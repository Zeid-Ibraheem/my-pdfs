import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../util/text.dart';
import 'book.dart';
import 'database.dart';
import 'server_api.dart';

typedef ImportProgress = void Function(int index, int total, String name);

/// Résultat d'un import de plusieurs fichiers.
class ImportReport {
  int get added => addedIds.length;
  int get duplicates => duplicateIds.length;
  final List<String> failed = [];

  /// Empreintes des livres ajoutés ou déjà présents
  /// (pour les ranger dans la catégorie affichée pendant l'import).
  final List<String> addedIds = [];
  final List<String> duplicateIds = [];

  /// Livres envoyés automatiquement sur le serveur.
  int uploaded = 0;

  String get summary {
    final parts = <String>[];
    if (added > 0) parts.add('$added ajouté${added > 1 ? 's' : ''}');
    if (duplicates > 0) {
      parts.add('$duplicates déjà dans la bibliothèque');
    }
    if (failed.isNotEmpty) {
      parts.add('${failed.length} en échec (${failed.join(', ')})');
    }
    if (uploaded > 0) {
      parts.add('$uploaded envoyé${uploaded > 1 ? 's' : ''} sur le serveur');
    }
    return parts.isEmpty ? 'Rien importé' : parts.join(' · ');
  }
}

enum _Status { added, duplicate, notPdf }

class _Outcome {
  const _Outcome(this.status, [this.id]);

  final _Status status;
  final String? id;
}

/// Gère les livres : fichiers sur le téléphone, serveur, sauvegardes.
///
/// Les PDF sont copiés dans le dossier privé de l'appli, sous le nom
/// « <empreinte SHA-256>.pdf ». Le fichier d'origine n'est jamais modifié.
/// Les écrans écoutent cet objet : il les prévient à chaque changement.
class Library extends ChangeNotifier {
  Library._(this._db, this.booksDir);

  AppDatabase _db;
  final String booksDir;
  ServerApi? _api;
  String? _serverUrl;
  String? _serverToken;

  AppDatabase get db => _db;
  ServerApi? get api => _api;
  bool get hasServer => _api != null;
  String? get serverUrl => _serverUrl;
  String? get serverToken => _serverToken;

  static const _kUrl = 'serveur_url';
  static const _kToken = 'serveur_jeton';
  static const _kAutoBackup = 'sauvegarde_auto';
  static const _kAutoUpload = 'envoi_auto';
  static const _kLastBackup = 'derniere_sauvegarde';
  static const _kCacheGb = 'cache_go';
  static const _kWatchDownloads = 'telechargements_auto';
  static const _kDeleteDownloads = 'telechargements_supprimer';

  /// Dossier Téléchargements du profil Android en cours.
  static const downloadsPath = '/storage/self/primary/Download';

