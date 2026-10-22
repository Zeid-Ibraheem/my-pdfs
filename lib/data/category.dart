/// Une catégorie créée par l'utilisateur (« Réseau », « À lire »…).
/// Un livre peut appartenir à plusieurs catégories à la fois.
class BookCategory {
  const BookCategory({required this.id, required this.name});

  final int id;
  final String name;

  factory BookCategory.fromRow(Map<String, Object?> row) =>
      BookCategory(id: row['id'] as int, name: row['name'] as String);
}

/// Filtres de la bibliothèque : catégories automatiques (calculées à partir
/// de la progression) ou catégorie créée par l'utilisateur.
///
/// Enregistré dans les réglages sous forme de texte : « all », « reading »,
/// « new », « done » ou « cat:<id> ».
class LibraryFilter {
  const LibraryFilter._(this.key);

  static const all = LibraryFilter._('all');
  static const reading = LibraryFilter._('reading');
  static const notStarted = LibraryFilter._('new');
  static const finished = LibraryFilter._('done');

  static const automatic = [all, reading, notStarted, finished];

  factory LibraryFilter.category(int id) => LibraryFilter._('cat:$id');

  factory LibraryFilter.fromKey(String? key) {
    for (final filter in automatic) {
      if (filter.key == key) return filter;
    }
    if (key != null && key.startsWith('cat:')) {
      final id = int.tryParse(key.substring(4));
      if (id != null) return LibraryFilter.category(id);
    }
    return all;
  }

  final String key;

  /// Identifiant de la catégorie, ou `null` pour un filtre automatique.
  int? get categoryId =>
      key.startsWith('cat:') ? int.tryParse(key.substring(4)) : null;

  String get autoLabel => switch (key) {
        'reading' => 'En cours',
        'new' => 'Pas commencés',
        'done' => 'Terminés',
        _ => 'Tous',
      };

  @override
  bool operator ==(Object other) => other is LibraryFilter && other.key == key;

  @override
  int get hashCode => key.hashCode;
}
