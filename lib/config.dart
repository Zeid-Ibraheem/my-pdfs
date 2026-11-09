/// Informations centrales de l'appli : un seul endroit à modifier lors
/// d'une mise à jour (voir docs/ARCHITECTURE.md, « Faire évoluer l'appli »).
class AppInfo {
  AppInfo._();

  static const name = 'My PDFs';
  static const version = '0.7.0';

  /// Version d'API minimale attendue du serveur (server/app.py, API_VERSION).
  /// À augmenter quand l'appli utilise une nouvelle route du serveur.
  static const minServerApi = 2;
}

/// Clés des réglages enregistrés dans la table settings.
///
/// Ne jamais renommer une clé existante : les réglages déjà enregistrés sur
/// les téléphones seraient perdus. Pour changer de format, créer une
/// nouvelle clé et reprendre l'ancienne valeur dans une migration.
class SettingKeys {
  SettingKeys._();

  // Bibliothèque
  static const sort = 'tri';
  static const sortReversed = 'tri_inverse';
  static const filter = 'filtre';

  // Lecteur
  static const nightMode = 'mode_nuit';

  // Serveur
  static const serverUrl = 'serveur_url';
  static const serverToken = 'serveur_jeton';
  static const autoBackup = 'sauvegarde_auto';
  static const autoUpload = 'envoi_auto';
  static const lastBackup = 'derniere_sauvegarde';
  static const cacheGb = 'cache_go';

  // Synchronisation
  static const syncSeq = 'synchro_seq';
  static const syncEpoch = 'synchro_epoch';
}
