import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';

import 'book.dart';
import 'server_api.dart';

/// Couvertures des livres, enregistrées une fois pour toutes en PNG.
///
/// Pourquoi : avant, chaque ligne de la bibliothèque ouvrait le PDF entier
/// pour dessiner sa page 1. pdfrx partage un même document entre tous les
/// écrans qui ouvrent le même fichier : en se redessinant, la liste fermait
/// le document que le lecteur utilisait (pages blanches, pas de nombre de
/// pages), et tout se rechargeait au retour. Les couvertures sont désormais
/// des images fixes, créées une seule fois, l'une après l'autre, avec leur
/// propre ouverture du fichier, et jamais pendant la lecture.
class CoverCache {
  CoverCache(this.dir);

  final String dir;

  /// Fichier de la couverture d'un livre (il peut ne pas encore exister).
  File fileFor(String bookId) => File(p.join(dir, '$bookId.png'));

  final List<_Request> _queue = [];
  final Map<String, Future<File?>> _pending = {};
  final Set<String> _failed = {}; // pas de nouvel essai avant redémarrage
  bool _working = false;
  int _pauses = 0;
  Completer<void>? _resumed;

  /// Met en pause la création des couvertures (pendant la lecture).
  void pause() {
    _pauses++;
    _resumed ??= Completer<void>();
  }

  void resume() {
    if (_pauses == 0) return;
    _pauses--;
    if (_pauses == 0) {
      _resumed?.complete();
      _resumed = null;
    }
  }

  /// La couverture si elle existe déjà, sinon `null` (sans attendre).
  File? existing(String bookId) {
    final file = fileFor(bookId);
    return file.existsSync() ? file : null;
  }

  /// Demande la couverture d'un livre : renvoie le fichier une fois créé,
  /// ou `null` si c'est impossible (PDF abîmé, scan illisible…).
  Future<File?> request(Book book, {required String pdfPath, ServerApi? api}) {
    final ready = existing(book.id);
    if (ready != null) return Future.value(ready);
    if (_failed.contains(book.id)) return Future.value(null);
    return _pending.putIfAbsent(book.id, () {
      final request = _Request(book, pdfPath, api);
      _queue.add(request);
      unawaited(_work());
      return request.done.future;
    });
  }

  /// Oublie la couverture d'un livre supprimé.
  Future<void> remove(String bookId) async {
    try {
      final file = fileFor(bookId);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Pas grave : un fichier orphelin de quelques Ko.
    }
  }

  Future<void> _work() async {
    if (_working) return;
    _working = true;
    try {
      await Directory(dir).create(recursive: true);
      while (_queue.isNotEmpty) {
        final waiting = _resumed;
        if (waiting != null) await waiting.future;
        final request = _queue.removeLast(); // les plus récentes d'abord (écran)
        File? result;
        try {
          result = await _make(request);
        } catch (_) {
          result = null;
        }
        if (result == null) _failed.add(request.book.id);
        _pending.remove(request.book.id);
        request.done.complete(result);
      }
    } finally {
      _working = false;
    }
  }

  Future<File?> _make(_Request request) async {
    final book = request.book;
    final dest = fileFor(book.id);
    final tmp = File('${dest.path}.part');
    List<int>? png;

    if (book.onDevice && await File(request.pdfPath).exists()) {
      png = await _renderFirstPage(request.pdfPath)
          .timeout(const Duration(seconds: 60), onTimeout: () => null);
    }
    if (png == null && book.onServer && request.api != null) {
      png = await request.api!.cover(book.id);
    }
    if (png == null || png.isEmpty) return null;
    await tmp.writeAsBytes(png, flush: true);
    await tmp.rename(dest.path);
    return dest;
  }

  /// Dessine la page 1 en 200 px de large, avec une ouverture du fichier
  /// propre à cette fonction (aucun partage avec le lecteur).
  static Future<List<int>?> _renderFirstPage(String path) async {
    final document = await PdfDocument.openFile(path);
    try {
      if (document.pages.isEmpty) return null;
      final page = document.pages.first;
      if (page.width <= 0 || page.height <= 0) return null;
      const width = 200;
      final height =
          (width * page.height / page.width).round().clamp(1, 600).toInt();
      final rendered = await page.render(
        width: width,
        height: height,
        fullWidth: width.toDouble(),
        fullHeight: height.toDouble(),
        backgroundColor: 0xFFFFFFFF,
      );
      if (rendered == null) return null;
      try {
        final image = await rendered.createImage();
        try {
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          return bytes?.buffer.asUint8List();
        } finally {
          image.dispose();
        }
      } finally {
        rendered.dispose();
      }
    } finally {
      await document.dispose();
    }
  }
}

class _Request {
  _Request(this.book, this.pdfPath, this.api);

  final Book book;
  final String pdfPath;
  final ServerApi? api;
  final Completer<File?> done = Completer<File?>();
}
