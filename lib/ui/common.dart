import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../data/book.dart';
import '../data/library.dart';
import '../data/server_api.dart';
import 'reader_screen.dart';

/// Petit message en bas de l'écran.
void showSnack(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

/// Affiche une fenêtre de progression pendant [task].
/// Les erreurs de [task] remontent à l'appelant une fois la fenêtre fermée.
Future<T> runWithProgress<T>(
  BuildContext context,
  String title,
  Future<T> Function(ValueNotifier<double?> progress, ValueNotifier<String?> detail)
      task,
) async {
  final progress = ValueNotifier<double?>(null);
  final detail = ValueNotifier<String?>(null);
  final navigator = Navigator.of(context, rootNavigator: true);
  unawaited(showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ValueListenableBuilder<double?>(
              valueListenable: progress,
              builder: (context, value, child) =>
                  LinearProgressIndicator(value: value),
            ),
            const SizedBox(height: 12),
            ValueListenableBuilder<String?>(
              valueListenable: detail,
              builder: (context, text, child) =>
                  ValueListenableBuilder<double?>(
                valueListenable: progress,
                builder: (context, value, child) => Text(
                  text ??
                      (value == null
                          ? 'Patiente…'
                          : '${(value * 100).round()} %'),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  ));
  try {
    return await task(progress, detail);
  } finally {
    navigator.pop();
  }
}

/// Demande une confirmation. Renvoie `true` si l'utilisateur accepte.
Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  required String action,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: Text(action),
        ),
      ],
    ),
  );
  return confirmed == true;
}

/// Ouvre un livre. S'il n'est que sur le serveur, il est d'abord téléchargé.
Future<void> openBook(
  BuildContext context,
  Library library,
  Book book, {
  int? page,
}) async {
  var target = book;
  if (!book.onDevice) {
    if (!book.onServer) {
      showSnack(context, 'Fichier introuvable, ni sur le téléphone ni sur le serveur');
      return;
    }
    if (!library.hasServer) {
      showSnack(context,
          'Ce livre est sur ton serveur : renseigne-le dans l’onglet Réglages');
      return;
    }
    try {
      await runWithProgress<void>(
        context,
        'Téléchargement depuis le serveur',
        (progress, detail) => library.downloadBook(book,
            onProgress: (fraction) => progress.value = fraction),
      );
    } on ServerException catch (e) {
      if (context.mounted) showSnack(context, e.message);
      return;
    }
    target = await library.db.book(book.id) ?? book;
  }
  if (!context.mounted) return;
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => ReaderScreen(library: library, book: target, initialPage: page),
    ),
  );
  library.refresh(); // progression, notes… ont pu changer
  unawaited(library.autoBackup());
}
