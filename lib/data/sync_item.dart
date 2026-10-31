import 'dart:convert';
import 'dart:math';

/// Un élément de l'état synchronisé entre profils / appareils via le serveur.
///
/// Types et clés :
/// - progress   <livre>              {page, opened}   page en cours
/// - title      <livre>              {title}          titre renommé
/// - bookmark   <livre>|<page>       {}               marque-page
/// - category   <clé de catégorie>   {name}           catégorie
/// - bookcat    <livre>|<clé cat.>   {}               livre rangé dans une catégorie
/// - annotation <uid>                {book_id, page, quote, rects, color,
///                                    note, created_at}
///
/// Pour un même (type, clé), la version la plus récente gagne. Une
/// suppression est un élément marqué [deleted] (sinon l'autre profil le
/// recréerait à la synchro suivante).
class SyncItem {
  const SyncItem({
    required this.kind,
    required this.key,
    required this.data,
    required this.updatedAt,
    this.deleted = false,
  });

  final String kind;
  final String key;
  final Map<String, Object?> data;

  /// Date de la modification (ms) : c'est elle qui départage les conflits.
  final int updatedAt;
  final bool deleted;

  /// Ordre d'application : les catégories avant les rangements qui les citent.
  int get applyOrder => kind == 'category' ? 0 : 1;

  Map<String, Object?> toJson() => {
        'kind': kind,
        'key': key,
        'data': data,
        'updated_at': updatedAt,
        'deleted': deleted,
      };

  factory SyncItem.fromJson(Map<String, dynamic> json) {
    final data = json['data'];
    return SyncItem(
      kind: json['kind'] as String,
      key: json['key'] as String,
      data: data is Map ? Map<String, Object?>.from(data) : const {},
      updatedAt: (json['updated_at'] as num).toInt(),
      deleted: json['deleted'] == true,
    );
  }

  factory SyncItem.fromRow(Map<String, Object?> row) {
    Map<String, Object?> data = const {};
    try {
      final decoded = jsonDecode(row['data'] as String? ?? '{}');
      if (decoded is Map) data = Map<String, Object?>.from(decoded);
    } on FormatException {
      // Donnée abîmée : on garde un élément vide plutôt que de planter.
    }
    return SyncItem(
      kind: row['kind'] as String,
      key: row['key'] as String,
      data: data,
      updatedAt: row['updated_at'] as int,
      deleted: (row['deleted'] as int? ?? 0) == 1,
    );
  }
}

/// Identifiant aléatoire de 32 caractères hexadécimaux.
String newUid() {
  final random = Random.secure();
  return List<String>.generate(
      16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

/// Lit un entier dans des données JSON (int ou double), ou `null`.
int? jsonInt(Object? value) => value is num ? value.toInt() : null;
