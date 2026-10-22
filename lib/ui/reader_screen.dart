import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pdfrx/pdfrx.dart';

import '../data/book.dart';
import '../data/library.dart';

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

enum _MenuAction { bookmarks, goToPage, copyPage, night }

/// Lecteur : défilement vertical continu, reprise à la dernière page,
/// marque-pages, copie du texte.
class ReaderScreen extends StatefulWidget {
  const ReaderScreen({super.key, required this.library, required this.book});

  final Library library;
  final Book book;

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen>
    with WidgetsBindingObserver {
  final _controller = PdfViewerController();
  late int _page;
  int? _pageCount;
  Set<int> _bookmarks = {};
  bool _night = false;
  bool _hasSelection = false;
  Timer? _saveTimer;

  Book get _book => widget.book;
  Library get _lib => widget.library;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _page = math.max(1, _book.lastPage);
    _pageCount = _book.pageCount;
    _lib.db.markOpened(_book.id);
    _loadState();
  }

  Future<void> _loadState() async {
    final marks = await _lib.db.bookmarks(_book.id);
    final night = await _lib.db.getSetting('mode_nuit') == '1';
    _update(() {
      _bookmarks = marks;
      _night = night;
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _saveNow();
    super.dispose();
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

  // ----------------------------------------------------- Rappels du lecteur

  void _onViewerReady(PdfDocument document, PdfViewerController controller) {
    final count = document.pages.length;
    if (count != _pageCount) {
      _update(() => _pageCount = count);
      _lib.db.setPageCount(_book.id, count);
    }
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

  void _onMenu(_MenuAction action) {
    switch (action) {
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final count = _pageCount;
    final marked = _bookmarks.contains(_page);
    final position = count == null
        ? 'Page $_page'
        : 'Page $_page / $count · ${(_page * 100 / count).round()} %';

    return PopScope(
      // Enregistre la page avant que la bibliothèque ne se recharge.
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) _saveNow();
      },
      child: Scaffold(
        appBar: AppBar(
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
              icon: Icon(marked ? Icons.bookmark : Icons.bookmark_border),
              tooltip: marked ? 'Retirer le marque-page' : 'Marquer cette page',
              onPressed: _toggleBookmark,
            ),
            PopupMenuButton<_MenuAction>(
              onSelected: _onMenu,
              itemBuilder: (context) => [
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
        body: ColorFiltered(
          colorFilter: _night ? _nightFilter : _dayFilter,
          child: PdfViewer.file(
            _lib.pathOf(_book),
            controller: _controller,
            // Valeur lue une seule fois à l'ouverture : ne pas y mettre _page,
            // sinon le lecteur serait reconfiguré à chaque changement de page.
            initialPageNumber: math.max(1, _book.lastPage),
            params: PdfViewerParams(
              backgroundColor: const Color(0xFFE0E0E0),
              onViewerReady: _onViewerReady,
              onPageChanged: _onPageChanged,
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
                      borderRadius:
                          BorderRadius.horizontal(left: Radius.circular(14)),
                    ),
                    child: Center(
                      child: Text(
                        pageNumber.toString(),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        floatingActionButton: _hasSelection
            ? FloatingActionButton.extended(
                onPressed: _copySelection,
                icon: const Icon(Icons.copy),
                label: const Text('Copier'),
              )
            : null,
      ),
    );
  }
}
