import 'package:material_ui/material_ui.dart';

import '../data/book.dart';
import '../data/library.dart';
import '../data/server_api.dart';
import '../util/text.dart';
import 'common.dart';
import '../config.dart';


/// Onglet Réglages : connexion au serveur, place sur le téléphone,
/// sauvegarde des notes et de la progression.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.library});

  final Library library;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _url = TextEditingController();
  final _token = TextEditingController();
  bool _showToken = false;
  bool _busy = false;
  ServerUsage? _usage;
  String? _serverError;
  bool _autoBackup = true;
  bool _autoUpload = false;
  int _cacheGb = 5;
  DateTime? _lastBackup;
  int _localOnlyBytes = 0;
  int _cachedBytes = 0;
  int _phoneOnlyBooks = 0;

  Library get _lib => widget.library;

  @override
  void initState() {
    super.initState();
    _url.text = _lib.serverUrl ?? '';
    _token.text = _lib.serverToken ?? '';
    _lib.addListener(_onLibraryChanged);
    _load();
    if (_lib.hasServer) _refreshUsage();
  }

  @override
  void dispose() {
    _lib.removeListener(_onLibraryChanged);
    _url.dispose();
    _token.dispose();
    super.dispose();
  }

  void _onLibraryChanged() {
    _load();
  }

  Future<void> _load() async {
    final autoBackup = await _lib.autoBackupEnabled();
    final autoUpload = await _lib.autoUploadEnabled();
    final cacheGb = await _lib.cacheLimitGb();
    final lastBackup = await _lib.lastBackup();
    final (localOnly, cached) = await _lib.deviceUsage();
    final phoneOnly =
        (await _lib.db.books()).where((b) => b.onDevice && !b.onServer).length;
    if (!mounted) return;
    setState(() {
      _autoBackup = autoBackup;
      _autoUpload = autoUpload;
      _cacheGb = cacheGb;
      _lastBackup = lastBackup;
      _localOnlyBytes = localOnly;
      _cachedBytes = cached;
      _phoneOnlyBooks = phoneOnly;
    });
  }

  Future<void> _refreshUsage() async {
    final api = _lib.api;
    if (api == null) return;
    try {
      final usage = await api.usage();
      if (mounted) {
        setState(() {
          _usage = usage;
          _serverError = null;
        });
      }
    } on ServerException catch (e) {
      if (mounted) setState(() => _serverError = e.message);
    }
  }

  /// Exécute une action longue en affichant les erreurs proprement.
  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } on ServerException catch (e) {
      if (mounted) showSnack(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    await _load();
  }

  Future<void> _saveServer() => _run(() async {
        FocusScope.of(context).unfocus();
        final usage = await _lib.saveServerConfig(_url.text, _token.text);
        if (!mounted) return;
        setState(() {
          _url.text = _lib.serverUrl ?? '';
          _usage = usage;
          _serverError = null;
        });
        showSnack(context, 'Connecté au serveur');
        final added = await _lib.syncWithServer();
        if (added > 0 && mounted) {
          showSnack(context,
              '$added livre${added > 1 ? 's' : ''} du serveur ajouté${added > 1 ? 's' : ''}');
        }
      });

  Future<void> _forgetServer() => _run(() async {
        final ok = await confirmDialog(
          context,
          title: 'Oublier le serveur ?',
          message: 'L’appli ne s’y connectera plus. Rien n’est supprimé, ni '
              'sur le téléphone ni sur le serveur.',
          action: 'Oublier',
        );
        if (!ok) return;
        await _lib.forgetServer();
        if (!mounted) return;
        setState(() {
          _url.clear();
          _token.clear();
          _usage = null;
          _serverError = null;
        });
      });

  Future<void> _sync() => _run(() async {
        final added = await _lib.syncWithServer();
        await _refreshUsage();
        if (mounted) {
          showSnack(
              context,
              added == 0
                  ? 'Bibliothèque à jour'
                  : '$added livre${added > 1 ? 's' : ''} ajouté${added > 1 ? 's' : ''}');
        }
      });

  Future<void> _uploadAll() => _run(() async {
        final (sent, failed) = await runWithProgress<(int, int)>(
          context,
          'Envoi sur le serveur',
          (progress, detail) => _lib.uploadAll(
            onProgress: (index, total, name) {
              progress.value = total == 0 ? null : index / total;
              detail.value = '${index + 1} / $total · $name';
            },
          ),
        );
        await _refreshUsage();
        if (mounted) {
          showSnack(
              context,
              failed == 0
                  ? '$sent livre${sent > 1 ? 's' : ''} envoyé${sent > 1 ? 's' : ''}'
                  : '$sent envoyé${sent > 1 ? 's' : ''}, $failed en échec');
        }
      });

  Future<void> _backupNow() => _run(() async {
        await _lib.backupNow();
        if (mounted) showSnack(context, 'Sauvegarde envoyée sur le serveur');
      });

  /// Efface définitivement toutes les sauvegardes (et, au choix, les livres),
  /// sur le téléphone et sur le serveur. Double confirmation.
  Future<void> _wipeEverything() async {
    final typed = TextEditingController();
    var withBooks = false;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (dialogContext, setDialog) => AlertDialog(
          title: const Text('Tout effacer définitivement ?'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Seront supprimés, sans retour possible :\n'
                  '• notes, surlignages, marque-pages, catégories, pages '
                  'en cours et carnet de lectures, sur ce téléphone et sur '
                  'le serveur ;\n'
                  '• toutes les sauvegardes du serveur ;\n'
                  '• les fichiers temporaires de l’appli.\n\n'
                  '${_lib.hasServer ? 'Ton autre profil effacera aussi les siens à sa prochaine synchro.' : 'Aucun serveur configuré : seul ce téléphone est concerné.'}',
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: withBooks,
                  onChanged: (value) =>
                      setDialog(() => withBooks = value ?? false),
                  title: const Text('Supprimer aussi tous les livres (PDF)'),
                  subtitle: Text(_lib.hasServer
                      ? 'Sur ce téléphone et sur le serveur'
                      : 'Sur ce téléphone'),
                ),
                const SizedBox(height: 8),
                const Text('Tape SUPPRIMER pour confirmer :'),
                TextField(
                  controller: typed,
                  autocorrect: false,
                  textCapitalization: TextCapitalization.characters,
                  onChanged: (_) => setDialog(() {}),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Annuler'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(dialogContext).colorScheme.error,
                foregroundColor: Theme.of(dialogContext).colorScheme.onError,
              ),
              onPressed: typed.text.trim() == 'SUPPRIMER'
                  ? () => Navigator.pop(dialogContext, true)
                  : null,
              child: const Text('Tout effacer'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return;
    await _run(() async {
      await runWithProgress<void>(
        context,
        'Effacement',
        (progress, detail) => _lib.wipeEverything(books: withBooks),
      );
      if (mounted) {
        showSnack(context,
            withBooks ? 'Tout a été effacé, livres compris' : 'Sauvegardes effacées');
      }
    });
  }

  /// Rapatrie tous les livres sur le téléphone puis vide entièrement le
  /// serveur (livres, titres, état, sauvegardes, configuration).
  Future<void> _leaveServer() async {
    final List<Book> missing;
    try {
      missing = await _lib.serverOnlyBooks();
    } on ServerException catch (e) {
      if (mounted) showSnack(context, e.message);
      return;
    }
    if (!mounted) return;
    final size = missing.fold<int>(0, (sum, b) => sum + b.sizeBytes);
    final typed = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (dialogContext, setDialog) => AlertDialog(
          title: const Text('Tout rapatrier et vider le serveur ?'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '1. Téléchargement sur ce téléphone : '
                  '${missing.isEmpty ? 'rien à télécharger, tout y est déjà' : '${missing.length} livre${missing.length > 1 ? 's' : ''} (${formatSize(size)})'}.\n'
                  '2. Puis suppression de TOUT sur le serveur : livres, '
                  'titres, texte, couvertures, notes synchronisées, '
                  'sauvegardes et configuration (jeton compris). Le serveur '
                  's’arrête.\n'
                  '3. L’appli oublie le serveur. Tes notes, surlignages, '
                  'catégories, carnet et pages en cours restent sur ce '
                  'téléphone.\n\n'
                  'Si un seul livre échoue au téléchargement, rien n’est '
                  'supprimé sur le serveur.\n\n'
                  'Ton autre profil perdra l’accès aux livres qui n’étaient '
                  'que sur le serveur : rapatrie-les là-bas d’abord si tu '
                  'en as besoin.',
                ),
                const SizedBox(height: 12),
                const Text('Tape TOUT SUPPRIMER pour confirmer :'),
                TextField(
                  controller: typed,
                  autocorrect: false,
                  textCapitalization: TextCapitalization.characters,
                  onChanged: (_) => setDialog(() {}),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Annuler'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(dialogContext).colorScheme.error,
                foregroundColor: Theme.of(dialogContext).colorScheme.onError,
              ),
              onPressed: typed.text.trim() == 'TOUT SUPPRIMER'
                  ? () => Navigator.pop(dialogContext, true)
                  : null,
              child: const Text('Rapatrier et vider'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return;
    await _run(() async {
      await runWithProgress<void>(
        context,
        'Rapatriement',
        (progress, detail) => _lib.repatriateAndLeaveServer(
          onProgress: (index, total, name) {
            progress.value = total == 0 ? null : index / total;
            detail.value = index < total ? '${index + 1} / $total · $name' : name;
          },
        ),
      );
      if (!mounted) return;
      setState(() {
        _url.clear();
        _token.clear();
        _usage = null;
        _serverError = null;
      });
      showSnack(context,
          'Tout est sur le téléphone, le serveur est vide et arrêté');
    });
  }

  Future<void> _restore() => _run(() async {
        final ok = await confirmDialog(
          context,
          title: 'Restaurer la dernière sauvegarde ?',
          message: 'Catégories, notes, surlignages, marque-pages et '
              'progression du téléphone seront remplacés par ceux de la '
              'dernière sauvegarde du serveur.',
          action: 'Restaurer',
        );
        if (!ok || !mounted) return;
        await runWithProgress<void>(
          context,
          'Restauration',
          (progress, detail) => _lib.restoreLatestBackup(),
        );
        if (mounted) showSnack(context, 'Sauvegarde restaurée');
      });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final usage = _usage;
    final connected = _lib.hasServer;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Réglages'),
        bottom: _busy
            ? const PreferredSize(
                preferredSize: Size.fromHeight(4),
                child: LinearProgressIndicator(),
              )
            : null,
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          const _Header('Serveur'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              children: [
                TextField(
                  controller: _url,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: 'Adresse',
                    hintText: 'http://100.x.y.z:8765',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _token,
                  obscureText: !_showToken,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: 'Jeton',
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      icon: Icon(_showToken
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined),
                      tooltip: _showToken ? 'Masquer' : 'Afficher',
                      onPressed: () =>
                          setState(() => _showToken = !_showToken),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'L’adresse et le jeton s’affichent à la fin de '
                  'l’installation du serveur (server/install.sh). '
                  'Tailscale doit être actif sur le téléphone.',
                  style: muted,
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    FilledButton(
                      onPressed: _busy ? null : _saveServer,
                      child: const Text('Tester et enregistrer'),
                    ),
                    const SizedBox(width: 8),
                    if (connected)
                      TextButton(
                        onPressed: _busy ? null : _forgetServer,
                        child: const Text('Oublier'),
                      ),
                  ],
                ),
              ],
            ),
          ),
          if (connected && _serverError != null)
            ListTile(
              leading: Icon(Icons.cloud_off, color: theme.colorScheme.error),
              title: const Text('Serveur injoignable'),
              subtitle: Text(_serverError!),
              trailing: IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: 'Réessayer',
                onPressed: _refreshUsage,
              ),
            ),
          if (connected && usage != null) ...[
            ListTile(
              leading: const Icon(Icons.cloud_done_outlined),
              title: Text('${formatSize(usage.usedBytes)} utilisés sur '
                  '${formatSize(usage.quotaBytes)}'),
              subtitle: Text(
                '${usage.books} livre${usage.books > 1 ? 's' : ''} sur le serveur'
                '${usage.textPending > 0 ? ' · texte en cours d’extraction pour ${usage.textPending}' : ''}',
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: LinearProgressIndicator(
                value: usage.quotaBytes == 0
                    ? 0.0
                    : (usage.usedBytes / usage.quotaBytes)
                        .clamp(0.0, 1.0)
                        .toDouble(),
              ),
            ),
          ],
          ListTile(
            enabled: connected && !_busy,
            leading: const Icon(Icons.sync),
            title: const Text('Synchroniser maintenant'),
            subtitle: const Text('Récupère la liste des livres du serveur'),
            onTap: _sync,
          ),
          ListTile(
            enabled: connected && !_busy && _phoneOnlyBooks > 0,
            leading: const Icon(Icons.cloud_upload_outlined),
            title: const Text('Envoyer les livres du téléphone sur le serveur'),
            subtitle: Text(_phoneOnlyBooks == 0
                ? 'Tous tes livres sont déjà sur le serveur'
                : '$_phoneOnlyBooks livre${_phoneOnlyBooks > 1 ? 's' : ''} '
                    'seulement sur le téléphone'),
            onTap: _uploadAll,
          ),
          SwitchListTile(
            secondary: const Icon(Icons.upload_file_outlined),
            title: const Text('Envoyer automatiquement les nouveaux imports'),
            subtitle: const Text(
                'Désactivé : les livres restent sur le téléphone ; le bouton '
                'nuage de chaque livre les envoie quand tu veux'),
            value: _autoUpload,
            onChanged: connected
                ? (value) async {
                    setState(() => _autoUpload = value);
                    await _lib.setAutoUpload(value);
                  }
                : null,
          ),

          const _Header('Place sur le téléphone'),
          ListTile(
            leading: const Icon(Icons.smartphone),
            title: Text('${formatSize(_localOnlyBytes + _cachedBytes)} '
                'de livres sur le téléphone'),
            subtitle: Text(
              '${formatSize(_localOnlyBytes)} seulement ici · '
              '${formatSize(_cachedBytes)} de copies du serveur',
            ),
          ),
          ListTile(
            title: Text('Garder au maximum $_cacheGb Go de livres du serveur'),
            subtitle: Slider(
              value: _cacheGb.toDouble(),
              min: 1,
              max: 32,
              divisions: 31,
              label: '$_cacheGb Go',
              onChanged: (value) => setState(() => _cacheGb = value.round()),
              onChangeEnd: (value) => _lib.setCacheLimitGb(value.round()),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Au-delà, les livres du serveur les moins récemment lus sont '
              'retirés du téléphone (ils restent sur le serveur et se '
              'retéléchargent à l’ouverture). Les livres épinglés et ceux '
              'qui ne sont que sur le téléphone ne sont jamais retirés.',
              style: muted,
            ),
          ),

          const _Header('Sauvegarde'),
          SwitchListTile(
            secondary: const Icon(Icons.backup_outlined),
            title: const Text('Sauvegarde automatique après chaque lecture'),
            subtitle: const Text(
                'Catégories, notes, surlignages, marque-pages et progression'),
            value: _autoBackup,
            onChanged: connected
                ? (value) async {
                    setState(() => _autoBackup = value);
                    await _lib.setAutoBackup(value);
                  }
                : null,
          ),
          ListTile(
            enabled: connected && !_busy,
            leading: const Icon(Icons.save_outlined),
            title: const Text('Sauvegarder maintenant'),
            subtitle: Text(_lastBackup == null
                ? 'Jamais sauvegardé'
                : 'Dernière sauvegarde : ${formatDateTime(_lastBackup!)}'),
            onTap: _backupNow,
          ),
          ListTile(
            enabled: connected && !_busy,
            leading: const Icon(Icons.settings_backup_restore),
            title: const Text('Restaurer la dernière sauvegarde'),
            subtitle: const Text(
                'Après un changement ou une réinitialisation du téléphone'),
            onTap: _restore,
          ),

          const _Header('Quitter le serveur'),
          ListTile(
            enabled: connected && !_busy,
            leading: Icon(Icons.cloud_off_outlined,
                color: theme.colorScheme.error),
            title: const Text('Tout rapatrier et vider le serveur'),
            subtitle: const Text(
                'Télécharge ici tous les livres qui n’y sont pas, puis '
                'supprime absolument tout sur le serveur, configuration '
                'comprise'),
            onTap: _leaveServer,
          ),

          const _Header('Effacement'),
          ListTile(
            enabled: !_busy,
            leading: Icon(Icons.delete_forever_outlined,
                color: theme.colorScheme.error),
            title: Text('Tout effacer définitivement',
                style: TextStyle(color: theme.colorScheme.error)),
            subtitle: const Text(
                'Notes, surlignages, marque-pages, catégories, pages en cours '
                'et sauvegardes, ici et sur le serveur (livres au choix)'),
            onTap: _wipeEverything,
          ),

          const _Header('À propos'),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('${AppInfo.name} ${AppInfo.version}'),
            subtitle: const Text(
              'Tes PDF ne sont jamais modifiés : notes, surlignages et '
              'progression sont enregistrés à part, liés à l’empreinte '
              'de chaque fichier.',
            ),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
      child: Text(
        text,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }
}
