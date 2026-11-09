import 'package:material_ui/material_ui.dart';

import '../data/library.dart';
import '../data/reading_entry.dart';
import '../data/sync_item.dart';
import '../util/text.dart';
import 'common.dart';

/// Onglet Lectures : carnet des livres lus, en cours et à lire, avec une
/// note sur 5 et un avis. Les livres importés y sont ajoutés tout seuls ;
/// on peut aussi y noter des livres papier ou lus ailleurs.
class ReadingLogScreen extends StatefulWidget {
  const ReadingLogScreen({super.key, required this.library});

  final Library library;

  @override
  State<ReadingLogScreen> createState() => _ReadingLogScreenState();
}

class _ReadingLogScreenState extends State<ReadingLogScreen> {
  List<ReadingEntry> _entries = const [];
  Set<String> _booksHere = const {};
  int _totalReadSeconds = 0;
  ReadingStatus? _filter; // null = tous
  bool _loading = true;

  Library get _lib => widget.library;

  @override
  void initState() {
    super.initState();
    _lib.addListener(_reload);
    _reload();
  }

  @override
  void dispose() {
    _lib.removeListener(_reload);
    super.dispose();
  }

  Future<void> _reload() async {
    final entries = await _lib.db.readingEntries();
    final allBooks = await _lib.db.books();
    final books = {for (final b in allBooks) b.id};
    final totalSeconds =
        allBooks.fold<int>(0, (sum, b) => sum + b.readSeconds);
    if (!mounted) return;
    entries.sort(_compare);
    setState(() {
      _entries = entries;
      _booksHere = books;
      _totalReadSeconds = totalSeconds;
      _loading = false;
    });
  }

  /// En cours d'abord, puis lus (les plus récents d'abord), puis à lire.
  static int _compare(ReadingEntry a, ReadingEntry b) {
    int rank(ReadingStatus s) => switch (s) {
          ReadingStatus.reading => 0,
          ReadingStatus.read => 1,
          ReadingStatus.toRead => 2,
        };
    final byStatus = rank(a.status) - rank(b.status);
    if (byStatus != 0) return byStatus;
    final dateA = a.finishedAt ?? a.updatedAt;
    final dateB = b.finishedAt ?? b.updatedAt;
    final byDate = dateB.compareTo(dateA);
    if (byDate != 0) return byDate;
    return normalizeForSearch(a.title).compareTo(normalizeForSearch(b.title));
  }

  List<ReadingEntry> get _visible => _filter == null
      ? _entries
      : _entries.where((e) => e.status == _filter).toList();

