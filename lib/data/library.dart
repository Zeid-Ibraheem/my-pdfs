import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../util/text.dart';
import 'book.dart';
import 'covers.dart';
import 'database.dart';
import 'server_api.dart';
import '../config.dart';

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
  Library._(this._db, this.booksDir, this.covers);

  AppDatabase _db;
  final String booksDir;

  /// Couvertures en images (voir covers.dart).
  final CoverCache covers;
  ServerApi? _api;
  String? _serverUrl;
  String? _serverToken;

  AppDatabase get db => _db;
  ServerApi? get api => _api;
  bool get hasServer => _api != null;
  String? get serverUrl => _serverUrl;
  String? get serverToken => _serverToken;

  static const _kUrl = SettingKeys.serverUrl;
  static const _kToken = SettingKeys.serverToken;
  static const _kAutoBackup = SettingKeys.autoBackup;
  static const _kAutoUpload = SettingKeys.autoUpload;
  static const _kLastBackup = SettingKeys.lastBackup;
  static const _kCacheGb = SettingKeys.cacheGb;

  static Future<Library> open() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'livres'));
    await dir.create(recursive: true);
    await _cleanPartialFiles(dir);
    final library = Library._(await AppDatabase.open(), dir.path,
        CoverCache(p.join(docs.path, 'couvertures')));
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
    _serverCompatible = false;
    notifyListeners();
    return usage;
  }

  Future<void> forgetServer() async {
    await _db.setSetting(_kUrl, '');
    await _db.setSetting(_kToken, '');
    await _loadServerConfig();
    notifyListeners();
  }

  Future<int>? _syncRunning;

  /// Synchronise avec le serveur : liste des livres, puis état partagé
  /// (pages, marque-pages, notes, catégories). Une seule synchro à la fois :
  /// un second appel attend la première. Renvoie le nombre de nouveaux livres.
  Future<int> syncWithServer() {
    final running = _syncRunning;
    if (running != null) return running;
    final future = _syncAll();
    _syncRunning = future;
    return future.whenComplete(() => _syncRunning = null);
  }

  DateTime? _lastSyncAttempt;

  /// Synchro silencieuse (retour dans l'appli, ouverture et fin de lecture) :
  /// ne lève jamais d'erreur et ne prend jamais plus de [timeout]. Avec
  /// [skipIfRecent], ne relance pas une synchro faite il y a moins longtemps
  /// (mais attend celle en cours, s'il y en a une).
  Future<void> syncQuietly({
    Duration timeout = const Duration(seconds: 15),
    Duration? skipIfRecent,
  }) async {
    if (!hasServer) return;
    final last = _lastSyncAttempt;
    if (_syncRunning == null &&
        skipIfRecent != null &&
        last != null &&
        DateTime.now().difference(last) < skipIfRecent) {
      return;
    }
    try {
      await syncWithServer().timeout(timeout);
    } catch (_) {
      // Hors connexion ou serveur éteint : on réessaiera plus tard.
    }
  }

  /// Le serveur a-t-il déjà été vérifié compatible pendant cette session ?
  bool _serverCompatible = false;

  /// Vérifie une fois par session que le serveur connaît toutes les routes
  /// utilisées par cette version de l'appli, avec un message clair sinon.
  Future<void> _ensureServerCompatible() async {
    if (_serverCompatible) return;
    final apiVersion = await _requireApi().apiVersion();
    if (apiVersion < AppInfo.minServerApi) {
      throw const ServerException(
          'Serveur pas à jour : sur le serveur, lance « cd ~/my-pdfs && '
          'git pull && cd server && ./install.sh »');
    }
    _serverCompatible = true;
  }

  Future<int> _syncAll() async {
    try {
      await _ensureServerCompatible();
      final added = await _syncBooks();
      await _syncState();
      notifyListeners();
      return added;
    } finally {
      _lastSyncAttempt = DateTime.now();
    }
  }

  static const _kSyncSeq = SettingKeys.syncSeq;
  static const _kSyncEpoch = SettingKeys.syncEpoch;

  /// Échange l'état partagé avec le serveur, par paquets de 500.
  Future<void> _syncState() async {
    final api = _requireApi();
    var since = int.tryParse(await _db.getSetting(_kSyncSeq) ?? '') ?? 0;
    var epoch = await _db.getSetting(_kSyncEpoch);
    if (epoch != null && epoch.isEmpty) epoch = null;
    for (var round = 0; round < 200; round++) {
      final outgoing = await _db.dirtyItems();
      final response =
          await api.syncState(since: since, epoch: epoch, changes: outgoing);
      if (response.wipe) {
        // Tout a été effacé depuis l'autre profil : on efface ici aussi,
        // sans renvoyer nos anciennes données au serveur.
        await _db.wipeReadingData(books: false);
        await _db.setSetting(_kLastBackup, '');
        since = 0;
        epoch = response.epoch;
        await _db.setSetting(_kSyncEpoch, epoch);
        await _db.setSetting(_kSyncSeq, '0');
        continue;
      }
      if (epoch != null && response.epoch != epoch) {
        // Base du serveur recréée : on lui renvoie tout ce qu'on a.
        await _db.markAllDirty();
        since = 0;
        epoch = response.epoch;
        await _db.setSetting(_kSyncEpoch, epoch);
        await _db.setSetting(_kSyncSeq, '0');
        continue;
      }
      await _db.markSent(outgoing);
      await _db.applyRemote(response.changes);
      since = response.seq;
      epoch = response.epoch;
      await _db.setSetting(_kSyncSeq, '$since');
      await _db.setSetting(_kSyncEpoch, epoch);
      if (!response.more && outgoing.length < 500) break;
    }
  }

  /// Ajoute à la bibliothèque les livres présents sur le serveur, retire
  /// ceux qui n'y sont plus (s'ils n'étaient pas sur le téléphone) et met à
  /// jour leur emplacement. Renvoie le nombre de nouveaux livres.
  Future<int> _syncBooks() async {
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
    final remoteIds = {for (final r in remote) r.id};
    for (final book in local.values) {
      // Supprimé du serveur (depuis l'autre profil) et absent du téléphone.
      if (book.onServer && !book.onDevice && !remoteIds.contains(book.id)) {
        await _db.deleteBook(book.id);
        await covers.remove(book.id);
      }
    }
    await _db.applyServerIds(remoteIds);
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
    await _downloadFile(book, onProgress: onProgress);
    await enforceCacheLimit(keepId: book.id);
    notifyListeners();
  }

  /// Télécharge le PDF (empreinte vérifiée) sans appliquer la limite de place.
  Future<void> _downloadFile(Book book, {ProgressCallback? onProgress}) async {
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
  }

  /// Livres qui ne sont que sur le serveur (à télécharger avant de le quitter).
  Future<List<Book>> serverOnlyBooks() async {
    if (hasServer) await _syncBooks();
    return (await _db.books())
        .where((b) => b.onServer && !b.onDevice)
        .toList();
  }

  /// Rapatrie sur le téléphone tous les livres absents, PUIS supprime
  /// absolument tout sur le serveur et oublie sa configuration.
  ///
  /// Sécurité : si un seul livre n'a pas pu être téléchargé (réseau, place),
  /// RIEN n'est supprimé sur le serveur. Notes, surlignages, catégories,
  /// carnet et progression restent sur le téléphone.
  Future<void> repatriateAndLeaveServer({ImportProgress? onProgress}) async {
    final api = _requireApi();
    if (await api.apiVersion() < 3) {
      // Vérifié AVANT de télécharger : un ancien serveur ne sait pas
      // s'effacer entièrement.
      throw const ServerException(
          'Serveur pas à jour : sur le serveur, lance « cd ~/my-pdfs && '
          'git pull && cd server && ./install.sh »');
    }
    final missing = await serverOnlyBooks();
    final failed = <String>[];
    for (var i = 0; i < missing.length; i++) {
      final book = missing[i];
      onProgress?.call(i, missing.length, book.title);
      try {
        await _downloadFile(book);
      } on ServerException {
        failed.add(book.title);
      } on FileSystemException {
        failed.add(book.title); // téléphone plein, par exemple
      }
    }
    for (final book in missing) {
      final file = File(pathOf(book));
      if (!await file.exists() || await file.length() == 0) {
        if (!failed.contains(book.title)) failed.add(book.title);
      }
    }
    if (failed.isNotEmpty) {
      notifyListeners();
      throw ServerException(
          '${failed.length} livre${failed.length > 1 ? 's' : ''} non '
          'téléchargé${failed.length > 1 ? 's' : ''} (${failed.take(3).join(', ')}'
          '${failed.length > 3 ? '…' : ''}). Rien n’a été supprimé sur le '
          'serveur : libère de la place ou vérifie la connexion, puis réessaie.');
    }

    onProgress?.call(missing.length, missing.length, 'Suppression sur le serveur…');
    await api.eraseAll();

    await _db.markAllOffServer();
    await _db.setSetting(_kSyncSeq, '0');
    await _db.setSetting(_kSyncEpoch, '');
    await _db.setSetting(_kLastBackup, '');
    await _db.setSetting(_kUrl, '');
    await _db.setSetting(_kToken, '');
    await _loadServerConfig();
    _serverCompatible = false;
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
    await covers.remove(book.id);
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

  // ------------------------------------------------------- Effacement

  /// Efface définitivement toutes les sauvegardes : sur le serveur (état
  /// synchronisé + sauvegardes quotidiennes) puis sur ce téléphone (notes,
  /// surlignages, marque-pages, catégories, pages en cours, fichiers
  /// temporaires). Avec [books], supprime aussi tous les livres, partout.
  ///
  /// Si un serveur est configuré et injoignable, rien n'est effacé (pour ne
  /// pas laisser le serveur renvoyer les données au prochain démarrage).
  Future<void> wipeEverything({required bool books}) async {
    final api = _api;
    String? newEpoch;
    if (api != null) newEpoch = await api.wipeEverything(books: books);

    await _db.wipeReadingData(books: books);
    await _db.setSetting(_kSyncSeq, '0');
    await _db.setSetting(_kSyncEpoch, newEpoch ?? '');
    await _db.setSetting(_kLastBackup, '');

    if (books) {
      for (final folder in [booksDir, covers.dir]) {
        final dir = Directory(folder);
        if (!await dir.exists()) continue;
        await for (final entry in dir.list()) {
          if (entry is File) await _deleteQuietly(entry);
        }
      }
    }
    // Copies temporaires : imports (file_picker), sauvegardes, restaurations.
    try {
      await FilePicker.clearTemporaryFiles();
    } catch (_) {
      // Rien à nettoyer.
    }
    final tmp = await getTemporaryDirectory();
    for (final name in ['my_pdfs-sauvegarde.db', 'restauration.db']) {
      await _deleteQuietly(File(p.join(tmp.path, name)));
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

  static Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Fichier déjà effacé ou verrouillé : sans conséquence pour la base.
    }
  }
}
