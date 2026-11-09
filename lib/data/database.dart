import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../util/text.dart';
import 'annotation.dart';
import 'book.dart';
import 'category.dart';
import 'reading_entry.dart';
import 'sync_item.dart';

/// Base SQLite locale : livres, marque-pages, catégories, annotations,
/// réglages et état à synchroniser.
///
/// Versions du schéma :
/// 1. livres, marque-pages, réglages
/// 2. catégories et annotations (surlignages, notes)
/// 3. emplacement des livres (téléphone / serveur) et épinglage
/// 4. table d'une ancienne option (import depuis Téléchargements), retirée ;
///    gardée pour qu'une base déjà mise à jour s'ouvre toujours
/// 5. synchronisation entre profils : identifiants globaux des catégories et
///    annotations, table sync_items (miroir de l'état du serveur)
/// 6. carnet de lectures (livres lus, en cours, à lire, avec note et avis)
/// 7. temps de lecture par livre
///
/// Chaque modification synchronisable (page, marque-page, note, catégorie,
/// titre) écrit aussi un élément dans sync_items, marqué « à envoyer ».
class AppDatabase {
  AppDatabase._(this._db, this.path);

  final Database _db;

  /// Chemin du fichier de la base (pour la sauvegarde et la restauration).
  final String path;

  static const fileName = 'my_pdfs.db';

  static Future<String> defaultPath() async =>
      p.join(await getDatabasesPath(), fileName);

