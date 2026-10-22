/// Un livre de la bibliothèque.
///
/// [id] est l'empreinte SHA-256 du fichier : le même PDF garde le même
/// identifiant (et donc ses marque-pages) même s'il est renommé ou réimporté.
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
  });

  final String id;
  final String title;

  /// Nom du fichier dans le dossier privé de l'appli (« <id>.pdf »).
  /// On ne stocke pas le chemin complet : il peut changer selon le profil
  /// Android, alors que le nom reste fixe.
  final String fileName;
  final int sizeBytes;

  /// Connu à la première ouverture du livre.
  final int? pageCount;
  final int lastPage;
  final DateTime addedAt;

  /// `null` tant que le livre n'a jamais été ouvert.
  final DateTime? lastOpenedAt;

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
      };
}

/// Ordres de tri proposés dans la bibliothèque.
enum BookSort {
  recent(
    'recent',
    'Lus récemment',
    'last_opened_at IS NULL, last_opened_at DESC, added_at DESC',
  ),
  title('titre', 'Titre (A → Z)', 'title ASC'),
  added('ajout', "Date d'ajout", 'added_at DESC');

  const BookSort(this.key, this.label, this.orderBy);

  /// Valeur enregistrée dans les réglages.
  final String key;
  final String label;

  /// Clause ORDER BY SQL.
  final String orderBy;

  static BookSort fromKey(String? key) =>
      values.firstWhere((s) => s.key == key, orElse: () => recent);
}
