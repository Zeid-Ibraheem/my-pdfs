import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../data/book.dart';
import '../data/covers.dart';
import '../data/server_api.dart';
import '../util/text.dart';

/// Une ligne de la bibliothèque : couverture, titre, progression,
/// catégories, nombre d'annotations et emplacement (téléphone / serveur).
class BookTile extends StatelessWidget {
  const BookTile({
    super.key,
    required this.book,
    required this.filePath,
    required this.covers,
    this.api,
    this.categoryNames = const [],
    this.annotationCount = 0,
    this.serverConfigured = false,
    this.onUpload,
    this.onTap,
    this.onLongPress,
  });

  final Book book;
  final String filePath;
  final CoverCache covers;
  final ServerApi? api;
  final List<String> categoryNames;
  final int annotationCount;
  final bool serverConfigured;

  /// Envoi sur le serveur (bouton affiché sur les livres seulement ici).
  final VoidCallback? onUpload;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final progress = book.progress;
    final location = _locationIcon();
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Cover(book: book, filePath: filePath, covers: covers, api: api),
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
                    _status(),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: (!book.onDevice && !book.onServer)
                          ? theme.colorScheme.error
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (categoryNames.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      categoryNames.join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ],
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
            if (book.onDevice && !book.onServer && serverConfigured &&
                onUpload != null)
              IconButton(
                icon: const Icon(Icons.cloud_upload_outlined),
                tooltip: 'Seulement sur le téléphone : envoyer sur le serveur',
                visualDensity: VisualDensity.compact,
                onPressed: onUpload,
              )
            else if (location != null) ...[
              const SizedBox(width: 8),
              Tooltip(
                message: location.$2,
                child: Icon(
                  location.$1,
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Icône d'emplacement et son explication.
  (IconData, String)? _locationIcon() {
    if (book.pinned && book.onDevice) {
      return (Icons.push_pin, 'Épinglé : toujours gardé sur le téléphone');
    }
    if (book.onDevice && book.onServer) {
      return (Icons.cloud_done_outlined, 'Sur le téléphone et sur le serveur');
    }
    if (!book.onDevice && book.onServer) {
      return (Icons.cloud_outlined, 'Sur le serveur : se lit sans téléchargement');
    }
    if (book.onDevice && serverConfigured) {
      return (Icons.smartphone, 'Seulement sur le téléphone');
    }
    return null;
  }

  String _status() {
    if (!book.onDevice && !book.onServer) {
      return 'Fichier introuvable : appui long > Supprimer';
    }
    final count = book.pageCount;
    final parts = <String>[];
    if (!book.started) {
      parts.add('Pas commencé');
      parts.add(formatSize(book.sizeBytes));
    } else if (count == null) {
      parts.add('Page ${book.lastPage}');
    } else if (book.finished) {
      parts.add('Terminé · $count pages');
    } else {
      final percent = ((book.progress ?? 0) * 100).round();
      parts.add('Page ${book.lastPage} / $count · $percent %');
    }
    if (annotationCount > 0) {
      parts.add('$annotationCount note${annotationCount > 1 ? 's' : ''}');
    }
    if (book.readSeconds >= 60) parts.add(formatDuration(book.readSeconds));
    return parts.join(' · ');
  }
}

/// Couverture : image enregistrée une fois (voir data/covers.dart).
/// Aucun PDF n'est ouvert ici, donc rien à recharger au retour du lecteur.
class _Cover extends StatefulWidget {
  const _Cover({
    required this.book,
    required this.filePath,
    required this.covers,
    this.api,
  });

  final Book book;
  final String filePath;
  final CoverCache covers;
  final ServerApi? api;

  @override
  State<_Cover> createState() => _CoverState();
}

class _CoverState extends State<_Cover> {
  File? _file;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_Cover old) {
    super.didUpdateWidget(old);
    final changed = old.book.id != widget.book.id ||
        old.book.onDevice != widget.book.onDevice;
    if (changed && _file == null) _load();
  }

  void _load() {
    final ready = widget.covers.existing(widget.book.id);
    if (ready != null) {
      _file = ready;
      return;
    }
    widget.covers
        .request(widget.book, pdfPath: widget.filePath, api: widget.api)
        .then((file) {
      if (mounted && file != null) setState(() => _file = file);
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final file = _file;
    return SizedBox(
      width: 52,
      height: 72,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: ColoredBox(
          color: colors.surfaceContainerHighest,
          child: file == null
              ? Icon(
                  widget.book.onDevice
                      ? Icons.picture_as_pdf_outlined
                      : Icons.cloud_outlined,
                  color: colors.onSurfaceVariant,
                )
              : Image.file(
                  file,
                  fit: BoxFit.cover,
                  cacheWidth: 156, // 52 px × 3 (écran haute densité)
                  gaplessPlayback: true,
                  errorBuilder: (context, error, stack) => Icon(
                    Icons.picture_as_pdf_outlined,
                    color: colors.onSurfaceVariant,
                  ),
                ),
        ),
      ),
    );
  }
}
