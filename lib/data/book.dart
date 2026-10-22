import '../util/text.dart';

/// Un livre de la bibliothèque.
///
/// [id] est l'empreinte SHA-256 du fichier : le même PDF garde le même
/// identifiant (et donc ses marque-pages et annotations) sur le téléphone
/// comme sur le serveur, même s'il est renommé.
class Book {
  const Book({
    required this.id,
    required this.title,
    required this.fileName,
    required this.sizeBytes,
    required this.pageCount,
    required this.lastPage,
    required this.addedAt,
    required this.lastOpenedAt,
    this.onDevice = true,
    this.onServer = false,
    this.pinned = false,
  });

  final String id;
  final String title;

  /// Nom du fichier dans le dossier privé de l'appli (« <id>.pdf »).
  final String fileName;
  final int sizeBytes;

  /// Connu à la première ouverture du livre.
  final int? pageCount;
  final int lastPage;
  final DateTime addedAt;

  /// `null` tant que le livre n'a jamais été ouvert.
  final DateTime? lastOpenedAt;

  /// Le fichier est présent sur le téléphone.
  final bool onDevice;

  /// Le fichier est stocké sur le serveur.
  final bool onServer;

  /// Épinglé : jamais retiré automatiquement du téléphone.
  final bool pinned;

  bool get started => lastOpenedAt != null;
  bool get finished => pageCount != null && lastPage >= pageCount!;

  /// Progression entre 0 et 1, ou `null` si le nombre de pages est inconnu.
  double? get progress {
    final count = pageCount;
    if (count == null || count <= 0) return null;
    return (lastPage / count).clamp(0.0, 1.0).toDouble();
  }

  factory Book.fromRow(Map<String, Object?> row) {
    final opened = row['last_opened_at'] as int?;
    return Book(
      id: row['id'] as String,
      title: row['title'] as String,
      fileName: row['file_name'] as String,
      sizeBytes: row['size_bytes'] as int,
      pageCount: row['page_count'] as int?,
      lastPage: row['last_page'] as int,
      addedAt: DateTime.fromMillisecondsSinceEpoch(row['added_at'] as int),
      lastOpenedAt:
          opened == null ? null : DateTime.fromMillisecondsSinceEpoch(opened),
      onDevice: (row['on_device'] as int? ?? 1) == 1,
      onServer: (row['on_server'] as int? ?? 0) == 1,
      pinned: (row['pinned'] as int? ?? 0) == 1,
    );
  }

  Map<String, Object?> toRow() => {
        'id': id,
        'title': title,
        'file_name': fileName,
        'size_bytes': sizeBytes,
        'page_count': pageCount,
        'last_page': lastPage,
        'added_at': addedAt.millisecondsSinceEpoch,
        'last_opened_at': lastOpenedAt?.millisecondsSinceEpoch,
        'on_device': onDevice ? 1 : 0,
        'on_server': onServer ? 1 : 0,
        'pinned': pinned ? 1 : 0,
      };
}

/// Ordres de tri proposés dans la bibliothèque.
enum BookSort {
  recent('recent', 'Lus récemment'),
  title('titre', 'Titre (A → Z)'),
  added('ajout', "Date d'ajout"),
  progress('progression', 'Progression'),
  pages('pages', 'Nombre de pages'),
  size('taille', 'Taille du fichier');

  const BookSort(this.key, this.label);

  /// Valeur enregistrée dans les réglages.
  final String key;
  final String label;

  static BookSort fromKey(String? key) =>
      values.firstWhere((s) => s.key == key, orElse: () => recent);
}

/// Trie les livres. Chaque critère a un sens naturel (récents d'abord,
/// A → Z, plus avancés d'abord…) ; [reversed] l'inverse.
List<Book> sortBooks(List<Book> books, BookSort sort, {bool reversed = false}) {
  int byDateDesc(DateTime? a, DateTime? b) {
    if (a == null && b == null) return 0;
    if (a == null) return 1; // jamais ouverts à la fin
    if (b == null) return -1;
    return b.compareTo(a);
  }

  int compare(Book a, Book b) {
    switch (sort) {
      case BookSort.recent:
        final opened = byDateDesc(a.lastOpenedAt, b.lastOpenedAt);
        return opened != 0 ? opened : b.addedAt.compareTo(a.addedAt);
      case BookSort.title:
        return normalizeForSearch(a.title).compareTo(normalizeForSearch(b.title));
      case BookSort.added:
        return b.addedAt.compareTo(a.addedAt);
      case BookSort.progress:
        return (b.progress ?? -1).compareTo(a.progress ?? -1);
      case BookSort.pages:
        return (b.pageCount ?? -1).compareTo(a.pageCount ?? -1);
      case BookSort.size:
        return b.sizeBytes.compareTo(a.sizeBytes);
    }
  }

  final sorted = [...books]..sort((a, b) {
      final result = compare(a, b);
      // À égalité, ordre alphabétique pour un affichage stable.
      return result != 0
          ? result
          : normalizeForSearch(a.title).compareTo(normalizeForSearch(b.title));
    });
  return reversed ? sorted.reversed.toList() : sorted;
}