  Future<void> _edit([ReadingEntry? entry]) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => _EntryEditor(
        library: _lib,
        entry: entry,
        bookHere: entry?.bookId != null && _booksHere.contains(entry!.bookId),
      ),
    ));
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Mes lectures')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(),
        icon: const Icon(Icons.add),
        label: const Text('Ajouter'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                _buildFilters(),
                Expanded(child: _buildList()),
              ],
            ),
    );
  }

  Widget _buildFilters() {
    int count(ReadingStatus? s) =>
        s == null ? _entries.length : _entries.where((e) => e.status == s).length;
    Widget chip(ReadingStatus? s, String label) => ChoiceChip(
          label: Text('$label (${count(s)})'),
          selected: _filter == s,
          showCheckmark: false,
          onSelected: (_) => setState(() => _filter = s),
        );
    return SizedBox(
      height: 52,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        children: [
          chip(null, 'Tous'),
          for (final s in ReadingStatus.values) ...[
            const SizedBox(width: 8),
            chip(s, s.label),
          ],
        ],
      ),
    );
  }

  Widget _buildStats(ThemeData theme) {
    final year = DateTime.now().year;
    final read = _entries.where((e) => e.status == ReadingStatus.read);
    final thisYear = read.where((e) => e.finishedAt?.year == year).length;
    final rated = read.where((e) => e.rating > 0).toList();
    final average = rated.isEmpty
        ? null
        : rated.fold<int>(0, (sum, e) => sum + e.rating) / rated.length;
    final parts = [
      '${read.length} lu${read.length > 1 ? 's' : ''}',
      '$thisYear en $year',
      if (_totalReadSeconds >= 60)
        '${formatDuration(_totalReadSeconds)} de lecture',
      if (average != null)
        'note moyenne ${average.toStringAsFixed(1).replaceAll('.', ',')} / 5',
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Text(
        parts.join(' · '),
        style: theme.textTheme.labelMedium
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
    );
  }

  Widget _buildList() {
    final theme = Theme.of(context);
    final entries = _visible;
    if (_entries.isEmpty) {
      return ListView(
        padding: const EdgeInsets.all(32),
        children: const [
          Text(
            'Ton carnet est vide.\n\n'
            'Les livres que tu importes y apparaissent tout seuls. Tu peux '
            'aussi y noter des livres papier ou lus ailleurs avec « Ajouter ».',
            textAlign: TextAlign.center,
          ),
        ],
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 96),
      itemCount: entries.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) return _buildStats(theme);
        final entry = entries[index - 1];
        final details = [
          if (entry.author.isNotEmpty) entry.author,
          entry.status.label,
          if (entry.status == ReadingStatus.read && entry.finishedAt != null)
            'fini le ${formatDate(entry.finishedAt!)}',
        ].join(' · ');
        return ListTile(
          leading: Icon(
            entry.bookId != null && _booksHere.contains(entry.bookId)
                ? Icons.picture_as_pdf_outlined
                : Icons.menu_book_outlined,
          ),
          title: Text(entry.title, maxLines: 2, overflow: TextOverflow.ellipsis),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(details, maxLines: 1, overflow: TextOverflow.ellipsis),
              if (entry.rating > 0) _Stars(rating: entry.rating, size: 16),
              if (entry.review.trim().isNotEmpty)
                Text(entry.review.trim(),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontStyle: FontStyle.italic)),
            ],
          ),
          isThreeLine: entry.rating > 0 || entry.review.trim().isNotEmpty,
          onTap: () => _edit(entry),
        );
      },
    );
  }
}

/// Étoiles de note (affichage seul, ou cliquables avec [onChanged]).
class _Stars extends StatelessWidget {
  const _Stars({required this.rating, this.size = 32, this.onChanged});

  final int rating;
  final double size;
  final ValueChanged<int>? onChanged;

  @override
  Widget build(BuildContext context) {
    final color = Colors.amber.shade700;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 1; i <= 5; i++)
          onChanged == null
              ? Icon(i <= rating ? Icons.star : Icons.star_border,
                  size: size, color: color)
              : IconButton(
                  iconSize: size,
                  visualDensity: VisualDensity.compact,
                  tooltip: '$i / 5',
                  // Toucher l'étoile déjà choisie retire la note.
                  onPressed: () => onChanged!(i == rating ? 0 : i),
                  icon: Icon(i <= rating ? Icons.star : Icons.star_border,
                      color: color),
                ),
      ],
    );
  }
}

/// Écran d'ajout ou de modification d'une entrée.
class _EntryEditor extends StatefulWidget {
  const _EntryEditor({
    required this.library,
    required this.entry,
    required this.bookHere,
  });

  final Library library;
  final ReadingEntry? entry;
  final bool bookHere;

  @override
  State<_EntryEditor> createState() => _EntryEditorState();
}

class _EntryEditorState extends State<_EntryEditor> {
  late final TextEditingController _title;
  late final TextEditingController _author;
  late final TextEditingController _review;
  late ReadingStatus _status;
  late int _rating;
  DateTime? _finishedAt;
  String? _error;

