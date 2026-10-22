import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pdfrx/pdfrx.dart';

import '../data/annotation.dart';
import '../data/book.dart';
import '../data/library.dart';
import 'annotation_widgets.dart';

/// Inverse les couleurs des pages (fond noir, texte blanc).
const _nightFilter = ColorFilter.matrix(<double>[
  -1, 0, 0, 0, 255, //
  0, -1, 0, 0, 255, //
  0, 0, -1, 0, 255, //
  0, 0, 0, 1, 0, //
]);

/// Filtre neutre : garder un ColorFiltered en permanence évite de recréer
/// le lecteur (et de perdre la position) quand on bascule le mode nuit.
const _dayFilter = ColorFilter.matrix(<double>[
  1, 0, 0, 0, 0, //
  0, 1, 0, 0, 0, //
  0, 0, 1, 0, 0, //
  0, 0, 0, 1, 0, //
]);

/// Couleur du point qui signale une page annotée.
const _noteDotColor = 0xFFFF9F00;

/// Inverse une couleur ARGB : en mode nuit, tout l'écran est inversé,
/// donc on peint l'inverse pour retrouver la bonne teinte à l'affichage.
int _invert(int argb) => 0xFF000000 | (~argb & 0x00FFFFFF);

enum _MenuAction { addNote, bookmarks, goToPage, copyPage, night }

/// Une zone surlignée prête à peindre.
class _Mark {
  const _Mark(this.rect, this.color);

  final PdfRect rect;
  final int color;
}

/// Lecteur : défilement vertical continu, reprise à la dernière page,
/// marque-pages, surlignages, notes et copie du texte.
class ReaderScreen extends StatefulWidget {
  const ReaderScreen({
    super.key,
    required this.library,
    required this.book,
    this.initialPage,
  });

  final Library library;
  final Book book;

  /// Page d'ouverture (résultat de recherche) ; sinon la dernière page lue.
  final int? initialPage;

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen>
    with WidgetsBindingObserver {
  final _controller = PdfViewerController();
  late int _page;
  int? _pageCount;
  Set<int> _bookmarks = {};
  List<Annotation> _annotations = const [];
  Map<int, List<_Mark>> _marks = const {};
  Set<int> _notedPages = const {};
  bool _night = false;
  bool _hasSelection = false;
  Timer? _saveTimer;

  // Recherche dans le livre (moteur de pdfrx). Créé seulement quand le
  // lecteur est prêt : avant, le contrôleur n'est pas encore relié au
  // document et pdfrx lève une erreur (écran gris en version release).
  PdfTextSearcher? _searcher;

  // Lecture depuis le serveur : adresse et en-têtes calculés une seule fois
  // (de nouveaux objets à chaque affichage feraient recharger le livre).
  Uri? _remoteUri;
  Map<String, String>? _remoteHeaders;
  final _searchField = TextEditingController();
  bool _searchMode = false;

  Book get _book => widget.book;
  Library get _lib => widget.library;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _page = math.max(1, widget.initialPage ?? _book.lastPage);
    _pageCount = _book.pageCount;
    final api = _lib.api;
    if (!_book.onDevice && _book.onServer && api != null) {
      _remoteUri = api.fileUri(_book.id);
      _remoteHeaders = api.authHeaders;
    }
    _lib.db.markOpened(_book.id);
    _loadState();
  }

  Future<void> _loadState() async {
    final marks = await _lib.db.bookmarks(_book.id);
    final annotations = await _lib.db.annotations(_book.id);
    final night = await _lib.db.getSetting('mode_nuit') == '1';
    _update(() {
      _bookmarks = marks;
      _night = night;
    });
    _setAnnotations(annotations);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _saveNow();
    final searcher = _searcher;
    if (searcher != null) {
      searcher.removeListener(_onSearchChanged);
      searcher.dispose();
    }
    _searchField.dispose();
    super.dispose();
  }

  // ------------------------------------------------- Recherche dans le livre

  void _onSearchChanged() => _update(() {});

  void _openSearch() => setState(() => _searchMode = true);

  void _closeSearch() {
    _searcher?.resetTextSearch();
    _searchField.clear();
    setState(() => _searchMode = false);
  }

  void _runSearch(String query) {
    final searcher = _searcher;
    if (searcher == null) return; // livre pas encore chargé
    final text = query.trim();
    if (text.isEmpty) {
      searcher.resetTextSearch();
    } else {
      searcher.startTextSearch(text, caseInsensitive: true);
    }
  }