  static Future<Library> open() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'livres'));
    await dir.create(recursive: true);
    await _cleanPartialFiles(dir);
    final library = Library._(await AppDatabase.open(), dir.path);
    await library._loadServerConfig();
    await library._reconcileFiles();
    return library;
  }

  /// Supprime les copies interrompues (appli fermée pendant un transfert).
  static Future<void> _cleanPartialFiles(Directory dir) async {
    await for (final entry in dir.list()) {
      if (entry is File && entry.path.endsWith('.part')) {
        await _deleteQuietly(entry);
      }
    }
  }

  String pathOf(Book book) => p.join(booksDir, book.fileName);

  /// Prévient les écrans qu'il faut se rafraîchir (après une lecture, par ex.).
  void refresh() => notifyListeners();

  /// Remet « sur le téléphone » en accord avec les fichiers réellement
  /// présents (utile après une restauration ou un fichier effacé).
  Future<void> _reconcileFiles() async {
    for (final book in await _db.books()) {
      final exists = await File(pathOf(book)).exists();
      if (exists != book.onDevice) await _db.setOnDevice(book.id, exists);
    }
  }

  ServerApi _requireApi() {
    final api = _api;
    if (api == null) {
      throw const ServerException(
          'Serveur non configuré : renseigne-le dans l’onglet Réglages');
    }
    return api;
  }

  // ------------------------------------------------------------- Serveur

  Future<void> _loadServerConfig() async {
    _serverUrl = await _db.getSetting(_kUrl);
    _serverToken = await _db.getSetting(_kToken);
    final url = _serverUrl, token = _serverToken;
    _api = (url != null && url.isNotEmpty && token != null && token.isNotEmpty)
        ? ServerApi(baseUrl: url, token: token)
        : null;
  }

  /// « 100.1.2.3:8765/ » → « http://100.1.2.3:8765 ».
  static String normalizeServerUrl(String input) {
    var url = input.trim();
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    if (url.isNotEmpty && !url.contains('://')) url = 'http://$url';
    return url;
  }

  /// Teste puis enregistre l'adresse et le jeton. Lève ServerException
  /// si le serveur ne répond pas ou refuse le jeton.
  Future<ServerUsage> saveServerConfig(String url, String token) async {
    final cleanUrl = normalizeServerUrl(url);
    final cleanToken = token.trim();
    final api = ServerApi(baseUrl: cleanUrl, token: cleanToken);
    final usage = await api.check();
    await _db.setSetting(_kUrl, cleanUrl);
    await _db.setSetting(_kToken, cleanToken);
    await _loadServerConfig();
    notifyListeners();
    return usage;
  }

  Future<void> forgetServer() async {
    await _db.setSetting(_kUrl, '');
    await _db.setSetting(_kToken, '');
    await _loadServerConfig();
    notifyListeners();
  }

  /// Ajoute à la bibliothèque les livres présents sur le serveur et met à
  /// jour leur emplacement. Renvoie le nombre de nouveaux livres.
  Future<int> syncWithServer() async {
    final api = _requireApi();
    final remote = await api.books();
    final local = {for (final b in await _db.books()) b.id: b};
    var added = 0;
    for (final r in remote) {
      final existing = local[r.id];
      if (existing == null) {
        await _db.insertBook(Book(
          id: r.id,
          title: r.title,
          fileName: '${r.id}.pdf',
          sizeBytes: r.sizeBytes,
          pageCount: r.pageCount,
          lastPage: 1,
          addedAt: r.addedAt,
          lastOpenedAt: null,
          onDevice: false,
          onServer: true,
        ));
        added++;
      } else if (existing.pageCount == null && r.pageCount != null) {
        await _db.setPageCount(r.id, r.pageCount!);
      }
    }
    await _db.applyServerIds({for (final r in remote) r.id});
    notifyListeners();
    return added;
  }

  Future<void> uploadBook(Book book, {ProgressCallback? onProgress}) async {
    final api = _requireApi();
    await api.upload(book.id, book.title, File(pathOf(book)),
        onProgress: onProgress);
    await _db.setOnServer(book.id, true);
    notifyListeners();
  }

  /// Envoie sur le serveur tous les livres qui ne sont que sur le téléphone.
  Future<(int, int)> uploadAll({ImportProgress? onProgress}) async {
    _requireApi();
    final pending =
        (await _db.books()).where((b) => b.onDevice && !b.onServer).toList();
    var sent = 0;
    var failed = 0;
    for (var i = 0; i < pending.length; i++) {
      onProgress?.call(i, pending.length, pending[i].title);
      try {
        await uploadBook(pending[i]);
        sent++;
      } on ServerException {
        failed++;
      }
    }
    return (sent, failed);
  }

  /// Télécharge sur le téléphone un livre qui n'est que sur le serveur.
  Future<void> downloadBook(Book book, {ProgressCallback? onProgress}) async {
    final api = _requireApi();
    final tmp = File(p.join(
        booksDir, 'dl-${DateTime.now().microsecondsSinceEpoch}.part'));
    try {
      await api.download(book.id, tmp,
          expectedSize: book.sizeBytes, onProgress: onProgress);
      await tmp.rename(pathOf(book));
    } finally {
      await _deleteQuietly(tmp);
    }
    await _db.setOnDevice(book.id, true);
    await enforceCacheLimit(keepId: book.id);
    notifyListeners();
  }

  /// Retire le fichier du téléphone ; il reste sur le serveur.
  Future<void> freeSpace(Book book) async {
    if (!book.onServer) return;
    await _deleteQuietly(File(pathOf(book)));
    await _db.setOnDevice(book.id, false);
    notifyListeners();
  }

  Future<void> setPinned(Book book, bool pinned) async {
    await _db.setPinned(book.id, pinned);
    notifyListeners();
  }

  Future<void> renameBook(Book book, String title) async {
    await _db.renameBook(book.id, title);
    if (book.onServer && hasServer) {
      try {
        await _api!.rename(book.id, title);
      } on ServerException {
        // Le titre du serveur ne sert qu'à l'affichage : pas bloquant.
      }
    }
    notifyListeners();
  }

  /// Supprime le livre, ses marque-pages et ses annotations, sur le
  /// téléphone et (si [fromServer]) sur le serveur.
  Future<void> deleteBook(Book book, {bool fromServer = true}) async {
    if (fromServer && book.onServer) {
      await _requireApi().delete(book.id);
    }
    await _db.deleteBook(book.id);
    await _deleteQuietly(File(pathOf(book)));
    notifyListeners();
  }

  // ---------------------------------------------- Place sur le téléphone

  /// Limite de place pour les livres du serveur gardés sur le téléphone.
  Future<int> cacheLimitGb() async =>
      int.tryParse(await _db.getSetting(_kCacheGb) ?? '') ?? 5;

  Future<void> setCacheLimitGb(int gb) async {
    await _db.setSetting(_kCacheGb, '$gb');
    await enforceCacheLimit();
    notifyListeners();
  }

  /// Si les livres du serveur gardés sur le téléphone dépassent la limite,
  /// retire les moins récemment lus (jamais les livres épinglés, ni ceux
  /// qui ne sont que sur le téléphone). Renvoie le nombre de livres retirés.
  Future<int> enforceCacheLimit({String? keepId}) async {
    final limit = (await cacheLimitGb()) * 1024 * 1024 * 1024;
    final cached =
        (await _db.books()).where((b) => b.onDevice && b.onServer).toList();
    var total = cached.fold<int>(0, (sum, b) => sum + b.sizeBytes);
    if (total <= limit) return 0;
    final candidates = cached
        .where((b) => !b.pinned && b.id != keepId)
        .toList()
      ..sort((a, b) =>
          (a.lastOpenedAt ?? a.addedAt).compareTo(b.lastOpenedAt ?? b.addedAt));
    var removed = 0;
    for (final book in candidates) {
      if (total <= limit) break;
      await _deleteQuietly(File(pathOf(book)));
      await _db.setOnDevice(book.id, false);
      total -= book.sizeBytes;
      removed++;
    }
    return removed;
  }

  /// Place utilisée sur le téléphone : (livres seulement ici, copies du serveur).
  Future<(int, int)> deviceUsage() async {
    var localOnly = 0;
    var cached = 0;
    for (final b in await _db.books()) {
      if (!b.onDevice) continue;
      if (b.onServer) {
        cached += b.sizeBytes;
      } else {
        localOnly += b.sizeBytes;
      }
    }
    return (localOnly, cached);
  }

  // ---------------------------------------------------------- Sauvegarde

  Future<bool> autoBackupEnabled() async =>
      await _db.getSetting(_kAutoBackup) != '0';

  Future<void> setAutoBackup(bool enabled) =>
      _db.setSetting(_kAutoBackup, enabled ? '1' : '0');

  /// Désactivé par défaut : un livre importé reste sur le téléphone tant
  /// qu'on ne demande pas de l'envoyer sur le serveur.
  Future<bool> autoUploadEnabled() async =>
      await _db.getSetting(_kAutoUpload) == '1';

  Future<void> setAutoUpload(bool enabled) =>
      _db.setSetting(_kAutoUpload, enabled ? '1' : '0');

  Future<DateTime?> lastBackup() async {
    final ms = int.tryParse(await _db.getSetting(_kLastBackup) ?? '');
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  /// Envoie une copie de la base (catégories, notes, progression…).
  Future<void> backupNow() async {
    final api = _requireApi();
    final tmpDir = await getTemporaryDirectory();
    final copy = File(p.join(tmpDir.path, 'my_pdfs-sauvegarde.db'));
    await _db.exportTo(copy.path);
    try {
      await api.uploadBackup(copy);
    } finally {
      await _deleteQuietly(copy);
    }
    await _db.setSetting(
        _kLastBackup, '${DateTime.now().millisecondsSinceEpoch}');
  }

  /// Sauvegarde silencieuse après une séance de lecture.
  Future<void> autoBackup() async {
    if (!hasServer || !await autoBackupEnabled()) return;
    try {
      await backupNow();
    } on ServerException {
      // Serveur injoignable : on réessaiera après la prochaine lecture.
    }
  }

  /// Remplace la base du téléphone par la dernière sauvegarde du serveur.
  /// Les PDF absents du téléphone seront retéléchargés à l'ouverture.
  Future<void> restoreLatestBackup() async {
    final api = _requireApi();
    final tmpDir = await getTemporaryDirectory();
    final download = File(p.join(tmpDir.path, 'restauration.db'));
    await api.downloadLatestBackup(download);
    final header = await download
        .openRead(0, 15)
        .fold<List<int>>(<int>[], (bytes, chunk) => bytes..addAll(chunk));
    if (String.fromCharCodes(header) != 'SQLite format 3') {
      await _deleteQuietly(download);
      throw const ServerException('La sauvegarde reçue est invalide');
    }

    final url = _serverUrl;
    final token = _serverToken;
    final path = _db.path;
    await _db.close();
    await download.copy(path);
    await _deleteQuietly(download);
    for (final suffix in ['-wal', '-shm', '-journal']) {
      await _deleteQuietly(File('$path$suffix'));
    }
    _db = await AppDatabase.open();
    // On garde la connexion actuelle au serveur, même si la sauvegarde
    // contenait une autre adresse.
    if (url != null && token != null) {
      await _db.setSetting(_kUrl, url);
      await _db.setSetting(_kToken, token);
    }
    await _loadServerConfig();
    await _reconcileFiles();
    try {
      await syncWithServer();
    } on ServerException {
      // Pas grave : la synchro se refera au prochain rafraîchissement.
    }
    notifyListeners();
  }

  // -------------------------------------------------------------- Import

  Future<ImportReport> importFiles(
    List<PlatformFile> files, {
    ImportProgress? onProgress,
  }) async {
    final report = ImportReport();
    for (var i = 0; i < files.length; i++) {
      final file = files[i];
      onProgress?.call(i, files.length, file.name);
      try {
        final outcome = await _importStream(file.name, file.readAsByteStream());
        switch (outcome.status) {
          case _Status.added:
            report.addedIds.add(outcome.id!);
          case _Status.duplicate:
            report.duplicateIds.add(outcome.id!);
          case _Status.notPdf:
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

    // Envoi automatique des nouveaux livres sur le serveur.
    if (hasServer && report.addedIds.isNotEmpty && await autoUploadEnabled()) {
      for (var i = 0; i < report.addedIds.length; i++) {
        final book = await _db.book(report.addedIds[i]);
        if (book == null) continue;
        onProgress?.call(i, report.addedIds.length, 'Envoi : ${book.title}');
        try {
          await uploadBook(book);
          report.uploaded++;
        } on ServerException {
          // Serveur injoignable : le livre reste sur le téléphone, on pourra
          // l'envoyer plus tard depuis les Réglages.
        }
      }
    }
    notifyListeners();
    return report;
  }

  /// Copie le fichier dans la bibliothèque en calculant son empreinte
  /// au passage (une seule lecture du fichier, même pour 200 Mo).
  Future<_Outcome> _importStream(String name, Stream<List<int>> bytes) async {
    final tmp = File(p.join(
        booksDir, 'import-${DateTime.now().microsecondsSinceEpoch}.part'));
    final hashInput = StreamController<List<int>>();
    final digestFuture = sha256.bind(hashInput.stream).first;
    final header = <int>[];
    final sink = tmp.openWrite();

    var copied = false;
    try {
      await for (final chunk in bytes) {
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
      return const _Outcome(_Status.notPdf);
    }
    final existing = await _db.book(id);
    if (existing != null) {
      if (existing.onDevice) {
        await _deleteQuietly(tmp);
      } else {
        // Le livre n'était que sur le serveur : on garde ce fichier.
        await tmp.rename(pathOf(existing));
        await _db.setOnDevice(id, true);
      }
      return _Outcome(_Status.duplicate, id);
    }

    final fileName = '$id.pdf';
    final dest = File(p.join(booksDir, fileName));
    if (await dest.exists()) await dest.delete(); // reste d'une suppression ratée
    await tmp.rename(dest.path);

    await _db.insertBook(Book(
      id: id,
      title: cleanTitle(name),
      fileName: fileName,
      sizeBytes: await dest.length(),
      pageCount: null,
      lastPage: 1,
      addedAt: DateTime.now(),
      lastOpenedAt: null,
    ));
    return _Outcome(_Status.added, id);
  }

  // --------------------------------------------- Dossier Téléchargements

  Future<bool> watchDownloadsEnabled() async =>
      await _db.getSetting(_kWatchDownloads) == '1';

  Future<void> setWatchDownloads(bool enabled) =>
      _db.setSetting(_kWatchDownloads, enabled ? '1' : '0');

  Future<bool> deleteDownloadsAfterImport() async =>
      await _db.getSetting(_kDeleteDownloads) == '1';

  Future<void> setDeleteDownloadsAfterImport(bool enabled) =>
      _db.setSetting(_kDeleteDownloads, enabled ? '1' : '0');

  /// Marque comme déjà vus tous les PDF actuellement dans Téléchargements,
  /// pour que l'activation de l'option n'importe pas tout l'historique.
  Future<int> ignoreCurrentDownloads() async {
    final files = await _pendingDownloads();
    for (final (file, signature) in files) {
      await _db.markDownloadSeen(file.path, signature);
    }
    return files.length;
  }

  /// Nombre de PDF de Téléchargements pas encore importés.
  Future<int> pendingDownloadsCount() async =>
      (await _pendingDownloads()).length;

  /// PDF du dossier Téléchargements pas encore importés.
  Future<List<(File, String)>> _pendingDownloads() async {
    final dir = Directory(downloadsPath);
    if (!await dir.exists()) return const [];
    final seen = await _db.seenDownloads();
    final found = <(File, String)>[];
    final now = DateTime.now();
    final entries = dir
        .list(recursive: true, followLinks: false)
        .handleError((Object _) {}); // sous-dossier illisible : on l'ignore
    await for (final entry in entries) {
      if (entry is! File) continue;
      final name = p.basename(entry.path);
      if (name.startsWith('.') || !name.toLowerCase().endsWith('.pdf')) {
        continue;
      }
      final stat = await entry.stat();
      // Fichier modifié il y a moins de 5 s : téléchargement peut-être en cours.
      if (now.difference(stat.modified) < const Duration(seconds: 5)) continue;
      final signature = '${stat.size}:${stat.modified.millisecondsSinceEpoch}';
      if (seen[entry.path] == signature) continue;
      found.add((entry, signature));
    }
    return found;
  }

  /// Importe les nouveaux PDF du dossier Téléchargements (sur le téléphone
  /// seulement). Nécessite l'accès à tous les fichiers.
  Future<ImportReport> importFromDownloads() async {
    final report = ImportReport();
    final deleteAfter = await deleteDownloadsAfterImport();
    for (final (file, signature) in await _pendingDownloads()) {
      try {
        final outcome =
            await _importStream(p.basename(file.path), file.openRead());
        switch (outcome.status) {
          case _Status.added:
            report.addedIds.add(outcome.id!);
          case _Status.duplicate:
            report.duplicateIds.add(outcome.id!);
          case _Status.notPdf:
            report.failed.add(p.basename(file.path));
        }
        await _db.markDownloadSeen(file.path, signature);
        if (deleteAfter && outcome.status != _Status.notPdf) {
          await _deleteQuietly(file);
        }
      } catch (_) {
        report.failed.add(p.basename(file.path));
      }
    }
    if (report.added > 0 || report.duplicates > 0) notifyListeners();
    return report;
  }

  static Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Fichier déjà effacé ou verrouillé : sans conséquence pour la base.
    }
  }
}
