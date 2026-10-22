import 'package:material_ui/material_ui.dart';

import '../data/annotation.dart';

/// Fenêtre d'écriture d'une note. Renvoie le texte, ou `null` si annulé.
Future<String?> editNoteDialog(
  BuildContext context, {
  required String title,
  String? quote,
  String initial = '',
}) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (quote != null) ...[
              QuoteBox(text: quote, maxLines: 6),
              const SizedBox(height: 12),
            ],
            TextField(
              controller: controller,
              autofocus: true,
              minLines: 3,
              maxLines: 8,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                hintText: 'Ta note…',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, controller.text),
          child: const Text('Enregistrer'),
        ),
      ],
    ),
  );
}

/// Citation surlignée, avec un trait de la couleur du surlignage.
class QuoteBox extends StatelessWidget {
  const QuoteBox({super.key, required this.text, this.color, this.maxLines = 4});

  final String text;
  final int? color;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final argb = color;
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 6, 8, 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        border: Border(
          left: BorderSide(
            color: argb != null ? Color(argb) : theme.colorScheme.outline,
            width: 3,
          ),
        ),
      ),
      child: Text(
        text,
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodyMedium?.copyWith(fontStyle: FontStyle.italic),
      ),
    );
  }
}

/// Barre affichée en bas quand du texte est sélectionné :
/// copier, surligner (4 couleurs), surligner + note.
class SelectionBar extends StatelessWidget {
  const SelectionBar({
    super.key,
    required this.onCopy,
    required this.onHighlight,
    required this.onNote,
  });

  final VoidCallback onCopy;
  final ValueChanged<int> onHighlight;
  final VoidCallback onNote;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SafeArea(
      minimum: const EdgeInsets.all(12),
      child: Material(
        elevation: 6,
        color: colors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(28),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: const Icon(Icons.copy),
                tooltip: 'Copier',
                onPressed: onCopy,
              ),
              const _BarDivider(),
              for (final argb in highlightColors)
                _ColorDot(argb: argb, onTap: () => onHighlight(argb)),
              const _BarDivider(),
              IconButton(
                icon: const Icon(Icons.edit_note),
                tooltip: 'Surligner et ajouter une note',
                onPressed: onNote,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BarDivider extends StatelessWidget {
  const _BarDivider();

  @override
  Widget build(BuildContext context) =>
      const SizedBox(height: 24, child: VerticalDivider(width: 12));
}

class _ColorDot extends StatelessWidget {
  const _ColorDot({required this.argb, required this.onTap});

  final int argb;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Surligner',
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(7),
          child: Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: Color(argb),
              shape: BoxShape.circle,
              border: Border.all(color: Colors.black26),
            ),
          ),
        ),
      ),
    );
  }
}

/// Liste des annotations d'un livre (dans un panneau qu'on fait glisser).
class NotesPanel extends StatelessWidget {
  const NotesPanel({
    super.key,
    required this.annotations,
    required this.scrollController,
    required this.onCopyAll,
    required this.onOpen,
    required this.onEdit,
    required this.onDelete,
  });

  final List<Annotation> annotations;
  final ScrollController scrollController;
  final VoidCallback onCopyAll;
  final ValueChanged<Annotation> onOpen;
  final ValueChanged<Annotation> onEdit;
  final ValueChanged<Annotation> onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 8, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Notes et surlignages (${annotations.length})',
                  style: theme.textTheme.titleMedium,
                ),
              ),
              if (annotations.isNotEmpty)
                TextButton.icon(
                  onPressed: onCopyAll,
                  icon: const Icon(Icons.content_copy, size: 18),
                  label: const Text('Tout copier'),
                ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: annotations.isEmpty
              ? ListView(
                  controller: scrollController,
                  padding: const EdgeInsets.all(24),
                  children: const [
                    Text(
                      "Rien pour l'instant.\n\n"
                      'Pour surligner : appui long sur un mot, ajuste la '
                      'sélection, puis touche une couleur en bas.\n\n'
                      'Pour une note sans surlignage : menu ⋮ > '
                      'Note sur cette page.',
                    ),
                  ],
                )
              : ListView.separated(
                  controller: scrollController,
                  padding: const EdgeInsets.only(bottom: 24),
                  itemCount: annotations.length,
                  separatorBuilder: (context, index) =>
                      const Divider(height: 1, indent: 16, endIndent: 16),
                  itemBuilder: (context, index) => _AnnotationTile(
                    annotation: annotations[index],
                    onOpen: onOpen,
                    onEdit: onEdit,
                    onDelete: onDelete,
                  ),
                ),
        ),
      ],
    );
  }
}

class _AnnotationTile extends StatelessWidget {
  const _AnnotationTile({
    required this.annotation,
    required this.onOpen,
    required this.onEdit,
    required this.onDelete,
  });

  final Annotation annotation;
  final ValueChanged<Annotation> onOpen;
  final ValueChanged<Annotation> onEdit;
  final ValueChanged<Annotation> onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final a = annotation;
    final quote = a.quote;
    return InkWell(
      onTap: () => onOpen(a),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 4, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    quote == null ? 'Page ${a.page} · note' : 'Page ${a.page}',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 6),
                  if (quote != null) QuoteBox(text: quote, color: a.color),
                  if (a.hasNote)
                    Padding(
                      padding: EdgeInsets.only(top: quote != null ? 8 : 0),
                      child: Text(a.note.trim()),
                    ),
                ],
              ),
            ),
            PopupMenuButton<String>(
              tooltip: 'Options',
              onSelected: (value) {
                if (value == 'edit') {
                  onEdit(a);
                } else {
                  onDelete(a);
                }
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: 'edit',
                  child: Text(a.hasNote ? 'Modifier la note' : 'Ajouter une note'),
                ),
                const PopupMenuItem(value: 'delete', child: Text('Supprimer')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
