import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:permission_handler/permission_handler.dart';

import '../data/book.dart';
import '../data/category.dart';
import '../data/library.dart';
import '../data/server_api.dart';
import '../util/text.dart';
import 'book_tile.dart';
import 'common.dart';

/// Onglet Bibliothèque : filtres par catégorie, tri et liste des livres
/// (sur le téléphone et sur le serveur).
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key, required this.library});

  final Library library;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen>
    with WidgetsBindingObserver {
  final _searchController = TextEditingController();
  List<Book> _books = const [];
  List<BookCategory> _categories = const [];
  Map<String, Set<int>> _links = const {};
  Map<String, int> _annotationCounts = const {};
  bool _loading = true;
  bool _syncing = false;
  BookSort _sort = BookSort.recent;
  bool _reversed = false;
  LibraryFilter _filter = LibraryFilter.all;
  bool _searching = false;
  String _query = '';

  Library get _lib => widget.library;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _lib.addListener(_onLibraryChanged);
    _init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _lib.removeListener(_onLibraryChanged);
    _searchController.dispose();
    super.dispose();
  }

  void _onLibraryChanged() {
    _reload();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Retour dans l'appli (après un téléchargement dans le navigateur, par
    // exemple) : on regarde s'il y a de nouveaux PDF dans Téléchargements.
    if (state == AppLifecycleState.resumed) _checkDownloads();
  }

  bool _checkingDownloads = false;

  /// Importe les nouveaux PDF du dossier Téléchargements, si l'option est
  /// activée dans les Réglages et que l'accès aux fichiers est autorisé.
  Future<void> _checkDownloads() async {
    if (_checkingDownloads || !await _lib.watchDownloadsEnabled()) return;
    if (!await Permission.manageExternalStorage.isGranted) return;
    _checkingDownloads = true;
    try {
      final report = await _lib.importFromDownloads();
      if (!mounted || (report.added == 0 && report.failed.isEmpty)) return;
      _offerUpload(
          'Téléchargements : ${report.summary}', report.addedIds);
    } finally {
      _checkingDownloads = false;
    }
  }

  /// Message après un import, avec un bouton pour envoyer aussi les
  /// nouveaux livres sur le serveur (ils restent d'abord sur le téléphone).
  void _offerUpload(String message, List<String> ids) {
    final canUpload = _lib.hasServer && ids.isNotEmpty;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message),
        duration: Duration(seconds: canUpload ? 8 : 4),
        action: canUpload
            ? SnackBarAction(
                label: 'Envoyer sur le serveur',
                onPressed: () => _uploadIds(ids),
              )
            : null,
      ));
  }

  Future<void> _uploadIds(List<String> ids) async {
    if (!mounted) return;
    try {
      await runWithProgress<void>(context, 'Envoi sur le serveur',
          (progress, detail) async {
        for (var i = 0; i < ids.length; i++) {
          final book = await _lib.db.book(ids[i]);
          if (book == null || book.onServer || !book.onDevice) continue;
          detail.value = '${i + 1} / ${ids.length} · ${book.title}';
          await _lib.uploadBook(book, onProgress: (fraction) {
            progress.value = (i + fraction) / ids.length;
          });
        }
      });
      if (mounted) showSnack(context, 'Envoyé sur le serveur');
    } on ServerException catch (e) {
      if (mounted) showSnack(context, e.message);
    }
  }

  Future<void> _uploadOne(Book book) => _uploadIds([book.id]);

  Future<void> _init() async {
    _sort = BookSort.fromKey(await _lib.db.getSetting('tri'));
    _reversed = await _lib.db.getSetting('tri_inverse') == '1';
    _filter = LibraryFilter.fromKey(await _lib.db.getSetting('filtre'));
    await _reload();
    await _checkDownloads();
    if (_lib.hasServer) await _sync(silent: true);
  }

  Future<void> _reload() async {
    final books = await _lib.db.books();
    final categories = await _lib.db.categories();
    final links = await _lib.db.bookCategoryLinks();
    final counts = await _lib.db.annotationCounts();
    if (!mounted) return;
    setState(() {
      _books = sortBooks(books, _sort, reversed: _reversed);
      _categories = categories;
      _links = links;
      _annotationCounts = counts;
      final categoryId = _filter.categoryId;
      if (categoryId != null && !categories.any((c) => c.id == categoryId)) {
        _filter = LibraryFilter.all; // catégorie supprimée entre-temps
      }
      _loading = false;
    });
  }

  /// Récupère la liste des livres du serveur.
  Future<void> _sync({bool silent = false}) async {
    if (!mounted || !_lib.hasServer || _syncing) return;
    setState(() => _syncing = true);
    try {
      final added = await _lib.syncWithServer();
      if (!silent && mounted) {
        showSnack(
            context,
            added == 0
                ? 'Bibliothèque à jour'
                : '$added livre${added > 1 ? 's' : ''} du serveur ajouté${added > 1 ? 's' : ''}');
      }
    } on ServerException catch (e) {
      if (mounted) showSnack(context, e.message);
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  // ------------------------------------------------------------- Filtres

  bool _matches(Book book, LibraryFilter filter) {
    final categoryId = filter.categoryId;
    if (categoryId != null) {
      return _links[book.id]?.contains(categoryId) ?? false;
    }
    if (filter == LibraryFilter.reading) return book.started && !book.finished;
    if (filter == LibraryFilter.notStarted) return !book.started;
    if (filter == LibraryFilter.finished) return book.finished;
    return true;
  }

  int _count(LibraryFilter filter) =>
      _books.where((b) => _matches(b, filter)).length;

  List<Book> get _visible {
    final query = normalizeForSearch(_query.trim());
    return _books
        .where((b) => _matches(b, _filter))
        .where((b) =>
            query.isEmpty || normalizeForSearch(b.title).contains(query))
        .toList();
  }

  BookCategory? get _selectedCategory {
    final id = _filter.categoryId;
    if (id == null) return null;
    for (final category in _categories) {
      if (category.id == id) return category;
    }
    return null;
  }

  List<String> _categoryNamesOf(Book book) {
    final ids = _links[book.id];
    if (ids == null || ids.isEmpty) return const [];
    return [
      for (final category in _categories)
        if (ids.contains(category.id)) category.name,
    ];
  }

  void _setFilter(LibraryFilter filter) {
    if (!mounted) return;
    setState(() => _filter = filter);
    _lib.db.setSetting('filtre', filter.key);
  }

  // ----------------------------------------------------------------- Tri

  Future<void> _chooseSort() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => StatefulBuilder(
        builder: (sheetContext, setSheetState) {
          void apply(BookSort sort, bool reversed) {
            setSheetState(() {});
            setState(() {
              _sort = sort;
              _reversed = reversed;
              _books = sortBooks(_books, sort, reversed: reversed);
            });
            _lib.db.setSetting('tri', sort.key);
            _lib.db.setSetting('tri_inverse', reversed ? '1' : '0');
          }

          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(24, 0, 24, 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text('Trier par'),
                  ),
                ),
                for (final sort in BookSort.values)
                  ListTile(
                    title: Text(sort.label),
                    trailing: sort == _sort ? const Icon(Icons.check) : null,
                    onTap: () => apply(sort, _reversed),
                  ),
                const Divider(),
                SwitchListTile(
                  title: const Text('Ordre inverse'),
                  value: _reversed,
                  onChanged: (value) => apply(_sort, value),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  // ------------------------------------------------------------- Actions

  void _closeSearch() {
    setState(() {
      _searching = false;
      _query = '';
      _searchController.clear();
    });
  }

  Future<void> _import() async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['pdf'],
    );
    if (files.isEmpty || !mounted) return;

    final category = _selectedCategory;
    final report = await runWithProgress<ImportReport>(
      context,
      'Import',
      (progress, detail) => _lib.importFiles(
        files,
        onProgress: (index, total, name) {
          progress.value = total == 0 ? null : index / total;
          detail.value = '${index + 1} / $total · $name';
        },
      ),
    );

    // Import depuis une catégorie : les livres y sont rangés directement.
    final ids = [...report.addedIds, ...report.duplicateIds];
    if (category != null && ids.isNotEmpty) {
      await _lib.db.addBooksToCategory(ids, category.id);
    }
    if (!mounted) return;
    final where = category != null && ids.isNotEmpty
        ? ' · rangé${ids.length > 1 ? 's' : ''} dans « ${category.name} »'
        : '';
    _offerUpload('${report.summary}$where', report.addedIds);
    await _reload();
  }

  /// Demande un nom (livre ou catégorie). Renvoie `null` si annulé ou vide.
  Future<String?> _askName({
    required String title,
    required String action,
    String initial = '',
    String? hint,
  }) async {
    final controller = TextEditingController(text: initial);
    final value = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(hintText: hint),
          onSubmitted: (value) => Navigator.pop(dialogContext, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: Text(action),
          ),
        ],
      ),
    );
    final clean = value?.trim() ?? '';
    return clean.isEmpty ? null : clean;
  }

  /// Petit menu en bas d'écran avec un titre et des actions.
  Future<String?> _menu(String title, List<(String, IconData, String)> items) {
    return showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                child: Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(sheetContext).textTheme.titleMedium,
                ),
              ),
              for (final (value, icon, label) in items)
                ListTile(
                  leading: Icon(icon),
                  title: Text(label),
                  onTap: () => Navigator.pop(sheetContext, value),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------- Actions sur un livre

  Future<void> _showBookMenu(Book book) async {
    final server = _lib.hasServer;
    final action = await _menu(book.title, [
      ('categories', Icons.label_outline, 'Catégories…'),
      ('rename', Icons.edit_outlined, 'Renommer'),
      if (server && book.onDevice && !book.onServer)
        ('upload', Icons.cloud_upload_outlined, 'Envoyer sur le serveur'),
      if (server && !book.onDevice && book.onServer)
        ('download', Icons.download_outlined,
            'Télécharger sur le téléphone (lecture hors connexion)'),
      if (book.onDevice && book.onServer)
        ('free', Icons.phonelink_erase,
            'Libérer de la place (le garder seulement sur le serveur)'),
      if (book.onServer)
        book.pinned
            ? ('unpin', Icons.push_pin_outlined, 'Ne plus épingler')
            : ('pin', Icons.push_pin, 'Épingler (toujours garder sur le téléphone)'),
      ('delete', Icons.delete_outline, 'Supprimer'),
    ]);
    if (!mounted || action == null) return;
    try {
      switch (action) {
        case 'categories':
          await _editBookCategories(book);
        case 'rename':
          final title = await _askName(
              title: 'Renommer', action: 'Enregistrer', initial: book.title);
          if (title != null && title != book.title) {
            await _lib.renameBook(book, title);
          }
        case 'upload':
          await runWithProgress<void>(
            context,
            'Envoi sur le serveur',
            (progress, detail) => _lib.uploadBook(book,
                onProgress: (fraction) => progress.value = fraction),
          );
          if (mounted) showSnack(context, '« ${book.title} » est sur le serveur');
        case 'download':
          await runWithProgress<void>(
            context,
            'Téléchargement',
            (progress, detail) => _lib.downloadBook(book,
                onProgress: (fraction) => progress.value = fraction),
          );
        case 'free':
          await _lib.freeSpace(book);
          if (mounted) {
            showSnack(context,
                '${formatSize(book.sizeBytes)} libérés · le livre reste sur le serveur');
          }
        case 'pin':
          await _lib.setPinned(book, true);
          if (!book.onDevice && mounted) await openBookDownloadOnly(book);
        case 'unpin':
          await _lib.setPinned(book, false);
        case 'delete':
          await _deleteBook(book);
      }
    } on ServerException catch (e) {
      if (mounted) showSnack(context, e.message);
    }
    await _reload();
  }

  /// Épingler un livre absent du téléphone le télécharge tout de suite.
  Future<void> openBookDownloadOnly(Book book) async {
    await runWithProgress<void>(
      context,
      'Téléchargement',
      (progress, detail) => _lib.downloadBook(book,
          onProgress: (fraction) => progress.value = fraction),
    );
  }

  Future<void> _deleteBook(Book book) async {
    final ok = await confirmDialog(
      context,
      title: 'Supprimer ce livre ?',
      message: book.onServer
          ? '« ${book.title} » sera supprimé du téléphone ET du serveur, '
              'avec ses marque-pages et ses notes.\n\n'
              'Pour seulement libérer de la place sur le téléphone, choisis '
              'plutôt « Libérer de la place ».'
          : '« ${book.title} », ses marque-pages et ses notes seront effacés '
              'du téléphone.',
      action: 'Supprimer',
    );
    if (!ok) return;
    await _lib.deleteBook(book);
    if (mounted) showSnack(context, '« ${book.title} » supprimé');
  }

  /// Coche/décoche les catégories d'un livre, avec création à la volée.
  Future<void> _editBookCategories(Book book) async {
    final selected = <int>{...?_links[book.id]};
    final newNames = <String>[]; // créées seulement à l'enregistrement
    final newChecked = <String>{};
    final input = TextEditingController();

    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (dialogContext, setDialog) {
          void addTyped() {
            final name = input.text.trim();
            if (name.isEmpty) return;
            final key = normalizeForSearch(name);
            setDialog(() {
              final existing = _categories
                  .where((c) => normalizeForSearch(c.name) == key)
                  .firstOrNull;
              if (existing != null) {
                selected.add(existing.id);
              } else if (!newNames.any((n) => normalizeForSearch(n) == key)) {
                newNames.add(name);
                newChecked.add(name);
              }
              input.clear();
            });
          }

          return AlertDialog(
            title: const Text('Catégories'),
            content: SizedBox(
              width: double.maxFinite,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        if (_categories.isEmpty && newNames.isEmpty)
                          const Padding(
                            padding: EdgeInsets.only(bottom: 8),
                            child: Text(
                                'Aucune catégorie pour l’instant : crée la '
                                'première ci-dessous.'),
                          ),
                        for (final category in _categories)
                          CheckboxListTile(
                            contentPadding: EdgeInsets.zero,
                            value: selected.contains(category.id),
                            title: Text(category.name),
                            onChanged: (checked) => setDialog(() {
                              if (checked == true) {
                                selected.add(category.id);
                              } else {
                                selected.remove(category.id);
                              }
                            }),
                          ),
                        for (final name in newNames)
                          CheckboxListTile(
                            contentPadding: EdgeInsets.zero,
                            value: newChecked.contains(name),
                            title: Text(name),
                            subtitle: const Text('Nouvelle'),
                            onChanged: (checked) => setDialog(() {
                              if (checked == true) {
                                newChecked.add(name);
                              } else {
                                newChecked.remove(name);
                              }
                            }),
                          ),
                      ],
                    ),
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: input,
                          textCapitalization: TextCapitalization.sentences,
                          decoration: const InputDecoration(
                              hintText: 'Nouvelle catégorie'),
                          onSubmitted: (_) => addTyped(),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.add),
                        tooltip: 'Ajouter',
                        onPressed: addTyped,
                      ),
                    ],
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Annuler'),
              ),
              FilledButton(
                onPressed: () {
                  addTyped(); // un nom tapé mais pas encore ajouté compte aussi
                  Navigator.pop(dialogContext, true);
                },
                child: const Text('Enregistrer'),
              ),
            ],
          );
        },
      ),
    );
    if (saved != true) return;

    for (final name in newChecked) {
      final category = await _lib.db.createCategory(name);
      selected.add(category.id);
    }
    await _lib.db.setBookCategories(book.id, selected);
  }

  // ---------------------------------------------------------- Catégories

  Future<void> _createCategory() async {
    final name = await _askName(
      title: 'Nouvelle catégorie',
      action: 'Créer',
      hint: 'Ex. Réseau, À lire, Religion…',
    );
    if (name == null) return;
    final category = await _lib.db.createCategory(name);
    await _reload();
    _setFilter(LibraryFilter.category(category.id));
  }

  Future<void> _showCategoryMenu(BookCategory category) async {
    final action = await _menu(category.name, const [
      ('rename', Icons.edit_outlined, 'Renommer'),
      ('delete', Icons.delete_outline, 'Supprimer la catégorie'),
    ]);
    if (!mounted) return;
    switch (action) {
      case 'rename':
        final name = await _askName(
          title: 'Renommer la catégorie',
          action: 'Enregistrer',
          initial: category.name,
        );
        if (name == null || name == category.name) return;
        final ok = await _lib.db.renameCategory(category.id, name);
        if (!ok && mounted) showSnack(context, 'Une catégorie « $name » existe déjà');
        await _reload();
      case 'delete':
        final confirmed = await confirmDialog(
          context,
          title: 'Supprimer « ${category.name} » ?',
          message: 'Seule la catégorie disparaît : les livres restent dans '
              'ta bibliothèque.',
          action: 'Supprimer',
        );
        if (!confirmed) return;
        await _lib.db.deleteCategory(category.id);
        if (_filter.categoryId == category.id) _setFilter(LibraryFilter.all);
        await _reload();
    }
  }

  // ----------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_searching,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _closeSearch();
      },
      child: Scaffold(
        appBar: _buildAppBar(),
        body: _buildBody(),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: _import,
          icon: const Icon(Icons.add),
          label: const Text('Importer'),
        ),
      ),
    );
  }

  AppBar _buildAppBar() {
    if (_searching) {
      return AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Fermer la recherche',
          onPressed: _closeSearch,
        ),
        title: TextField(
          controller: _searchController,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Rechercher un titre',
            border: InputBorder.none,
          ),
          onChanged: (value) => setState(() => _query = value),
        ),
      );
    }
    return AppBar(
      title: const Text('Bibliothèque'),
      actions: [
        IconButton(
          icon: const Icon(Icons.search),
          tooltip: 'Rechercher un titre',
          onPressed: () => setState(() => _searching = true),
        ),
        if (_lib.hasServer)
          _syncing
              ? const Padding(
                  padding: EdgeInsets.all(14),
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : IconButton(
                  icon: const Icon(Icons.sync),
                  tooltip: 'Synchroniser avec le serveur',
                  onPressed: _sync,
                ),
      ],
    );
  }

  Widget _buildFilterBar() {
    final chips = <Widget>[
      for (final filter in LibraryFilter.automatic)
        _filterChip(filter, filter.autoLabel),
      for (final category in _categories)
        GestureDetector(
          onLongPress: () => _showCategoryMenu(category),
          child: _filterChip(LibraryFilter.category(category.id), category.name),
        ),
      ActionChip(
        avatar: const Icon(Icons.add, size: 18),
        label: const Text('Catégorie'),
        onPressed: _createCategory,
      ),
    ];
    return SizedBox(
      height: 52,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        itemCount: chips.length,
        separatorBuilder: (context, index) => const SizedBox(width: 8),
        itemBuilder: (context, index) => chips[index],
      ),
    );
  }

  Widget _filterChip(LibraryFilter filter, String label) {
    return ChoiceChip(
      label: Text('$label (${_count(filter)})'),
      selected: _filter == filter,
      showCheckmark: false,
      onSelected: (_) => _setFilter(filter),
    );
  }

  /// Ligne « 12 livres · 1,2 Go      Tri : Lus récemment ».
  Widget _buildSortBar(List<Book> books) {
    final theme = Theme.of(context);
    final totalBytes = books.fold<int>(0, (sum, b) => sum + b.sizeBytes);
    final count = books.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 4, 0),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '$count livre${count > 1 ? 's' : ''} · ${formatSize(totalBytes)}',
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          TextButton.icon(
            onPressed: _chooseSort,
            icon: const Icon(Icons.swap_vert, size: 18),
            label: Text(
                'Tri : ${_sort.label}${_reversed ? ' (inversé)' : ''}'),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_books.isEmpty) {
      return _EmptyLibrary(
        onImport: _import,
        onSync: _lib.hasServer ? _sync : null,
      );
    }

    final books = _visible;
    return Column(
      children: [
        _buildFilterBar(),
        _buildSortBar(books),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () async {
              await _checkDownloads();
              await (_lib.hasServer ? _sync() : _reload());
            },
            child: books.isEmpty ? _buildNoResult() : _buildList(books),
          ),
        ),
      ],
    );
  }

  Widget _buildNoResult() {
    final query = _query.trim();
    final category = _selectedCategory;
    final String message;
    if (query.isNotEmpty) {
      message = 'Aucun titre ne contient « $query » ici.';
    } else if (category != null) {
      message = 'Aucun livre dans « ${category.name} ».\n\n'
          'Appui long sur un livre > Catégories pour l’y ranger, '
          'ou importe directement depuis ce filtre.';
    } else {
      message = 'Aucun livre dans ce filtre.';
    }
    // ListView pour que « tirer pour rafraîchir » marche aussi ici.
    return ListView(
      padding: const EdgeInsets.all(32),
      children: [Text(message, textAlign: TextAlign.center)],
    );
  }

  Widget _buildList(List<Book> books) {
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 96),
      itemCount: books.length,
      itemBuilder: (context, index) {
        final book = books[index];
        return BookTile(
          key: ValueKey(book.id),
          book: book,
          filePath: _lib.pathOf(book),
          categoryNames: _categoryNamesOf(book),
          annotationCount: _annotationCounts[book.id] ?? 0,
          serverConfigured: _lib.hasServer,
          onUpload: () => _uploadOne(book),
          onTap: () => openBook(context, _lib, book),
          onLongPress: () => _showBookMenu(book),
        );
      },
    );
  }
}

class _EmptyLibrary extends StatelessWidget {
  const _EmptyLibrary({required this.onImport, this.onSync});

  final VoidCallback onImport;
  final VoidCallback? onSync;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.menu_book_outlined,
                size: 64, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text('Aucun livre pour l’instant',
                style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'Importe tes PDF : ils sont copiés dans l’appli, '
              'le fichier d’origine ne bouge pas.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: onImport,
              icon: const Icon(Icons.add),
              label: const Text('Importer des PDF'),
            ),
            if (onSync != null) ...[
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: onSync,
                icon: const Icon(Icons.sync),
                label: const Text('Récupérer les livres du serveur'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
