import 'package:material_ui/material_ui.dart';
import 'package:pdfrx/pdfrx.dart';

import '../data/book.dart';
import '../util/text.dart';

/// Une ligne de la bibliothèque : couverture, titre, progression.
class BookTile extends StatelessWidget {
  const BookTile({
    super.key,
    required this.book,
    required this.filePath,
    this.onTap,
    this.onLongPress,
  });

  final Book book;
  final String filePath;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final progress = book.progress;
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Cover(bookId: book.id, filePath: filePath),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    book.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _status(book),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (book.started && progress != null) ...[
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: progress,
                        minHeight: 4,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _status(Book book) {
    final count = book.pageCount;
    if (!book.started) return 'Pas commencé · ${formatSize(book.sizeBytes)}';
    if (count == null) return 'Page ${book.lastPage}';
    if (book.finished) return 'Terminé · $count pages';
    final percent = ((book.progress ?? 0) * 100).round();
    return 'Page ${book.lastPage} / $count · $percent %';
  }
}

/// Miniature de la page 1, rendue en basse résolution.
class _Cover extends StatelessWidget {
  const _Cover({required this.bookId, required this.filePath});

  final String bookId;
  final String filePath;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      width: 52,
      height: 72,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: ColoredBox(
          color: colors.surfaceContainerHighest,
          child: PdfDocumentViewBuilder.file(
            filePath,
            key: ValueKey(bookId),
            builder: (context, document) => document == null
                ? Icon(Icons.picture_as_pdf_outlined,
                    color: colors.onSurfaceVariant)
                : PdfPageView(
                    document: document,
                    pageNumber: 1,
                    maximumDpi: 72,
                  ),
          ),
        ),
      ),
    );
  }
}