  String _searchCounter() {
    final searcher = _searcher;
    if (searcher == null || _searchField.text.trim().isEmpty) return '';
    final count = searcher.matches.length;
    if (count == 0) return searcher.isSearching ? '' : '0';
    final index = searcher.currentIndex;
    return '${index == null ? 0 : index + 1}/$count';
  }

  void _paintSearchMatches(Canvas canvas, Rect pageRect, PdfPage page) {
    _searcher?.pageTextMatchPaintCallback(canvas, pageRect, page);
  }

  AppBar _buildSearchBar() {
    final searcher = _searcher;
    return AppBar(
      leading: IconButton(
        icon: const Icon(Icons.close),
        tooltip: 'Fermer la recherche',
        onPressed: _closeSearch,
      ),
      titleSpacing: 0,
      title: TextField(
        controller: _searchField,
        autofocus: true,
        textInputAction: TextInputAction.search,
        decoration: const InputDecoration(
          hintText: 'Rechercher dans le livre',
          border: InputBorder.none,
        ),
        onSubmitted: _runSearch,
      ),
      actions: [
        if (searcher != null && searcher.isSearching)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        Center(child: Text(_searchCounter())),
        IconButton(
          icon: const Icon(Icons.keyboard_arrow_up),
          tooltip: 'Résultat précédent',
          onPressed: searcher != null && searcher.hasMatches
              ? () => searcher.goToPrevMatch()
              : null,
        ),
        IconButton(
          icon: const Icon(Icons.keyboard_arrow_down),
          tooltip: 'Résultat suivant',
          onPressed: searcher != null && searcher.hasMatches
              ? () => searcher.goToNextMatch()
              : null,
        ),
      ],
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Android peut tuer l'appli en arrière-plan : on enregistre la page
    // dès qu'elle quitte le premier plan.
    if (state != AppLifecycleState.resumed) _saveNow();
  }

  /// setState sûr : les rappels du lecteur peuvent arriver pendant que
  /// Flutter construit l'écran, et setState y est interdit.
  void _update(VoidCallback change) {
    if (!mounted) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(change);
      });
    } else {
      setState(change);
    }
  }

  void _saveNow() {
    _saveTimer?.cancel();
    _saveTimer = null;
    _lib.db.saveLastPage(_book.id, _page);
  }

  /// Redessine les pages (surlignages, points de note) si le lecteur est prêt.
  void _repaintPages() {
    if (_controller.isReady) _controller.invalidate();
  }

  // ------------------------------------------------------------ Annotations

  void _setAnnotations(List<Annotation> annotations) {
    final sorted = [...annotations]..sort((a, b) {
        final byPage = a.page.compareTo(b.page);
        return byPage != 0 ? byPage : a.createdAt.compareTo(b.createdAt);
      });
    final marks = <int, List<_Mark>>{};
    final noted = <int>{};
    for (final annotation in sorted) {
      if (annotation.hasNote) noted.add(annotation.page);
      final color = annotation.color;
      if (color == null) continue;
      annotation.rects.forEach((page, rects) {
        for (final r in rects) {
          if (r.length != 4) continue;
          marks
              .putIfAbsent(page, () => [])
              .add(_Mark(PdfRect(r[0], r[1], r[2], r[3]), color));
        }
      });
    }
    _update(() {
      _annotations = sorted;
      _marks = marks;
      _notedPages = noted;
    });
    _repaintPages();
  }

  /// Peint les surlignages et un point orange sur les pages annotées.
  void _paintAnnotations(Canvas canvas, Rect pageRect, PdfPage page) {
    final marks = _marks[page.pageNumber];
    if (marks != null) {
      for (final mark in marks) {
        final argb = _night ? _invert(mark.color) : mark.color;
        final paint = Paint()
          ..color = Color(argb).withValues(alpha: 0.4)
          ..blendMode = BlendMode.multiply;
        canvas.drawRect(
          mark.rect.toRectInDocument(page: page, pageRect: pageRect),
          paint,
        );
      }
    }
    if (_notedPages.contains(page.pageNumber)) {
      final radius = pageRect.width * 0.018;
      final center = Offset(
        pageRect.right - radius * 2.5,
        pageRect.top + radius * 2.5,
      );
      final argb = _night ? _invert(_noteDotColor) : _noteDotColor;
      canvas.drawCircle(center, radius, Paint()..color = Color(argb));
    }
  }

  Future<void> _highlightSelection(int argb, {bool withNote = false}) async {
    final selection = _controller.textSelectionDelegate;
    final ranges = await selection.getSelectedTextRanges();
    final quote = (await selection.getSelectedText()).trim();

    final rects = <int, List<List<double>>>{};
    for (final range in ranges) {
      for (final fragment in range.enumerateFragmentBoundingRects()) {
        final b = fragment.bounds;
        rects
            .putIfAbsent(range.pageNumber, () => [])
            .add([b.left, b.top, b.right, b.bottom]);
      }
    }
    if (rects.isEmpty || quote.isEmpty) return;

    var note = '';
    if (withNote) {
      if (!mounted) return;
      final typed = await editNoteDialog(context, title: 'Note', quote: quote);
      if (typed == null) return; // annulé : la sélection reste en place
      note = typed.trim();
    }

    final now = DateTime.now();
    final annotation = Annotation(
      bookId: _book.id,
      page: rects.keys.reduce((a, b) => a < b ? a : b),
      quote: quote,
      rects: rects,
      color: argb,
      note: note,
      createdAt: now,
      updatedAt: now,
    );
    final id = await _lib.db.insertAnnotation(annotation);
    await selection.clearTextSelection();
    _update(() => _hasSelection = false);
    _setAnnotations([..._annotations, annotation.copyWith(id: id)]);
  }

  Future<void> _addPageNote() async {
    final page = _page;
    final typed = await editNoteDialog(context, title: 'Note · page $page');
    final note = typed?.trim() ?? '';
    if (note.isEmpty) return;
    final now = DateTime.now();
    final annotation = Annotation(
      bookId: _book.id,
      page: page,
      quote: null,
      rects: const {},
      color: null,
      note: note,
      createdAt: now,
      updatedAt: now,
    );
    final id = await _lib.db.insertAnnotation(annotation);
    _setAnnotations([..._annotations, annotation.copyWith(id: id)]);
  }

  Future<void> _editAnnotation(Annotation annotation) async {
    final typed = await editNoteDialog(
      context,
      title: 'Note · page ${annotation.page}',
      quote: annotation.quote,
      initial: annotation.note,
    );
    if (typed == null) return;
    final note = typed.trim();
    if (!annotation.isHighlight && note.isEmpty) {
      await _deleteAnnotation(annotation); // note libre vidée = supprimée
      return;
    }
    await _lib.db.updateAnnotationNote(annotation.id!, note);
    final now = DateTime.now();
    _setAnnotations([
      for (final a in _annotations)
        a.id == annotation.id ? a.copyWith(note: note, updatedAt: now) : a,
    ]);
  }

  Future<void> _deleteAnnotation(Annotation annotation) async {
    _setAnnotations(
        _annotations.where((a) => a.id != annotation.id).toList());
    await _lib.db.deleteAnnotation(annotation.id!);
  }

  Future<void> _copyAllNotes() async {
    final markdown = annotationsToMarkdown(_book.title, _annotations);
    await Clipboard.setData(ClipboardData(text: markdown));
    if (mounted) _snack('${_annotations.length} annotations copiées (Markdown)');
  }

  // ----------------------------------------------------- Rappels du lecteur

  void _onViewerReady(PdfDocument document, PdfViewerController controller) {
    _searcher ??= PdfTextSearcher(controller)..addListener(_onSearchChanged);
    final count = document.pages.length;
    if (count != _pageCount) {
      _update(() => _pageCount = count);
      _lib.db.setPageCount(_book.id, count);
    }
    _repaintPages();
  }

  void _onPageChanged(int? pageNumber) {
    if (pageNumber == null || pageNumber == _page) return;
    _update(() => _page = pageNumber);
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 1), _saveNow);
  }

  // --------------------------------------------------------------- Actions

  void _snack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _toggleBookmark() async {
    final page = _page;
    final had = _bookmarks.contains(page);
    setState(() {
      if (had) {
        _bookmarks.remove(page);
      } else {
        _bookmarks.add(page);
      }
    });
    if (had) {
      await _lib.db.removeBookmark(_book.id, page);
    } else {
      await _lib.db.addBookmark(_book.id, page);
    }
    if (mounted) {
      _snack(had ? 'Marque-page retiré (p. $page)' : 'Marque-page ajouté (p. $page)');
    }
  }

  void _goTo(int pageNumber) {
    if (!_controller.isReady) return;
    final last = _pageCount ?? pageNumber;
    _controller.goToPage(pageNumber: math.max(1, math.min(pageNumber, last)));
  }

  Future<void> _copySelection() async {
    final selection = _controller.textSelectionDelegate;
    if (!selection.isCopyAllowed) {
      _snack('Ce PDF interdit la copie de texte');
      return;
    }
    final text = await selection.getSelectedText();
    await Clipboard.setData(ClipboardData(text: text));
    await selection.clearTextSelection();
    _update(() => _hasSelection = false);
    if (mounted) _snack('Copié : ${text.length} caractères');
  }

  Future<void> _copyPage() async {
    if (!_controller.isReady) return;
    if (!_controller.textSelectionDelegate.isCopyAllowed) {
      _snack('Ce PDF interdit la copie de texte');
      return;
    }
    final pages = _controller.document.pages;
    if (_page < 1 || _page > pages.length) return;
    final pageText = await pages[_page - 1].loadStructuredText();
    final text = pageText.fullText.trim();
    if (!mounted) return;
    if (text.isEmpty) {
      _snack("Aucun texte sur cette page : c'est sûrement une image scannée.");
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) _snack('Page $_page copiée : ${text.length} caractères');
  }

  Future<void> _toggleNight() async {
    setState(() => _night = !_night);
    _repaintPages();
    await _lib.db.setSetting('mode_nuit', _night ? '1' : '0');
  }

  Future<void> _askPage() async {
    final last = _pageCount;
    final controller = TextEditingController();
    final pageNumber = await showDialog<int>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Aller à la page'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: InputDecoration(
            hintText: last == null ? 'Numéro de page' : '1 à $last',
          ),
          onSubmitted: (value) =>
              Navigator.pop(dialogContext, int.tryParse(value)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, int.tryParse(controller.text)),
            child: const Text('Aller'),
          ),
        ],
      ),
    );
    if (pageNumber != null) _goTo(pageNumber);
  }

  void _showBookmarks() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => StatefulBuilder(
        builder: (sheetContext, setSheetState) {
          final pages = _bookmarks.toList()..sort();
          if (pages.isEmpty) {
            return const SafeArea(
              child: Padding(
                padding: EdgeInsets.fromLTRB(24, 0, 24, 32),
                child: Text(
                  "Aucun marque-page. Touche l'icône marque-page en haut "
                  'pour marquer la page en cours.',
                ),
              ),
            );
          }
          final count = _pageCount;
          return SafeArea(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final page in pages)
                  ListTile(
                    leading: const Icon(Icons.bookmark),
                    title: Text('Page $page'),
                    subtitle: count == null
                        ? null
                        : Text('${(page * 100 / count).round()} % du livre'),
                    trailing: IconButton(
                      icon: const Icon(Icons.close),
                      tooltip: 'Retirer',
                      onPressed: () {
                        _update(() => _bookmarks.remove(page));
                        setSheetState(() {});
                        _lib.db.removeBookmark(_book.id, page);
                      },
                    ),
                    onTap: () {
                      Navigator.pop(sheetContext);
                      _goTo(page);
                    },
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  void _showNotes() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        minChildSize: 0.3,
        maxChildSize: 0.95,
        builder: (_, scrollController) => StatefulBuilder(
          builder: (sheetContext, setSheetState) => NotesPanel(
            annotations: _annotations,
            scrollController: scrollController,
            onCopyAll: _copyAllNotes,
            onOpen: (annotation) {
              Navigator.pop(sheetContext);
              _goTo(annotation.page);
            },
            onEdit: (annotation) async {
              await _editAnnotation(annotation);
              setSheetState(() {});
            },
            onDelete: (annotation) {
              _deleteAnnotation(annotation);
              setSheetState(() {});
            },
          ),
        ),
      ),
    );
  }

  void _onMenu(_MenuAction action) {
    switch (action) {
      case _MenuAction.addNote:
        _addPageNote();
      case _MenuAction.bookmarks:
        _showBookmarks();
      case _MenuAction.goToPage:
        _askPage();
      case _MenuAction.copyPage:
        _copyPage();
      case _MenuAction.night:
        _toggleNight();
    }
  }

  // -------------------------------------------------------------------- UI

  /// Livre lu directement depuis le serveur, sans copie sur le téléphone.
  bool get _remote => _remoteUri != null;

  PdfViewerParams _viewerParams() {
    return PdfViewerParams(
      backgroundColor: const Color(0xFFE0E0E0),
      onViewerReady: _onViewerReady,
      onPageChanged: _onPageChanged,
      pagePaintCallbacks: [_paintAnnotations, _paintSearchMatches],
      textSelectionParams: PdfTextSelectionParams(
        onTextSelectionChange: (selection) =>
            _update(() => _hasSelection = selection.hasSelectedText),
      ),
      viewerOverlayBuilder: (context, size, handleLinkTap) => [
        PdfViewerScrollThumb(
          controller: _controller,
          orientation: ScrollbarOrientation.right,
          thumbSize: const Size(44, 28),
          thumbBuilder: (context, thumbSize, pageNumber, controller) =>
              DecoratedBox(
            decoration: const BoxDecoration(
              color: Color(0xDD000000),
              borderRadius: BorderRadius.horizontal(left: Radius.circular(14)),
            ),
            child: Center(
              child: Text(
                pageNumber.toString(),
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildViewer() {
    // Lu une seule fois à l'ouverture : ne pas y mettre _page, sinon le
    // lecteur serait reconfiguré à chaque changement de page.
    final initialPage = math.max(1, widget.initialPage ?? _book.lastPage);
    final remoteUri = _remoteUri;
    final remoteHeaders = _remoteHeaders;
    if (remoteUri != null && remoteHeaders != null) {
      // Lecture par morceaux (requêtes HTTP partielles) : seules les pages
      // affichées sont transférées, rien n'est enregistré sur le téléphone.
      return PdfViewer.uri(
        remoteUri,
        headers: remoteHeaders,
        preferRangeAccess: true,
        controller: _controller,
        initialPageNumber: initialPage,
        params: _viewerParams(),
      );
    }
    return PdfViewer.file(
      _lib.pathOf(_book),
      controller: _controller,
      initialPageNumber: initialPage,
      params: _viewerParams(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final count = _pageCount;
    final marked = _bookmarks.contains(_page);
    final notesHere = _annotations
        .where((a) => a.page == _page || a.rects.containsKey(_page))
        .length;
    final where = _remote ? ' · serveur' : '';
    final position = count == null || count == 0
        ? 'Page $_page$where'
        : 'Page $_page / $count · ${count == 1 ? 100 : ((_page - 1) * 100 / (count - 1)).round()} %$where';

    return PopScope(
      canPop: !_searchMode,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) {
          _saveNow(); // avant que la bibliothèque ne se recharge
        } else {
          _closeSearch();
        }
      },
      child: Scaffold(
        appBar: _searchMode ? _buildSearchBar() : AppBar(
          titleSpacing: 0,
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _book.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium,
              ),
              Text(position, style: theme.textTheme.bodySmall),
            ],
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.search),
              tooltip: 'Rechercher dans le livre',
              onPressed: _openSearch,
            ),
            IconButton(
              tooltip: 'Notes et surlignages',
              onPressed: _showNotes,
              icon: Badge(
                isLabelVisible: notesHere > 0,
                label: Text('$notesHere'),
                child: const Icon(Icons.sticky_note_2_outlined),
              ),
            ),
            IconButton(
              icon: Icon(marked ? Icons.bookmark : Icons.bookmark_border),
              tooltip: marked ? 'Retirer le marque-page' : 'Marquer cette page',
              onPressed: _toggleBookmark,
            ),
            PopupMenuButton<_MenuAction>(
              onSelected: _onMenu,
              itemBuilder: (context) => [
                const PopupMenuItem(
                  value: _MenuAction.addNote,
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.note_add_outlined),
                    title: Text('Note sur cette page'),
                  ),
                ),
                const PopupMenuItem(
                  value: _MenuAction.bookmarks,
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.bookmarks_outlined),
                    title: Text('Marque-pages'),
                  ),
                ),
                const PopupMenuItem(
                  value: _MenuAction.goToPage,
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.numbers),
                    title: Text('Aller à la page…'),
                  ),
                ),
                const PopupMenuItem(
                  value: _MenuAction.copyPage,
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.content_copy),
                    title: Text('Copier le texte de la page'),
                  ),
                ),
                PopupMenuItem(
                  value: _MenuAction.night,
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(_night
                        ? Icons.light_mode_outlined
                        : Icons.dark_mode_outlined),
                    title: Text(_night ? 'Mode jour' : 'Mode nuit'),
                  ),
                ),
              ],
            ),
          ],
        ),
        body: Stack(
          children: [
            Positioned.fill(
              child: ColorFiltered(
                colorFilter: _night ? _nightFilter : _dayFilter,
                child: _buildViewer(),
              ),
            ),
            if (_hasSelection)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Center(
                  child: SelectionBar(
                    onCopy: _copySelection,
                    onHighlight: (argb) => _highlightSelection(argb),
                    onNote: () => _highlightSelection(highlightColors.first,
                        withNote: true),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
