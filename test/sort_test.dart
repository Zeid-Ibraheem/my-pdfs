import 'package:flutter_test/flutter_test.dart';
import 'package:my_pdfs/data/book.dart';
import 'package:my_pdfs/data/library.dart';
import 'package:my_pdfs/util/text.dart';

Book book(String title,
    {int? pages, int last = 1, int size = 1, int added = 0, int? opened}) {
  return Book(
    id: title,
    title: title,
    fileName: '$title.pdf',
    sizeBytes: size,
    pageCount: pages,
    lastPage: last,
    addedAt: DateTime.fromMillisecondsSinceEpoch(added),
    lastOpenedAt: opened == null ? null : DateTime.fromMillisecondsSinceEpoch(opened),
  );
}

void main() {
  final a = book('Été', pages: 100, last: 50, size: 30, added: 1, opened: 10);
  final b = book('avion', pages: 200, last: 20, size: 10, added: 3);
  final c = book('Zèbre', pages: 50, last: 50, size: 20, added: 2, opened: 20);
  List<String> titles(List<Book> list) => [for (final x in list) x.title];

  test('tri par titre sans accents ni majuscules', () {
    expect(titles(sortBooks([a, b, c], BookSort.title)), ['avion', 'Été', 'Zèbre']);
    expect(titles(sortBooks([a, b, c], BookSort.title, reversed: true)),
        ['Zèbre', 'Été', 'avion']);
  });

  test('lus récemment d’abord, jamais ouverts à la fin', () {
    expect(titles(sortBooks([a, b, c], BookSort.recent)), ['Zèbre', 'Été', 'avion']);
  });

  test('progression, pages, taille, ajout', () {
    expect(titles(sortBooks([a, b, c], BookSort.progress)), ['Zèbre', 'Été', 'avion']);
    expect(titles(sortBooks([a, b, c], BookSort.pages)), ['avion', 'Été', 'Zèbre']);
    expect(titles(sortBooks([a, b, c], BookSort.size)), ['Été', 'Zèbre', 'avion']);
    expect(titles(sortBooks([a, b, c], BookSort.added)), ['avion', 'Zèbre', 'Été']);
  });

  test('adresse du serveur normalisée', () {
    expect(Library.normalizeServerUrl(' 100.1.2.3:8765/ '), 'http://100.1.2.3:8765');
    expect(Library.normalizeServerUrl('http://srv.ts.net:8765'), 'http://srv.ts.net:8765');
  });

  test('date en français', () {
    expect(formatDateTime(DateTime(2026, 10, 2, 9, 5)), '02/10/2026 à 09:05');
  });
}
