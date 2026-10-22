/// Petites fonctions de texte sans dépendance (testées dans test/text_test.dart).
library;

/// Transforme un nom de fichier en titre lisible :
/// « Le_Petit_Prince.pdf » → « Le Petit Prince ».
String cleanTitle(String fileName) {
  var title = fileName;
  if (title.toLowerCase().endsWith('.pdf')) {
    title = title.substring(0, title.length - 4);
  }
  title = title.replaceAll('_', ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  return title.isEmpty ? 'Sans titre' : title;
}

const _accents = <String, String>{
  'à': 'a', 'â': 'a', 'ä': 'a', 'á': 'a', 'ã': 'a', 'å': 'a',
  'é': 'e', 'è': 'e', 'ê': 'e', 'ë': 'e',
  'î': 'i', 'ï': 'i', 'í': 'i', 'ì': 'i',
  'ô': 'o', 'ö': 'o', 'ó': 'o', 'ò': 'o', 'õ': 'o',
  'ù': 'u', 'û': 'u', 'ü': 'u', 'ú': 'u',
  'ç': 'c', 'ñ': 'n', 'ÿ': 'y', 'œ': 'oe', 'æ': 'ae',
};

/// Met en minuscules et retire les accents, pour que la recherche
/// « ecologie » trouve « Écologie » et pour trier les titres proprement.
String normalizeForSearch(String input) {
  final buffer = StringBuffer();
  for (final rune in input.toLowerCase().runes) {
    final char = String.fromCharCode(rune);
    buffer.write(_accents[char] ?? char);
  }
  return buffer.toString();
}

/// Taille lisible en français : « 512 Ko », « 12,4 Mo », « 1,2 Go ».
String formatSize(int bytes) {
  const ko = 1024;
  const mo = 1024 * 1024;
  if (bytes < mo) return '${(bytes / ko).round()} Ko';
  final inMo = bytes / mo;
  if (inMo < 1024) return '${_fr(inMo)} Mo';
  return '${_fr(inMo / 1024)} Go';
}

String _fr(double value) =>
    (value >= 100 ? value.round().toString() : value.toStringAsFixed(1))
        .replaceAll('.', ',');

/// Un vrai PDF contient la signature « %PDF » dans ses 1024 premiers octets.
bool looksLikePdf(List<int> header) {
  for (var i = 0; i + 3 < header.length; i++) {
    if (header[i] == 0x25 && // %
        header[i + 1] == 0x50 && // P
        header[i + 2] == 0x44 && // D
        header[i + 3] == 0x46) {
      // F
      return true;
    }
  }
  return false;
}
