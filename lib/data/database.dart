import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../util/text.dart';
import 'book.dart';

/// Base SQLite locale : livres, marque-pages et réglages.
///
/// Tout tient dans un seul fichier (my_pdfs.db) : c'est lui qu'on sauvegardera
/// sur debi en phase 4.
class AppDatabase {
  AppDatabase._(this._db);

  final Database _db;

  static Future<AppDatabase> open() async {
    final dir = await getDatabasesPath();
    final db = await openDatabase(
      p.join(dir, 'my_pdfs.db'),
      version: 1,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
      },
      onCreate: (db, version) async {
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
      },
    );
    return AppDatabase._(db);
  }

  // ---------------------------------------------------------------- Livres

  Future<List<Book>> books(BookSort sort) async {
    final rows = await _db.query('books', orderBy: sort.orderBy);
    final list = rows.map(Book.fromRow).toList();
    if (sort == BookSort.title) {
      // Tri sans tenir compte des accents ni des majuscules.
      list.sort((a, b) =>
          normalizeForSearch(a.title).compareTo(normalizeForSearch(b.title)));
    }
    return list;
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
    await _db.delete('bookmarks', where: 'book_id = ?', whereArgs: [id]);
    await _db.delete('books', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> setPageCount(String id, int count) async {
    await _db.update('books', {'page_count': count},
        where: 'id = ?', whereArgs: [id]);
  }

  Future<void> saveLastPage(String id, int page) async {
    await _db.update('books', {'last_page': page},
        where: 'id = ?', whereArgs: [id]);
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
