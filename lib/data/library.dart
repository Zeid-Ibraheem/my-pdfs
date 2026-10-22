import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../util/text.dart';
import 'book.dart';
import 'database.dart';

typedef ImportProgress = void Function(int index, int total, String name);

/// Résultat d'un import de plusieurs fichiers.
class ImportReport {
  int added = 0;
  int duplicates = 0;
  final List<String> failed = [];

  String get summary {
    final parts = <String>[];
    if (added > 0) parts.add('$added ajouté${added > 1 ? 's' : ''}');
    if (duplicates > 0) {
      parts.add('$duplicates déjà dans la bibliothèque');
    }
    if (failed.isNotEmpty) {
      parts.add('${failed.length} en échec (${failed.join(', ')})');
    }
    return parts.isEmpty ? 'Rien importé' : parts.join(' · ');
  }
}

enum _Outcome { added, duplicate, notPdf }

/// Gère les fichiers PDF : import, chemin sur le disque, suppression.
///
/// Les PDF sont copiés dans le dossier privé de l'appli, sous le nom
/// « <empreinte SHA-256>.pdf ». Le fichier d'origine n'est jamais modifié.
class Library {
  Library._(this.db, this.booksDir);

  final AppDatabase db;
  final String booksDir;

  static Future<Library> open() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'livres'));
    await dir.create(recursive: true);
    await _cleanPartialImports(dir);
    return Library._(await AppDatabase.open(), dir.path);
  }

  /// Supprime les copies interrompues (appli fermée pendant un import).
  static Future<void> _cleanPartialImports(Directory dir) async {
    await for (final entry in dir.list()) {
      if (entry is File && entry.path.endsWith('.part')) {
        await _deleteQuietly(entry);
      }
    }
  }

  String pathOf(Book book) => p.join(booksDir, book.fileName);

  Future<ImportReport> importFiles(
    List<PlatformFile> files, {
    ImportProgress? onProgress,
  }) async {
    final report = ImportReport();
    for (var i = 0; i < files.length; i++) {
      final file = files[i];
      onProgress?.call(i, files.length, file.name);
      try {
        switch (await _importOne(file)) {
          case _Outcome.added:
            report.added++;
          case _Outcome.duplicate:
            report.duplicates++;
          case _Outcome.notPdf:
            report.failed.add(file.name);
        }
      } catch (_) {
        report.failed.add(file.name);
      }
    }
    // file_picker garde une copie temporaire de chaque fichier choisi.
    try {
      await FilePicker.clearTemporaryFiles();
    } catch (_) {
      // Pas grave : Android vide aussi ce cache tout seul.
    }
    return report;
  }

  /// Copie le fichier dans la bibliothèque en calculant son empreinte
  /// au passage (une seule lecture du fichier, même pour 200 Mo).
  Future<_Outcome> _importOne(PlatformFile source) async {
    final tmp = File(p.join(
        booksDir, 'import-${DateTime.now().microsecondsSinceEpoch}.part'));
    final hashInput = StreamController<List<int>>();
    final digestFuture = sha256.bind(hashInput.stream).first;
    final header = <int>[];
    final sink = tmp.openWrite();

    var copied = false;
    try {
      await for (final chunk in source.readAsByteStream()) {
        if (header.length < 1024) {
          header.addAll(chunk.take(1024 - header.length));
        }
        hashInput.add(chunk);
        sink.add(chunk);
      }
      copied = true;
    } finally {
      await sink.close();
      await hashInput.close();
      if (!copied) await _deleteQuietly(tmp);
    }

    final id = (await digestFuture).toString();

    if (!looksLikePdf(header)) {
      await _deleteQuietly(tmp);
      return _Outcome.notPdf;
    }
    if (await db.book(id) != null) {
      await _deleteQuietly(tmp);
      return _Outcome.duplicate;
    }

    final fileName = '$id.pdf';
    final dest = File(p.join(booksDir, fileName));
    if (await dest.exists()) await dest.delete(); // reste d'une suppression ratée
    await tmp.rename(dest.path);

    await db.insertBook(Book(
      id: id,
      title: cleanTitle(source.name),
      fileName: fileName,
      sizeBytes: await dest.length(),
      pageCount: null,
      lastPage: 1,
      addedAt: DateTime.now(),
      lastOpenedAt: null,
    ));
    return _Outcome.added;
  }

  /// Supprime le livre, son fichier et ses marque-pages.
  Future<void> delete(Book book) async {
    await db.deleteBook(book.id);
    await _deleteQuietly(File(pathOf(book)));
  }

  static Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Fichier déjà effacé ou verrouillé : sans conséquence pour la base.
    }
  }
}
