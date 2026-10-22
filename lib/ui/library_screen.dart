import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';

import '../data/book.dart';
import '../data/library.dart';
import '../util/text.dart';
import 'book_tile.dart';
import 'reader_screen.dart';

/// Écran d'accueil : la liste des livres.
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key, required this.library});

  final Library library;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  final _searchController = TextEditingController();
  List<Book> _books = const [];
  bool _loading = true;
  BookSort _sort = BookSort.recent;
  bool _searching = false;
  String _query = '';

  Library get _lib => widget.library;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    _sort = BookSort.fromKey(await _lib.db.getSetting('tri'));
    await _reload();
  }

  Future<void> _reload() async {
    final books = await _lib.db.books(_sort);
    if (!mounted) return;
    setState(() {
      _books = books;
      _loading = false;
    });
  }

  List<Book> get _visible {
    final query = normalizeForSearch(_query.trim());
    if (query.isEmpty) return _books;
    return _books
        .where((b) => normalizeForSearch(b.title).contains(query))
        .toList();
  }

  // ------------------------------------------------------------- Actions

  Future<void> _changeSort(BookSort sort) async {
    setState(() => _sort = sort);
    await _lib.db.setSetting('tri', sort.key);
    await _reload();
  }

  void _closeSearch() {
    setState(() {
      _searching = false;
      _query = '';
      _searchController.clear();
    });
  }

  Future<void> _import() async {
    final messenger = ScaffoldMessenger.of(context);
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['pdf'],
    );
    if (files.isEmpty || !mounted) return;

    final progress = ValueNotifier<String>('Préparation…');
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => PopScope(
        canPop: false,
        child: AlertDialog(
          content: Row(
            children: [
              const CircularProgressIndicator(),
              const SizedBox(width: 20),
              Expanded(
                child: ValueListenableBuilder<String>(
                  valueListenable: progress,
                  builder: (context, value, child) => Text(value),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    final report = await _lib.importFiles(
      files,
      onProgress: (index, total, name) {
        progress.value = 'Import ${index + 1} / $total\n$name';
      },
    );

    if (mounted) Navigator.of(context, rootNavigator: true).pop();
    messenger.showSnackBar(SnackBar(content: Text(report.summary)));
    await _reload();
  }

  Future<void> _open(Book book) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ReaderScreen(library: _lib, book: book),
      ),
    );
    await _reload();
  }

  Future<void> _showBookMenu(Book book) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text(
                book.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(sheetContext).textTheme.titleMedium,
              ),
            ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Renommer'),
              onTap: () => Navigator.pop(sheetContext, 'rename'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Supprimer'),
              onTap: () => Navigator.pop(sheetContext, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    switch (action) {
      case 'rename':
        await _rename(book);
      case 'delete':
        await _delete(book);
    }
  }

  Future<void> _rename(Book book) async {
    final controller = TextEditingController(text: book.title);
    final title = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Renommer'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          onSubmitted: (value) => Navigator.pop(dialogContext, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('Enregistrer'),
          ),
        ],
      ),
    );
    final clean = title?.trim() ?? '';
    if (clean.isEmpty || clean == book.title) return;
    await _lib.db.renameBook(book.id, clean);
    await _reload();
  }

  Future<void> _delete(Book book) async {
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Supprimer ce livre ?'),
        content: Text(
          '« ${book.title} » et ses marque-pages seront effacés du téléphone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _lib.delete(book);
    messenger.showSnackBar(SnackBar(content: Text('« ${book.title} » supprimé')));
    await _reload();
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
          tooltip: 'Rechercher',
          onPressed: () => setState(() => _searching = true),
        ),
        PopupMenuButton<BookSort>(
          icon: const Icon(Icons.sort),
          tooltip: 'Trier',
          onSelected: _changeSort,
          itemBuilder: (context) => [
            for (final sort in BookSort.values)
              CheckedPopupMenuItem<BookSort>(
                value: sort,
                checked: sort == _sort,
                child: Text(sort.label),
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_books.isEmpty) return _EmptyLibrary(onImport: _import);

    final books = _visible;
    if (books.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            'Aucun titre ne contient « ${_query.trim()} »',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    final theme = Theme.of(context);
    final totalBytes = _books.fold<int>(0, (sum, b) => sum + b.sizeBytes);
    final count = _books.length;
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 96),
      itemCount: books.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: Text(
              '$count livre${count > 1 ? 's' : ''} · ${formatSize(totalBytes)}',
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          );
        }
        final book = books[index - 1];
        return BookTile(
          key: ValueKey(book.id),
          book: book,
          filePath: _lib.pathOf(book),
          onTap: () => _open(book),
          onLongPress: () => _showBookMenu(book),
        );
      },
    );
  }
}

class _EmptyLibrary extends StatelessWidget {
  const _EmptyLibrary({required this.onImport});

  final VoidCallback onImport;

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
          ],
        ),
      ),
    );
  }
}
