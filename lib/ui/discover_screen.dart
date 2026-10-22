import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/library.dart';
import '../data/server_api.dart';
import 'common.dart';

/// Onglet Découvrir : cherche des livres libres en ligne (Internet Archive,
/// Open Library, Gallica). Le serveur fait les recherches et télécharge
/// les livres ajoutés, pour économiser la batterie et les données mobiles.
class DiscoverScreen extends StatefulWidget {
  const DiscoverScreen({super.key, required this.library});

  final Library library;

  @override
  State<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends State<DiscoverScreen> {
  final _field = TextEditingController();
  DiscoverResponse? _response;
  bool _loading = false;
  String? _error;
  final Set<String> _importing = {};
  final Set<String> _imported = {};

  Library get _lib => widget.library;

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  String _key(DiscoverResult r) => '${r.source}:${r.id}';

  Future<void> _search() async {
    final query = _field.text.trim();
    if (query.isEmpty) return;
    FocusScope.of(context).unfocus();
    final api = _lib.api;
    if (api == null) {
      setState(() => _error =
          'Configure ton serveur dans l’onglet Réglages : c’est lui qui '
          'cherche et télécharge les livres.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final response = await api.discover(query);
      if (mounted) setState(() => _response = response);
    } on ServerException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _add(DiscoverResult result) async {
    final api = _lib.api;
    if (api == null) return;
    final key = _key(result);
    setState(() => _importing.add(key));
    try {
      final book = await api.importDiscovered(result);
      await _lib.syncWithServer();
      if (!mounted) return;
      setState(() => _imported.add(key));
      showSnack(context,
          '« ${book.title} » ajouté à ta bibliothèque (sur ton serveur)');
    } on ServerException catch (e) {
      if (mounted) showSnack(context, e.message);
    } finally {
      if (mounted) setState(() => _importing.remove(key));
    }
  }

  Future<void> _openLink(String url) async {
    try {
      final ok = await launchUrl(Uri.parse(url),
          mode: LaunchMode.externalApplication);
      if (!ok && mounted) showSnack(context, 'Impossible d’ouvrir le lien');
    } catch (_) {
      if (mounted) showSnack(context, 'Impossible d’ouvrir le lien');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Découvrir des livres libres')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: TextField(
              controller: _field,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _search(),
              decoration: InputDecoration(
                hintText: 'Titre, auteur…',
                prefixIcon: const Icon(Icons.travel_explore),
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.arrow_forward),
                  tooltip: 'Chercher',
                  onPressed: _search,
                ),
              ),
            ),
          ),
          Expanded(child: _buildResults()),
        ],
      ),
    );
  }

  Widget _buildResults() {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return ListView(
        padding: const EdgeInsets.all(24),
        children: [Text(_error!, style: muted)],
      );
    }
    final response = _response;
    if (response == null) {
      return ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(
            'Cherche des livres libres de droits ou en accès libre sur '
            'Internet Archive, Open Library et Gallica.\n\n'
            '• « Ajouter » : ton serveur télécharge le livre, qui apparaît '
            'ensuite dans ta bibliothèque.\n'
            '• « Emprunter » / « Voir » : le livre n’est pas en accès libre '
            '(ou pas importable automatiquement) ; il s’ouvre dans le '
            'navigateur.\n\n'
            'Le plus souvent, tu trouveras des classiques du domaine public '
            'et des livres anciens ; les livres récents sont rarement libres.',
            style: muted,
          ),
        ],
      );
    }
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        if (response.errors.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'Sources indisponibles pour l’instant : '
              '${response.errors.join(' ; ')}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
        if (response.results.isEmpty)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Text('Aucun livre trouvé.', style: muted),
          ),
        for (final result in response.results) _buildResult(result, theme),
      ],
    );
  }

  Widget _buildResult(DiscoverResult result, ThemeData theme) {
    final key = _key(result);
    final details = [
      if (result.authors.isNotEmpty) result.authors,
      if (result.year.isNotEmpty) result.year,
      result.origin,
    ].join(' · ');

    final Widget action;
    if (result.status == 'download') {
      if (_importing.contains(key)) {
        action = const SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        );
      } else if (_imported.contains(key)) {
        action = const Icon(Icons.check_circle_outline);
      } else {
        action = FilledButton.tonal(
          onPressed: () => _add(result),
          child: const Text('Ajouter'),
        );
      }
    } else {
      action = OutlinedButton(
        onPressed: () => _openLink(result.url),
        child: Text(result.status == 'borrow' ? 'Emprunter' : 'Voir'),
      );
    }

    return ListTile(
      title: Text(result.title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text(details, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: action,
      onTap: () => _openLink(result.url),
    );
  }
}
