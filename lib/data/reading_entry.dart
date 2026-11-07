/// Statut d'un livre dans le carnet de lectures.
enum ReadingStatus {
  read('read', 'Lu'),
  reading('reading', 'En cours'),
  toRead('toread', 'À lire');

  const ReadingStatus(this.key, this.label);

  final String key;
  final String label;

  static ReadingStatus fromKey(Object? key) =>
      values.firstWhere((s) => s.key == key, orElse: () => toRead);
}

/// Une entrée du carnet de lectures : un livre lu, en cours ou à lire,
/// avec ou sans PDF dans la bibliothèque.
///
/// Les livres importés ont une entrée automatique, de clé « book:<empreinte> »
/// (la même sur tous les profils) ; les livres ajoutés à la main ont une clé
/// aléatoire. Supprimer un PDF de la bibliothèque ne supprime pas son entrée :
/// le carnet garde l'historique de tes lectures.
class ReadingEntry {
  const ReadingEntry({
    required this.uid,
    required this.title,
    this.author = '',
    this.rating = 0,
    this.review = '',
    this.status = ReadingStatus.toRead,
    this.finishedAt,
    this.bookId,
    required this.createdAt,
    required this.updatedAt,
  });

  final String uid;
  final String title;
  final String author;

  /// Note de 1 à 5 étoiles, 0 = pas encore noté.
  final int rating;

  /// Avis personnel, libre.
  final String review;
  final ReadingStatus status;

  /// Date de fin de lecture (pour les livres lus).
  final DateTime? finishedAt;

  /// Empreinte du PDF lié, si le livre est (ou a été) dans la bibliothèque.
  final String? bookId;
  final DateTime createdAt;
  final DateTime updatedAt;

  static String keyForBook(String bookId) => 'book:$bookId';

  ReadingEntry copyWith({
    String? title,
    String? author,
    int? rating,
    String? review,
    ReadingStatus? status,
    DateTime? finishedAt,
    bool clearFinishedAt = false,
  }) =>
      ReadingEntry(
        uid: uid,
        title: title ?? this.title,
        author: author ?? this.author,
        rating: rating ?? this.rating,
        review: review ?? this.review,
        status: status ?? this.status,
        finishedAt: clearFinishedAt ? null : (finishedAt ?? this.finishedAt),
        bookId: bookId,
        createdAt: createdAt,
        updatedAt: DateTime.now(),
      );

  static DateTime? _date(Object? ms) =>
      ms is num ? DateTime.fromMillisecondsSinceEpoch(ms.toInt()) : null;

  factory ReadingEntry.fromRow(Map<String, Object?> row) => ReadingEntry(
        uid: row['uid'] as String,
        title: row['title'] as String? ?? 'Sans titre',
        author: row['author'] as String? ?? '',
        rating: ((row['rating'] as int?) ?? 0).clamp(0, 5).toInt(),
        review: row['review'] as String? ?? '',
        status: ReadingStatus.fromKey(row['status']),
        finishedAt: _date(row['finished_at']),
        bookId: row['book_id'] as String?,
        createdAt: _date(row['created_at']) ?? DateTime.now(),
        updatedAt: _date(row['updated_at']) ?? DateTime.now(),
      );

  /// Ligne de la table reading_list (aussi utilisée comme données de synchro).
  Map<String, Object?> toRow() => {
        'uid': uid,
        'title': title,
        'author': author,
        'rating': rating,
        'review': review,
        'status': status.key,
        'finished_at': finishedAt?.millisecondsSinceEpoch,
        'book_id': bookId,
        'created_at': createdAt.millisecondsSinceEpoch,
        'updated_at': updatedAt.millisecondsSinceEpoch,
      };
}