  static Future<AppDatabase> open() async {
    final path = await defaultPath();
    final db = await openDatabase(
      path,
      version: 7,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
      },
      onCreate: (db, version) async {
        await _createV1(db);
        await _createV2(db);
        await _createV3(db);
        await _createV4(db);
        await _createV5(db);
        await _createV6(db);
        await _createV7(db);
      },
      // Mise à jour d'une appli déjà installée : on ajoute ce qui manque
      // sans toucher aux livres, marque-pages et annotations existants.
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) await _createV2(db);
        if (oldVersion < 3) await _createV3(db);
        if (oldVersion < 4) await _createV4(db);
        if (oldVersion < 5) await _createV5(db);
        if (oldVersion < 6) await _createV6(db);
        if (oldVersion < 7) await _createV7(db);
      },
    );
    return AppDatabase._(db, path);
  }

  Future<void> close() => _db.close();

  /// Copie cohérente de la base dans [dest] (même pendant l'utilisation).
  Future<void> exportTo(String dest) async {
    final file = File(dest);
    if (await file.exists()) await file.delete();
    try {
      await _db.execute('VACUUM INTO ?', [dest]);
    } catch (_) {
      // SQLite trop ancien pour VACUUM INTO : simple copie du fichier.
      await File(path).copy(dest);
    }
  }

  static int _now() => DateTime.now().millisecondsSinceEpoch;

  /// Clé d'une catégorie, identique sur tous les profils pour un même nom
  /// (« Réseau » et « reseau » donnent la même catégorie).
  static String categoryKey(String name) =>
      normalizeForSearch(name.trim()).replaceAll(RegExp(r'\s+'), ' ');

  // ---------------------------------------------------------------- Schéma

  static Future<void> _createV1(Database db) async {
    await db.execute('''
      CREATE TABLE books (
        id             TEXT PRIMARY KEY,
        title          TEXT NOT NULL,
        file_name      TEXT NOT NULL,
        size_bytes     INTEGER NOT NULL,
        page_count     INTEGER,
        last_page      INTEGER NOT NULL DEFAULT 1,
        added_at       INTEGER NOT NULL,
        last_opened_at INTEGER
      )
    ''');
    await db.execute('''
      CREATE TABLE bookmarks (
        book_id    TEXT NOT NULL REFERENCES books(id) ON DELETE CASCADE,
        page       INTEGER NOT NULL,
        created_at INTEGER NOT NULL,
        PRIMARY KEY (book_id, page)
      )
    ''');
    await db.execute('''
      CREATE TABLE settings (
        key   TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');
  }

  static Future<void> _createV2(Database db) async {
    await db.execute('''
      CREATE TABLE categories (
        id         INTEGER PRIMARY KEY AUTOINCREMENT,
        name       TEXT NOT NULL,
        created_at INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE book_categories (
        book_id     TEXT NOT NULL REFERENCES books(id) ON DELETE CASCADE,
        category_id INTEGER NOT NULL REFERENCES categories(id) ON DELETE CASCADE,
        PRIMARY KEY (book_id, category_id)
      )
    ''');
    await db.execute('''
      CREATE TABLE annotations (
        id         INTEGER PRIMARY KEY AUTOINCREMENT,
        book_id    TEXT NOT NULL REFERENCES books(id) ON DELETE CASCADE,
        page       INTEGER NOT NULL,
        quote      TEXT,
        rects      TEXT,
        color      INTEGER,
        note       TEXT NOT NULL DEFAULT '',
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');
    await db.execute(
        'CREATE INDEX annotations_by_book ON annotations (book_id, page)');
  }

  static Future<void> _createV3(Database db) async {
    await db.execute(
        'ALTER TABLE books ADD COLUMN on_device INTEGER NOT NULL DEFAULT 1');
    await db.execute(
        'ALTER TABLE books ADD COLUMN on_server INTEGER NOT NULL DEFAULT 0');
    await db.execute(
        'ALTER TABLE books ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0');
  }

  static Future<void> _createV4(Database db) async {
    await db.execute('''
      CREATE TABLE seen_downloads (
        path      TEXT PRIMARY KEY,
        signature TEXT NOT NULL
      )
    ''');
  }

  /// Version 5 : prépare la synchronisation, puis enregistre tout l'état
  /// existant comme « à envoyer » pour qu'il rejoigne celui des autres
  /// profils à la première synchro (la version la plus récente gagne).
  static Future<void> _createV5(Database db) async {
    await db.execute('ALTER TABLE categories ADD COLUMN uid TEXT');
    await db.execute('ALTER TABLE annotations ADD COLUMN uid TEXT');
    await db.execute('''
      CREATE TABLE sync_items (
        kind       TEXT NOT NULL,
        key        TEXT NOT NULL,
        data       TEXT NOT NULL,
        updated_at INTEGER NOT NULL,
        deleted    INTEGER NOT NULL DEFAULT 0,
        dirty      INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (kind, key)
      )
    ''');
    await db.execute('CREATE INDEX sync_items_dirty ON sync_items (dirty)');

    // Catégories : clé tirée du nom ; deux catégories au même nom (accents
    // ou majuscules près) sont fusionnées.
    final byKey = <String, int>{};
    for (final row in await db.query('categories', orderBy: 'id ASC')) {
      final id = row['id'] as int;
      final key = categoryKey(row['name'] as String);
      final keep = byKey[key];
      if (keep == null) {
        byKey[key] = id;
        await db.update('categories', {'uid': key},
            where: 'id = ?', whereArgs: [id]);
      } else {
        await db.rawInsert(
            'INSERT OR IGNORE INTO book_categories (book_id, category_id) '
            'SELECT book_id, ? FROM book_categories WHERE category_id = ?',
            [keep, id]);
        await db.delete('book_categories',
            where: 'category_id = ?', whereArgs: [id]);
        await db.delete('categories', where: 'id = ?', whereArgs: [id]);
      }
    }
    for (final row in await db.query('annotations', columns: ['id'])) {
      await db.update('annotations', {'uid': newUid()},
          where: 'id = ?', whereArgs: [row['id']]);
    }
    await db.execute('CREATE UNIQUE INDEX categories_uid ON categories (uid)');
    await db.execute('CREATE UNIQUE INDEX annotations_uid ON annotations (uid)');

    Future<void> seed(String kind, String key, Map<String, Object?> data,
        int updatedAt) async {
      await db.insert(
          'sync_items',
          {
            'kind': kind,
            'key': key,
            'data': jsonEncode(data),
            'updated_at': updatedAt,
            'deleted': 0,
            'dirty': 1,
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
    }

    for (final row in await db.query('books')) {
      final opened = row['last_opened_at'] as int?;
      if (opened == null) continue; // jamais ouvert : rien à partager
      await seed('progress', row['id'] as String,
          {'page': row['last_page'], 'opened': opened}, opened);
    }
    for (final row in await db.query('bookmarks')) {
      await seed('bookmark', '${row['book_id']}|${row['page']}', const {},
          row['created_at'] as int);
    }
    final catCreated = <int, int>{};
    for (final row in await db.query('categories')) {
      catCreated[row['id'] as int] = row['created_at'] as int;
      await seed('category', row['uid'] as String, {'name': row['name']},
          row['created_at'] as int);
    }
    final catUid = {
      for (final row in await db.query('categories'))
        row['id'] as int: row['uid'] as String,
    };
    for (final row in await db.query('book_categories')) {
      final categoryId = row['category_id'] as int;
      final uid = catUid[categoryId];
      if (uid == null) continue;
      await seed('bookcat', '${row['book_id']}|$uid', const {},
          catCreated[categoryId] ?? 1);
    }
    for (final row in await db.query('annotations')) {
      await seed('annotation', row['uid'] as String, _annotationData(row),
          row['updated_at'] as int);
    }
  }

  /// Version 6 : carnet de lectures. Chaque livre déjà présent y entre
  /// automatiquement, avec un statut déduit de sa progression.
  static Future<void> _createV6(Database db) async {
    await db.execute('''
      CREATE TABLE reading_list (
        uid         TEXT PRIMARY KEY,
        title       TEXT NOT NULL,
        author      TEXT NOT NULL DEFAULT '',
        rating      INTEGER NOT NULL DEFAULT 0,
        review      TEXT NOT NULL DEFAULT '',
        status      TEXT NOT NULL DEFAULT 'toread',
        finished_at INTEGER,
        book_id     TEXT,
        created_at  INTEGER NOT NULL,
        updated_at  INTEGER NOT NULL
      )
    ''');
    for (final row in await db.query('books')) {
      final book = Book.fromRow(row);
      final status = book.finished
          ? ReadingStatus.read
          : book.started
              ? ReadingStatus.reading
              : ReadingStatus.toRead;
      await _autoEntry(db, book, status);
    }
  }

  /// Version 7 : temps de lecture par livre.
  static Future<void> _createV7(Database db) async {
    await db.execute(
        'ALTER TABLE books ADD COLUMN read_seconds INTEGER NOT NULL DEFAULT 0');
  }

  /// Entrée automatique d'un livre importé. Datée de 1 (la plus ancienne
  /// possible) : toute vraie modification, sur n'importe quel profil, gagne
  /// contre elle à la synchro. N'écrase jamais une entrée existante ni une
  /// entrée supprimée volontairement.
  static Future<void> _autoEntry(
      DatabaseExecutor ex, Book book, ReadingStatus status) async {
    final key = ReadingEntry.keyForBook(book.id);
    final known = await ex.query('sync_items',
        columns: ['kind'],
        where: "kind = 'readlog' AND key = ?",
        whereArgs: [key],
        limit: 1);
    final exists = await ex.query('reading_list',
        columns: ['uid'], where: 'uid = ?', whereArgs: [key], limit: 1);
    if (known.isNotEmpty || exists.isNotEmpty) return;
    final entry = ReadingEntry(
      uid: key,
      title: book.title,
      status: status,
      finishedAt: status == ReadingStatus.read ? book.lastOpenedAt : null,
      bookId: book.id,
      createdAt: book.addedAt,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(1),
    );
    await ex.insert('reading_list', entry.toRow());
    await ex.insert(
        'sync_items',
        {
          'kind': 'readlog',
          'key': key,
          'data': jsonEncode(entry.toRow()),
          'updated_at': 1,
          'deleted': 0,
          'dirty': 1,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  static Map<String, Object?> _annotationData(Map<String, Object?> row) => {
        'book_id': row['book_id'],
        'page': row['page'],
        'quote': row['quote'],
        'rects': row['rects'],
        'color': row['color'],
        'note': row['note'],
        'created_at': row['created_at'],
      };

  // ------------------------------------------------- Suivi des changements

  /// Note une modification locale à envoyer au serveur.
  Future<void> _record(
    DatabaseExecutor ex,
    String kind,
    String key,
    Map<String, Object?> data, {
    bool deleted = false,
  }) async {
    await ex.insert(
        'sync_items',
        {
          'kind': kind,
          'key': key,
          'data': jsonEncode(data),
          'updated_at': _now(),
          'deleted': deleted ? 1 : 0,
          'dirty': 1,
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<bool> _bookExists(DatabaseExecutor ex, String id) async =>
      (await ex.query('books',
              columns: ['id'], where: 'id = ?', whereArgs: [id], limit: 1))
          .isNotEmpty;

  // ---------------------------------------------------------------- Livres

  /// Tous les livres (le tri se fait ensuite avec sortBooks).
  Future<List<Book>> books() async {
    final rows = await _db.query('books');
    return rows.map(Book.fromRow).toList();
  }

  Future<Book?> book(String id) async {
    final rows =
        await _db.query('books', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : Book.fromRow(rows.first);
  }

  /// Ajoute un livre, puis lui applique l'état déjà reçu des autres profils
  /// (page en cours, notes, catégories…) pour ce même fichier.
  Future<void> insertBook(Book book) async {
    await _db.transaction((txn) async {
      await txn.insert('books', book.toRow());
      await _reapplyForBook(txn, book.id);
      await _autoEntry(txn, book, ReadingStatus.toRead);
    });
  }

  Future<void> renameBook(String id, String title) async {
    await _db.transaction((txn) async {
      await txn.update('books', {'title': title},
          where: 'id = ?', whereArgs: [id]);
      await _record(txn, 'title', id, {'title': title});
      // Le titre suit dans le carnet de lectures.
      final rows = await txn.query('reading_list',
          where: 'uid = ?', whereArgs: [ReadingEntry.keyForBook(id)], limit: 1);
      if (rows.isNotEmpty) {
        await _writeEntry(
            txn, ReadingEntry.fromRow(rows.first).copyWith(title: title));
      }
    });
  }

  /// Supprime le livre de ce profil. Son état synchronisé est gardé : si le
  /// livre revient (réimport, serveur), il retrouve ses notes.
  Future<void> deleteBook(String id) async {
    await _db.transaction((txn) async {
      for (final table in ['bookmarks', 'book_categories', 'annotations']) {
        await txn.delete(table, where: 'book_id = ?', whereArgs: [id]);
      }
      await txn.delete('books', where: 'id = ?', whereArgs: [id]);
    });
  }

  Future<void> setPageCount(String id, int count) async {
    await _db.update('books', {'page_count': count},
        where: 'id = ?', whereArgs: [id]);
  }

  /// Enregistre la page en cours. Rien n'est envoyé si elle n'a pas changé :
  /// ouvrir un livre sans bouger n'écrase pas la page lue sur l'autre profil.
  Future<void> saveLastPage(String id, int page) async {
    await _db.transaction((txn) async {
      final rows = await txn.query('books',
          columns: ['last_page', 'last_opened_at', 'page_count'],
          where: 'id = ?',
          whereArgs: [id],
          limit: 1);
      if (rows.isEmpty || rows.first['last_page'] == page) return;
      await txn.update('books', {'last_page': page},
          where: 'id = ?', whereArgs: [id]);
      await _record(txn, 'progress', id,
          {'page': page, 'opened': rows.first['last_opened_at'] ?? _now()});
      // Dernière page atteinte : le livre passe en « Lu » dans le carnet.
      final count = rows.first['page_count'] as int?;
      if (count != null && count > 0 && page >= count) {
        await _setEntryStatus(txn, id, ReadingStatus.read);
      }
    });
  }

  Future<void> setOnDevice(String id, bool value) async {
    await _db.update('books', {'on_device': value ? 1 : 0},
        where: 'id = ?', whereArgs: [id]);
  }

  Future<void> setOnServer(String id, bool value) async {
    await _db.update('books', {'on_server': value ? 1 : 0},
        where: 'id = ?', whereArgs: [id]);
  }

  Future<void> setPinned(String id, bool value) async {
    await _db.update('books', {'pinned': value ? 1 : 0},
        where: 'id = ?', whereArgs: [id]);
  }

  /// Met à jour « sur le serveur » pour tous les livres d'un coup.
  Future<void> applyServerIds(Set<String> serverIds) async {
    await _db.transaction((txn) async {
      await txn.rawUpdate('UPDATE books SET on_server = 0');
      final ids = serverIds.toList();
      for (var i = 0; i < ids.length; i += 400) {
        final chunk =
            ids.sublist(i, i + 400 > ids.length ? ids.length : i + 400);
        final marks = List.filled(chunk.length, '?').join(', ');
        await txn.rawUpdate(
            'UPDATE books SET on_server = 1 WHERE id IN ($marks)', chunk);
      }
    });
  }

  /// Ajoute du temps de lecture à un livre.
  Future<void> addReadingTime(String id, int seconds) async {
    if (seconds <= 0) return;
    await _db.rawUpdate(
        'UPDATE books SET read_seconds = read_seconds + ? WHERE id = ?',
        [seconds, id]);
  }

  Future<void> markOpened(String id) async {
    await _db.transaction((txn) async {
      await txn.update('books', {'last_opened_at': _now()},
          where: 'id = ?', whereArgs: [id]);
      await _setEntryStatus(txn, id, ReadingStatus.reading,
          onlyFrom: ReadingStatus.toRead);
    });
  }

  /// Change le statut de l'entrée automatique d'un livre (ouvert → « En
  /// cours », fini → « Lu »), sans toucher à une entrée déjà dans ce statut.
  Future<void> _setEntryStatus(
    DatabaseExecutor ex,
    String bookId,
    ReadingStatus status, {
    ReadingStatus? onlyFrom,
  }) async {
    final rows = await ex.query('reading_list',
        where: 'uid = ?',
        whereArgs: [ReadingEntry.keyForBook(bookId)],
        limit: 1);
    if (rows.isEmpty) return;
    final entry = ReadingEntry.fromRow(rows.first);
    if (entry.status == status) return;
    if (onlyFrom != null && entry.status != onlyFrom) return;
    final updated = entry.copyWith(
      status: status,
      finishedAt: status == ReadingStatus.read ? DateTime.now() : null,
      clearFinishedAt: status != ReadingStatus.read,
    );
    await _writeEntry(ex, updated);
  }

  // ---------------------------------------------------- Carnet de lectures

  Future<List<ReadingEntry>> readingEntries() async {
    final rows = await _db.query('reading_list');
    return rows.map(ReadingEntry.fromRow).toList();
  }

  Future<void> _writeEntry(DatabaseExecutor ex, ReadingEntry entry) async {
    await ex.insert('reading_list', entry.toRow(),
        conflictAlgorithm: ConflictAlgorithm.replace);
    await _record(ex, 'readlog', entry.uid, entry.toRow());
  }

  Future<void> saveReadingEntry(ReadingEntry entry) =>
      _db.transaction((txn) => _writeEntry(txn, entry));

  Future<void> deleteReadingEntry(String uid) async {
    await _db.transaction((txn) async {
      await txn.delete('reading_list', where: 'uid = ?', whereArgs: [uid]);
      await _record(txn, 'readlog', uid, const {}, deleted: true);
    });
  }

  // ---------------------------------------------------------- Marque-pages

  Future<Set<int>> bookmarks(String bookId) async {
    final rows = await _db.query('bookmarks',
        columns: ['page'], where: 'book_id = ?', whereArgs: [bookId]);
    return {for (final row in rows) row['page'] as int};
  }

  Future<void> addBookmark(String bookId, int page) async {
    await _db.transaction((txn) async {
      await txn.insert(
        'bookmarks',
        {'book_id': bookId, 'page': page, 'created_at': _now()},
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
      await _record(txn, 'bookmark', '$bookId|$page', const {});
    });
  }

  Future<void> removeBookmark(String bookId, int page) async {
    await _db.transaction((txn) async {
      await txn.delete('bookmarks',
          where: 'book_id = ? AND page = ?', whereArgs: [bookId, page]);
      await _record(txn, 'bookmark', '$bookId|$page', const {},
          deleted: true);
    });
  }

  // ------------------------------------------------------------ Catégories

  Future<List<BookCategory>> categories() async {
    final rows = await _db.query('categories');
    final list = rows.map(BookCategory.fromRow).toList()
      ..sort((a, b) =>
          normalizeForSearch(a.name).compareTo(normalizeForSearch(b.name)));
    return list;
  }

  Future<Map<String, Object?>?> _categoryRowByKey(
      DatabaseExecutor ex, String key) async {
    final rows = await ex.query('categories',
        where: 'uid = ?', whereArgs: [key], limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  Future<String?> _categoryKeyOf(DatabaseExecutor ex, int id) async {
    final rows = await ex.query('categories',
        columns: ['uid'], where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : rows.first['uid'] as String?;
  }

  /// Crée la catégorie, ou renvoie celle qui porte déjà ce nom.
  Future<BookCategory> createCategory(String name) async {
    final key = categoryKey(name);
    return _db.transaction((txn) async {
      final existing = await _categoryRowByKey(txn, key);
      if (existing != null) return BookCategory.fromRow(existing);
      final id = await txn.insert('categories', {
        'name': name,
        'uid': key,
        'created_at': _now(),
      });
      await _record(txn, 'category', key, {'name': name});
      return BookCategory(id: id, name: name);
    });
  }

  /// Renvoie `false` si une autre catégorie porte déjà ce nom.
  Future<bool> renameCategory(int id, String name) async {
    final newKey = categoryKey(name);
    return _db.transaction((txn) async {
      final existing = await _categoryRowByKey(txn, newKey);
      if (existing != null && existing['id'] != id) return false;
      final oldKey = await _categoryKeyOf(txn, id);
      if (oldKey == null) return false;
      await txn.update('categories', {'name': name, 'uid': newKey},
          where: 'id = ?', whereArgs: [id]);
      await _record(txn, 'category', newKey, {'name': name});
      if (oldKey != newKey) {
        // La clé suit le nom : on déplace aussi les rangements des livres.
        await _record(txn, 'category', oldKey, const {}, deleted: true);
        final links = await txn.query('book_categories',
            columns: ['book_id'], where: 'category_id = ?', whereArgs: [id]);
        for (final link in links) {
          final bookId = link['book_id'] as String;
          await _record(txn, 'bookcat', '$bookId|$oldKey', const {},
              deleted: true);
          await _record(txn, 'bookcat', '$bookId|$newKey', const {});
        }
      }
      return true;
    });
  }

  /// Supprime la catégorie. Les livres, eux, restent dans la bibliothèque.
  Future<void> deleteCategory(int id) async {
    await _db.transaction((txn) async {
      final key = await _categoryKeyOf(txn, id);
      final links = await txn.query('book_categories',
          columns: ['book_id'], where: 'category_id = ?', whereArgs: [id]);
      await txn.delete('book_categories',
          where: 'category_id = ?', whereArgs: [id]);
      await txn.delete('categories', where: 'id = ?', whereArgs: [id]);
      if (key == null) return;
      await _record(txn, 'category', key, const {}, deleted: true);
      for (final link in links) {
        await _record(txn, 'bookcat', '${link['book_id']}|$key', const {},
            deleted: true);
      }
    });
  }

  /// Pour chaque livre, les identifiants de ses catégories.
  Future<Map<String, Set<int>>> bookCategoryLinks() async {
    final rows = await _db.query('book_categories');
    final links = <String, Set<int>>{};
    for (final row in rows) {
      links
          .putIfAbsent(row['book_id'] as String, () => <int>{})
          .add(row['category_id'] as int);
    }
    return links;
  }

  Future<void> setBookCategories(String bookId, Set<int> categoryIds) async {
    await _db.transaction((txn) async {
      final before = {
        for (final row in await txn.query('book_categories',
            columns: ['category_id'],
            where: 'book_id = ?',
            whereArgs: [bookId]))
          row['category_id'] as int,
      };
      for (final id in before.difference(categoryIds)) {
        await txn.delete('book_categories',
            where: 'book_id = ? AND category_id = ?', whereArgs: [bookId, id]);
        final key = await _categoryKeyOf(txn, id);
        if (key != null) {
          await _record(txn, 'bookcat', '$bookId|$key', const {},
              deleted: true);
        }
      }
      for (final id in categoryIds.difference(before)) {
        await txn.insert(
            'book_categories', {'book_id': bookId, 'category_id': id},
            conflictAlgorithm: ConflictAlgorithm.ignore);
        final key = await _categoryKeyOf(txn, id);
        if (key != null) await _record(txn, 'bookcat', '$bookId|$key', const {});
      }
    });
  }

  Future<void> addBooksToCategory(List<String> bookIds, int categoryId) async {
    await _db.transaction((txn) async {
      final key = await _categoryKeyOf(txn, categoryId);
      for (final bookId in bookIds) {
        await txn.insert(
            'book_categories', {'book_id': bookId, 'category_id': categoryId},
            conflictAlgorithm: ConflictAlgorithm.ignore);
        if (key != null) await _record(txn, 'bookcat', '$bookId|$key', const {});
      }
    });
  }

  // ----------------------------------------------------------- Annotations

  Future<List<Annotation>> annotations(String bookId) async {
    final rows = await _db.query('annotations',
        where: 'book_id = ?',
        whereArgs: [bookId],
        orderBy: 'page ASC, created_at ASC');
    return rows.map(Annotation.fromRow).toList();
  }

  /// Enregistre l'annotation et renvoie son identifiant.
  Future<int> insertAnnotation(Annotation annotation) async {
    return _db.transaction((txn) async {
      final row = {...annotation.toRow(), 'uid': newUid()}..remove('id');
      final id = await txn.insert('annotations', row);
      await _record(txn, 'annotation', row['uid'] as String,
          _annotationData(row));
      return id;
    });
  }

  Future<void> updateAnnotationNote(int id, String note) async {
    await _db.transaction((txn) async {
      await txn.update('annotations', {'note': note, 'updated_at': _now()},
          where: 'id = ?', whereArgs: [id]);
      final rows = await txn.query('annotations',
          where: 'id = ?', whereArgs: [id], limit: 1);
      if (rows.isEmpty) return;
      final uid = rows.first['uid'] as String?;
      if (uid != null) {
        await _record(txn, 'annotation', uid, _annotationData(rows.first));
      }
    });
  }

  Future<void> deleteAnnotation(int id) async {
    await _db.transaction((txn) async {
      final rows = await txn.query('annotations',
          columns: ['uid'], where: 'id = ?', whereArgs: [id], limit: 1);
      await txn.delete('annotations', where: 'id = ?', whereArgs: [id]);
      final uid = rows.isEmpty ? null : rows.first['uid'] as String?;
      if (uid != null) {
        await _record(txn, 'annotation', uid, const {}, deleted: true);
      }
    });
  }

  /// Nombre d'annotations par livre (affiché dans la bibliothèque).
  Future<Map<String, int>> annotationCounts() async {
    final rows = await _db.rawQuery(
        'SELECT book_id, COUNT(*) AS n FROM annotations GROUP BY book_id');
    return {
      for (final row in rows) row['book_id'] as String: row['n'] as int,
    };
  }

  // ------------------------------------------------------- Synchronisation

  /// Changements locaux pas encore envoyés.
  Future<List<SyncItem>> dirtyItems({int limit = 500}) async {
    final rows = await _db.query('sync_items',
        where: 'dirty = 1', orderBy: 'updated_at ASC', limit: limit);
    return rows.map(SyncItem.fromRow).toList();
  }

  /// Marque comme envoyés les éléments [sent], sauf ceux modifiés entre-temps.
  Future<void> markSent(List<SyncItem> sent) async {
    await _db.transaction((txn) async {
      for (final item in sent) {
        await txn.update('sync_items', {'dirty': 0},
            where: 'kind = ? AND key = ? AND updated_at = ?',
            whereArgs: [item.kind, item.key, item.updatedAt]);
      }
    });
  }

  /// Tout renvoyer (le serveur a été réinitialisé).
  Future<void> markAllDirty() async {
    await _db.rawUpdate('UPDATE sync_items SET dirty = 1');
  }

  /// Applique les changements reçus du serveur quand ils sont plus récents
  /// que la version locale. Renvoie le nombre de changements appliqués.
  Future<int> applyRemote(List<SyncItem> items) async {
    final sorted = [...items]..sort((a, b) => a.applyOrder - b.applyOrder);
    var applied = 0;
    await _db.transaction((txn) async {
      for (final item in sorted) {
        final local = await txn.query('sync_items',
            columns: ['updated_at'],
            where: 'kind = ? AND key = ?',
            whereArgs: [item.kind, item.key],
            limit: 1);
        if (local.isNotEmpty &&
            (local.first['updated_at'] as int) >= item.updatedAt) {
          continue; // la version locale est aussi récente ou plus récente
        }
        await txn.insert(
            'sync_items',
            {
              'kind': item.kind,
              'key': item.key,
              'data': jsonEncode(item.data),
              'updated_at': item.updatedAt,
              'deleted': item.deleted ? 1 : 0,
              'dirty': 0,
            },
            conflictAlgorithm: ConflictAlgorithm.replace);
        try {
          await _apply(txn, item);
        } catch (_) {
          // Élément inattendu : on le garde en réserve sans bloquer le reste.
        }
        applied++;
      }
    });
    return applied;
  }

  /// Réapplique l'état déjà reçu pour un livre qui vient d'arriver.
  Future<void> _reapplyForBook(DatabaseExecutor ex, String bookId) async {
    final rows = await ex.query('sync_items',
        where: "(kind IN ('progress', 'title') AND key = ?) "
            "OR (kind IN ('bookmark', 'bookcat') AND key LIKE ?) "
            "OR (kind = 'annotation' AND data LIKE ?)",
        whereArgs: [bookId, '$bookId|%', '%$bookId%']);
    final items = rows.map(SyncItem.fromRow).toList()
      ..sort((a, b) => a.applyOrder - b.applyOrder);
    for (final item in items) {
      try {
        await _apply(ex, item);
      } catch (_) {
        // Élément inattendu : ignoré, le livre s'ajoute quand même.
      }
    }
  }

  /// Traduit un élément synchronisé dans les tables de l'appli.
  /// Un élément qui vise un livre absent de ce profil est simplement gardé
  /// dans sync_items : il sera appliqué si le livre arrive.
  Future<void> _apply(DatabaseExecutor ex, SyncItem item) async {
    final data = item.data;
    switch (item.kind) {
      case 'progress':
        final page = jsonInt(data['page']);
        if (page == null || !await _bookExists(ex, item.key)) return;
        await ex.update(
            'books',
            {
              'last_page': page < 1 ? 1 : page,
              'last_opened_at': jsonInt(data['opened']) ?? item.updatedAt,
            },
            where: 'id = ?',
            whereArgs: [item.key]);
      case 'title':
        final title = data['title'];
        if (title is! String || title.trim().isEmpty) return;
        await ex.update('books', {'title': title},
            where: 'id = ?', whereArgs: [item.key]);
      case 'bookmark':
        final parts = item.key.split('|');
        final markPage = parts.length == 2 ? int.tryParse(parts[1]) : null;
        if (markPage == null) return;
        if (item.deleted) {
          await ex.delete('bookmarks',
              where: 'book_id = ? AND page = ?',
              whereArgs: [parts[0], markPage]);
        } else if (await _bookExists(ex, parts[0])) {
          await ex.insert(
              'bookmarks',
              {
                'book_id': parts[0],
                'page': markPage,
                'created_at': item.updatedAt,
              },
              conflictAlgorithm: ConflictAlgorithm.ignore);
        }
      case 'category':
        final existing = await _categoryRowByKey(ex, item.key);
        if (item.deleted) {
          if (existing == null) return;
          await ex.delete('book_categories',
              where: 'category_id = ?', whereArgs: [existing['id']]);
          await ex.delete('categories',
              where: 'id = ?', whereArgs: [existing['id']]);
          return;
        }
        final name = data['name'];
        if (name is! String || name.trim().isEmpty) return;
        if (existing == null) {
          await ex.insert('categories',
              {'name': name, 'uid': item.key, 'created_at': item.updatedAt});
        } else {
          await ex.update('categories', {'name': name},
              where: 'id = ?', whereArgs: [existing['id']]);
        }
      case 'bookcat':
        final cut = item.key.indexOf('|');
        if (cut <= 0) return;
        final linkBook = item.key.substring(0, cut);
        final category =
            await _categoryRowByKey(ex, item.key.substring(cut + 1));
        if (category == null) return;
        if (item.deleted) {
          await ex.delete('book_categories',
              where: 'book_id = ? AND category_id = ?',
              whereArgs: [linkBook, category['id']]);
        } else if (await _bookExists(ex, linkBook)) {
          await ex.insert('book_categories',
              {'book_id': linkBook, 'category_id': category['id']},
              conflictAlgorithm: ConflictAlgorithm.ignore);
        }
      case 'readlog':
        if (item.deleted) {
          await ex.delete('reading_list',
              where: 'uid = ?', whereArgs: [item.key]);
          return;
        }
        final entryTitle = data['title'];
        if (entryTitle is! String || entryTitle.trim().isEmpty) return;
        final entry = ReadingEntry.fromRow({
          ...data,
          'uid': item.key,
          'rating': jsonInt(data['rating']) ?? 0,
          'finished_at': jsonInt(data['finished_at']),
          'created_at': jsonInt(data['created_at']) ?? item.updatedAt,
          'updated_at': item.updatedAt,
          'author': data['author'] is String ? data['author'] : '',
          'review': data['review'] is String ? data['review'] : '',
          'book_id': data['book_id'] is String ? data['book_id'] : null,
        });
        await ex.insert('reading_list', entry.toRow(),
            conflictAlgorithm: ConflictAlgorithm.replace);
      case 'annotation':
        if (item.deleted) {
          await ex.delete('annotations',
              where: 'uid = ?', whereArgs: [item.key]);
          return;
        }
        final noteBook = data['book_id'];
        final notePage = jsonInt(data['page']);
        if (noteBook is! String || notePage == null) return;
        if (!await _bookExists(ex, noteBook)) return;
        final row = <String, Object?>{
          'book_id': noteBook,
          'page': notePage,
          'quote': data['quote'] is String ? data['quote'] : null,
          'rects': data['rects'] is String ? data['rects'] : null,
          'color': jsonInt(data['color']),
          'note': data['note'] is String ? data['note'] : '',
          'created_at': jsonInt(data['created_at']) ?? item.updatedAt,
          'updated_at': item.updatedAt,
          'uid': item.key,
        };
        final updated = await ex.update('annotations', row,
            where: 'uid = ?', whereArgs: [item.key]);
        if (updated == 0) await ex.insert('annotations', row);
    }
  }

  // ------------------------------------------------------- Effacement

  /// Efface définitivement les données de lecture de ce profil : notes,
  /// surlignages, marque-pages, catégories, pages en cours et état de
  /// synchronisation. Avec [books], supprime aussi la liste des livres.
  Future<void> wipeReadingData({required bool books}) async {
    await _db.transaction((txn) async {
      for (final table in [
        'bookmarks',
        'annotations',
        'book_categories',
        'categories',
        'sync_items',
        'seen_downloads',
        'reading_list',
      ]) {
        await txn.delete(table);
      }
      if (books) {
        await txn.delete('books');
      } else {
        await txn.rawUpdate(
            'UPDATE books SET last_page = 1, last_opened_at = NULL');
      }
      await txn.delete('settings', where: "key IN ('filtre')");
    });
  }

  // -------------------------------------------------------------- Réglages

  Future<String?> getSetting(String key) async {
    final rows = await _db.query('settings',
        columns: ['value'], where: 'key = ?', whereArgs: [key], limit: 1);
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  Future<void> setSetting(String key, String value) async {
    await _db.insert('settings', {'key': key, 'value': value},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }
}
