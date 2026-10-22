import 'dart:convert';

/// Couleurs de surlignage proposées (ARGB).
const highlightColors = <int>[
  0xFFFFEB3B, // jaune
  0xFF8BC34A, // vert
  0xFF4FC3F7, // bleu
  0xFFF48FB1, // rose
];

/// Un surlignage (avec ou sans note) ou une note libre sur une page.
///
/// Les zones surlignées sont stockées en coordonnées PDF (points, origine
/// en bas à gauche) : elles restent justes quel que soit le zoom, l'écran
/// ou l'orientation. Le fichier PDF lui-même n'est jamais modifié.
class Annotation {
  const Annotation({
    this.id,
    required this.bookId,
    required this.page,
    required this.quote,
    required this.rects,
    required this.color,
    required this.note,
    required this.createdAt,
    required this.updatedAt,
  });

  final int? id;
  final String bookId;

  /// Première page concernée (pour le tri et la navigation).
  final int page;

  /// Texte surligné, ou `null` pour une note libre sur la page.
  final String? quote;

  /// Zones surlignées par page : {page: [[gauche, haut, droite, bas], …]}.
  final Map<int, List<List<double>>> rects;

  /// Couleur ARGB du surlignage, `null` pour une note libre.
  final int? color;

  /// Texte de la note (peut être vide pour un simple surlignage).
  final String note;
  final DateTime createdAt;
  final DateTime updatedAt;

  bool get isHighlight => quote != null && rects.isNotEmpty;
  bool get hasNote => note.trim().isNotEmpty;

  Annotation copyWith({int? id, String? note, DateTime? updatedAt}) =>
      Annotation(
        id: id ?? this.id,
        bookId: bookId,
        page: page,
        quote: quote,
        rects: rects,
        color: color,
        note: note ?? this.note,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  factory Annotation.fromRow(Map<String, Object?> row) => Annotation(
        id: row['id'] as int,
        bookId: row['book_id'] as String,
        page: row['page'] as int,
        quote: row['quote'] as String?,
        rects: decodeRects(row['rects'] as String?),
        color: row['color'] as int?,
        note: row['note'] as String? ?? '',
        createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(row['updated_at'] as int),
      );

  Map<String, Object?> toRow() => {
        if (id != null) 'id': id,
        'book_id': bookId,
        'page': page,
        'quote': quote,
        'rects': rects.isEmpty ? null : encodeRects(rects),
        'color': color,
        'note': note,
        'created_at': createdAt.millisecondsSinceEpoch,
        'updated_at': updatedAt.millisecondsSinceEpoch,
      };

  static String encodeRects(Map<int, List<List<double>>> rects) =>
      jsonEncode({
        for (final entry in rects.entries) '${entry.key}': entry.value,
      });

  static Map<int, List<List<double>>> decodeRects(String? json) {
    if (json == null || json.isEmpty) return const {};
    final raw = jsonDecode(json) as Map<String, dynamic>;
    return {
      for (final entry in raw.entries)
        int.parse(entry.key): [
          for (final rect in entry.value as List)
            [for (final v in rect as List) (v as num).toDouble()],
        ],
    };
  }
}

/// Export de toutes les annotations d'un livre en Markdown (texte simple),
/// prêt à coller dans une appli de notes.
String annotationsToMarkdown(String title, List<Annotation> annotations) {
  final sorted = [...annotations]..sort((a, b) {
      final byPage = a.page.compareTo(b.page);
      return byPage != 0 ? byPage : a.createdAt.compareTo(b.createdAt);
    });
  final buffer = StringBuffer('# $title\n');
  int? currentPage;
  for (final a in sorted) {
    if (a.page != currentPage) {
      currentPage = a.page;
      buffer.write('\n## Page ${a.page}\n');
    }
    buffer.write('\n');
    if (a.quote != null) {
      for (final line in a.quote!.trim().split('\n')) {
        buffer.write('> $line\n');
      }
    }
    if (a.hasNote) {
      if (a.quote != null) buffer.write('\n');
      buffer.write('${a.note.trim()}\n');
    }
  }
  return buffer.toString();
}
