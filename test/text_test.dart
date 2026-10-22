import 'package:my_pdfs/util/text.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('cleanTitle retire l’extension et les tirets bas', () {
    expect(cleanTitle('Le_Petit_Prince.PDF'), 'Le Petit Prince');
    expect(cleanTitle('  Réseaux   et  télécoms.pdf'), 'Réseaux et télécoms');
    expect(cleanTitle('.pdf'), 'Sans titre');
  });

  test('normalizeForSearch ignore accents et majuscules', () {
    expect(normalizeForSearch('Écologie Générale'), 'ecologie generale');
    expect(normalizeForSearch('Cœur'), 'coeur');
  });

  test('formatSize affiche des unités françaises', () {
    expect(formatSize(512 * 1024), '512 Ko');
    expect(formatSize(13002342), '12,4 Mo');
    expect(formatSize(1288490188), '1,2 Go');
  });

  test('looksLikePdf repère la signature %PDF', () {
    expect(looksLikePdf('%PDF-1.7'.codeUnits), isTrue);
    expect(looksLikePdf([0, 0, ...'%PDF-1.4'.codeUnits]), isTrue);
    expect(looksLikePdf('<html>'.codeUnits), isFalse);
    expect(looksLikePdf(const []), isFalse);
  });
}