  @override
  void initState() {
    super.initState();
    final e = widget.entry;
    _title = TextEditingController(text: e?.title ?? '');
    _author = TextEditingController(text: e?.author ?? '');
    _review = TextEditingController(text: e?.review ?? '');
    _status = e?.status ?? ReadingStatus.read;
    _rating = e?.rating ?? 0;
    _finishedAt = e?.finishedAt;
  }

  @override
  void dispose() {
    _title.dispose();
    _author.dispose();
    _review.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _finishedAt ?? now,
      firstDate: DateTime(1950),
      lastDate: now,
      helpText: 'Date de fin de lecture',
    );
    if (picked != null) setState(() => _finishedAt = picked);
  }

  Future<void> _save() async {
    final title = _title.text.trim();
    if (title.isEmpty) {
      setState(() => _error = 'Le titre est obligatoire');
      return;
    }
    final now = DateTime.now();
    final old = widget.entry;
    final finished = _status == ReadingStatus.read ? (_finishedAt ?? now) : null;
    final entry = ReadingEntry(
      uid: old?.uid ?? newUid(),
      title: title,
      author: _author.text.trim(),
      rating: _rating,
      review: _review.text.trim(),
      status: _status,
      finishedAt: finished,
      bookId: old?.bookId,
      createdAt: old?.createdAt ?? now,
      updatedAt: now,
    );
    await widget.library.db.saveReadingEntry(entry);
    widget.library.refresh();
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _delete() async {
    final entry = widget.entry;
    if (entry == null) return;
    final ok = await confirmDialog(
      context,
      title: 'Retirer du carnet ?',
      message: '« ${entry.title} » sera retiré de tes lectures (sur tous tes '
          'profils). Le PDF, s’il est dans ta bibliothèque, n’est pas touché.',
      action: 'Retirer',
    );
    if (!ok) return;
    await widget.library.db.deleteReadingEntry(entry.uid);
    widget.library.refresh();
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _openBook() async {
    final bookId = widget.entry?.bookId;
    if (bookId == null) return;
    final book = await widget.library.db.book(bookId);
    if (!mounted) return;
    if (book == null) {
      showSnack(context, 'Ce PDF n’est plus dans ta bibliothèque');
      return;
    }
    await openBook(context, widget.library, book);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final editing = widget.entry != null;
    return Scaffold(
      appBar: AppBar(
        title: Text(editing ? 'Modifier' : 'Ajouter une lecture'),
        actions: [
          if (editing)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Retirer du carnet',
              onPressed: _delete,
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          TextField(
            controller: _title,
            autofocus: !editing,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              labelText: 'Titre *',
              border: const OutlineInputBorder(),
              errorText: _error,
            ),
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _author,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
              labelText: 'Auteur',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          SegmentedButton<ReadingStatus>(
            segments: [
              for (final s in ReadingStatus.values)
                ButtonSegment(value: s, label: Text(s.label)),
            ],
            selected: {_status},
            onSelectionChanged: (value) =>
                setState(() => _status = value.first),
          ),
          if (_status == ReadingStatus.read) ...[
            const SizedBox(height: 8),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.event_available_outlined),
              title: Text(_finishedAt == null
                  ? 'Fini aujourd’hui'
                  : 'Fini le ${formatDate(_finishedAt!)}'),
              trailing: const Icon(Icons.edit_calendar_outlined),
              onTap: _pickDate,
            ),
          ],
          const SizedBox(height: 8),
          Text('Note', style: theme.textTheme.titleSmall),
          _Stars(
            rating: _rating,
            onChanged: (value) => setState(() => _rating = value),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _review,
            minLines: 3,
            maxLines: 10,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Ton avis',
              alignLabelWithHint: true,
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 20),
          FilledButton(onPressed: _save, child: const Text('Enregistrer')),
          if (widget.bookHere) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _openBook,
              icon: const Icon(Icons.menu_book_outlined),
              label: const Text('Ouvrir le livre'),
            ),
          ],
        ],
      ),
    );
  }
}
