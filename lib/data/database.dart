import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../util/text.dart';
import 'annotation.dart';
import 'book.dart';
import 'category.dart';

/// Base SQLite locale : livres, marque-pages, catégories, annotations
/// et réglages.
///
/// Tout tient dans un seul fichier (my_pdfs.db) : c'est lui qui est
/// sauvegardé sur le serveur.
///
/// Versions du schéma :
/// 1. livres, marque-pages, réglages
/// 2. catégories et annotations (surlignages, notes)
/// 3. emplacement des livres (téléphone / serveur) et épinglage
/// 4. fichiers déjà vus dans le dossier Téléchargements
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
      version: 4,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
      },
      onCreate: (db, version) async {
        await _createV1(db);
        await _createV2(db);
        await _createV3(db);
        await _createV4(db);
      },
      // Mise à jour d'une appli déjà installée : on ajoute ce qui manque
      // sans toucher aux livres, marque-pages et annotations existants.
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) await _createV2(db);
        if (oldVersion < 3) await _createV3(db);
        if (oldVersion < 4) await _createV4(db);
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

  static Future<void> _createV4(Database db) async {
    await db.execute('''
      CREATE TABLE seen_downloads (
        path      TEXT PRIMARY KEY,
        signature TEXT NOT NULL
      )
    ''');
  }

  static Future<void> _createV3(Database db) async {
    await db.execute(
        'ALTER TABLE books ADD COLUMN on_device INTEGER NOT NULL DEFAULT 1');
    await db.execute(
        'ALTER TABLE books ADD COLUMN on_server INTEGER NOT NULL DEFAULT 0');
    await db.execute(
        'ALTER TABLE books ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0');
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

  Future<void> insertBook(Book book) async {
    await _db.insert('books', book.toRow());
  }

  Future<void> renameBook(String id, String title) async {
    await _db.update('books', {'title': title},
        where: 'id = ?', whereArgs: [id]);
  }

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

  Future<void> saveLastPage(String id, int page) async {
    await _db.update('books', {'last_page': page},
        where: 'id = ?', whereArgs: [id]);
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
        final chunk = ids.sublist(i, i + 400 > ids.length ? ids.length : i + 400);
        final marks = List.filled(chunk.length, '?').join(', ');
        await txn.rawUpdate(
            'UPDATE books SET on_server = 1 WHERE id IN ($marks)', chunk);
      }
    });
  }

  Future<void> markOpened(String id) async {
    await _db.update(
        'books', {'last_opened_at': DateTime.now().millisecondsSinceEpoch},
        where: 'id = ?', whereArgs: [id]);
  }

  // ---------------------------------------------------------- Marque-pages

  Future<Set<int>> bookmarks(String bookId) async {
    final rows = await _db.query('bookmarks',
        columns: ['page'], where: 'book_id = ?', whereArgs: [bookId]);
    return {for (final row in rows) row['page'] as int};
  }

  Future<void> addBookmark(String bookId, int page) async {
    await _db.insert(
      'bookmarks',
      {
        'book_id': bookId,
        'page': page,
        'created_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  Future<void> removeBookmark(String bookId, int page) async {
    await _db.delete('bookmarks',
        where: 'book_id = ? AND page = ?', whereArgs: [bookId, page]);
  }

  // ------------------------------------------------------------ Catégories

  Future<List<BookCategory>> categories() async {
    final rows = await _db.query('categories');
    final list = rows.map(BookCategory.fromRow).toList()
      ..sort((a, b) =>
          normalizeForSearch(a.name).compareTo(normalizeForSearch(b.name)));
    return list;
  }

  Future<BookCategory?> _categoryByName(String name) async {
    final rows = await _db.query('categories',
        where: 'name = ? COLLATE NOCASE', whereArgs: [name], limit: 1);
    return rows.isEmpty ? null : BookCategory.fromRow(rows.first);
  }

  /// Crée la catégorie, ou renvoie celle qui porte déjà ce nom.
  Future<BookCategory> createCategory(String name) async {
    final existing = await _categoryByName(name);
    if (existing != null) return existing;
    final id = await _db.insert('categories', {
      'name': name,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
    return BookCategory(id: id, name: name);
  }

  /// Renvoie `false` si une autre catégorie porte déjà ce nom.
  Future<bool> renameCategory(int id, String name) async {
    final existing = await _categoryByName(name);
    if (existing != null && existing.id != id) return false;
    await _db.update('categories', {'name': name},
        where: 'id = ?', whereArgs: [id]);
    return true;
  }

  /// Supprime la catégorie. Les livres, eux, restent dans la bibliothèque.
  Future<void> deleteCategory(int id) async {
    await _db.transaction((txn) async {
      await txn.delete('book_categories',
          where: 'category_id = ?', whereArgs: [id]);
      await txn.delete('categories', where: 'id = ?', whereArgs: [id]);
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
      await txn.delete('book_categories',
          where: 'book_id = ?', whereArgs: [bookId]);
      for (final id in categoryIds) {
        await txn.insert(
            'book_categories', {'book_id': bookId, 'category_id': id},
            conflictAlgorithm: ConflictAlgorithm.ignore);
      }
    });
  }

  Future<void> addBooksToCategory(List<String> bookIds, int categoryId) async {
    await _db.transaction((txn) async {
      for (final bookId in bookIds) {
        await txn.insert(
            'book_categories', {'book_id': bookId, 'category_id': categoryId},
            conflictAlgorithm: ConflictAlgorithm.ignore);
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
  Future<int> insertAnnotation(Annotation annotation) =>
      _db.insert('annotations', annotation.toRow());

  Future<void> updateAnnotationNote(int id, String note) async {
    await _db.update(
        'annotations',
        {
          'note': note,
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        },
        where: 'id = ?',
        whereArgs: [id]);
  }

  Future<void> deleteAnnotation(int id) async {
    await _db.delete('annotations', where: 'id = ?', whereArgs: [id]);
  }

  /// Nombre d'annotations par livre (affiché dans la bibliothèque).
  Future<Map<String, int>> annotationCounts() async {
    final rows = await _db.rawQuery(
        'SELECT book_id, COUNT(*) AS n FROM annotations GROUP BY book_id');
    return {
      for (final row in rows) row['book_id'] as String: row['n'] as int,
    };
  }

  // ------------------------------------------------- Dossier Téléchargements

  /// Fichiers déjà traités : chemin → « taille:date de modification ».
  Future<Map<String, String>> seenDownloads() async {
    final rows = await _db.query('seen_downloads');
    return {
      for (final row in rows) row['path'] as String: row['signature'] as String,
    };
  }

  Future<void> markDownloadSeen(String path, String signature) async {
    await _db.insert('seen_downloads', {'path': path, 'signature': signature},
        conflictAlgorithm: ConflictAlgorithm.replace);
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
