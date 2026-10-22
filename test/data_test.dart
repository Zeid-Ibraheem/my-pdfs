import 'package:flutter_test/flutter_test.dart';
import 'package:my_pdfs/data/annotation.dart';
import 'package:my_pdfs/data/category.dart';

void main() {
  test('les zones surlignées survivent à l’aller-retour JSON', () {
    final rects = <int, List<List<double>>>{
      12: [
        [10, 700.5, 200, 690],
      ],
      13: [
        [1, 2, 3, 4],
        [5, 6, 7, 8],
      ],
    };
    expect(Annotation.decodeRects(Annotation.encodeRects(rects)), rects);
    expect(Annotation.decodeRects(null), isEmpty);
  });

  test('export Markdown trié par page', () {
    final date = DateTime(2026);
    final highlight = Annotation(
      bookId: 'x',
      page: 3,
      quote: 'Bonjour\nmonde',
      rects: const {
        3: [
          [0, 0, 1, 1],
        ],
      },
      color: highlightColors.first,
      note: 'Idée',
      createdAt: date,
      updatedAt: date,
    );
    final freeNote = Annotation(
      bookId: 'x',
      page: 1,
      quote: null,
      rects: const {},
      color: null,
      note: 'Libre',
      createdAt: date,
      updatedAt: date,
    );
    expect(
      annotationsToMarkdown('Livre', [highlight, freeNote]),
      '# Livre\n\n## Page 1\n\nLibre\n\n## Page 3\n\n> Bonjour\n> monde\n\nIdée\n',
    );
  });

  test('filtres de la bibliothèque', () {
    expect(LibraryFilter.fromKey('reading'), LibraryFilter.reading);
    expect(LibraryFilter.fromKey('cat:5').categoryId, 5);
    expect(LibraryFilter.fromKey('n/a'), LibraryFilter.all);
    expect(LibraryFilter.fromKey(null), LibraryFilter.all);
    expect(LibraryFilter.all.categoryId, isNull);
  });
}
