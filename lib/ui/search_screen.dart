import 'package:material_ui/material_ui.dart';

import '../data/library.dart';
import '../data/server_api.dart';
import 'common.dart';

/// Onglet Recherche : cherche un mot dans le texte de tous les livres
/// stockés sur le serveur (le serveur a extrait leur texte).
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key, required this.library});

  final Library library;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _field = TextEditingController();
  List<SearchHit>? _hits;
  bool _loading = false;
  String? _error;

  Library get _lib => widget.library;

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final query = _field.text.trim();
    if (query.isEmpty) return;
    FocusScope.of(context).unfocus();
    final api = _lib.api;
    if (api == null) {
      setState(() => _error =
          'Configure ton serveur dans l’onglet Réglages pour chercher dans '
          'tous tes livres.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final hits = await api.search(query);
      if (mounted) setState(() => _hits = hits);
    } on ServerException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _open(SearchHit hit) async {
    var book = await _lib.db.book(hit.bookId);
    if (book == null && _lib.hasServer) {
      try {
        await _lib.syncWithServer();
      } on ServerException catch (e) {
        if (mounted) showSnack(context, e.message);
        return;
      }
      book = await _lib.db.book(hit.bookId);
    }
    if (!mounted) return;
    if (book == null) {
      showSnack(context, 'Livre introuvable');
      return;
    }
    await openBook(context, _lib, book, page: hit.page);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Recherche dans les livres')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: TextField(
              controller: _field,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _search(),
              decoration: InputDecoration(
                hintText: 'Un mot ou une expression…',
                prefixIcon: const Icon(Icons.search),
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
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return _Message(_error!);
    final hits = _hits;
    if (hits == null) {
      return const _Message(
        'Cherche un mot dans le texte de tous les livres stockés sur ton '
        'serveur, sans tenir compte des accents ni des majuscules.\n\n'
        'Le texte des pages scannées (images) n’est pas cherchable.\n\n'
        'Pour chercher seulement dans le livre ouvert : loupe en haut du '
        'lecteur.',
      );
    }
    if (hits.isEmpty) return const _Message('Aucun résultat.');

    // Regroupe les passages par livre, dans l'ordre de pertinence.
    final groups = <String, List<SearchHit>>{};
    for (final hit in hits) {
      groups.putIfAbsent(hit.bookId, () => []).add(hit);
    }
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        for (final group in groups.values) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text(
              '${group.first.title} (${group.length})',
              style: theme.textTheme.titleSmall,
            ),
          ),
          for (final hit in group)
            ListTile(
              dense: true,
              leading: Text('p. ${hit.page}',
                  style: theme.textTheme.labelMedium),
              title: Text.rich(
                _snippet(hit.snippet, theme),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => _open(hit),
            ),
        ],
      ],
    );
  }

  /// Met en gras les mots trouvés (entourés de \u0001 et \u0002).
  TextSpan _snippet(String text, ThemeData theme) {
    final spans = <TextSpan>[];
    final buffer = StringBuffer();
    var highlighted = false;
    void flush() {
      if (buffer.isEmpty) return;
      spans.add(TextSpan(
        text: buffer.toString(),
        style: highlighted
            ? TextStyle(
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.primary,
              )
            : null,
      ));
      buffer.clear();
    }

    for (final rune in text.replaceAll('\n', ' ').runes) {
      if (rune == 1 || rune == 2) {
        flush();
        highlighted = rune == 1;
      } else {
        buffer.writeCharCode(rune);
      }
    }
    flush();
    return TextSpan(children: spans);
  }
}

class _Message extends StatelessWidget {
  const _Message(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(
          text,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
      ],
    );
  }
}
