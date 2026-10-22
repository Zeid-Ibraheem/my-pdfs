import 'package:material_ui/material_ui.dart';

import 'data/library.dart';
import 'ui/library_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final library = await Library.open();
  runApp(BibliApp(library: library));
}

class BibliApp extends StatelessWidget {
  const BibliApp({super.key, required this.library});

  final Library library;

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF3D5A80);
    return MaterialApp(
      title: 'Bibli',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: ThemeData(colorSchemeSeed: seed, brightness: Brightness.light),
      darkTheme: ThemeData(colorSchemeSeed: seed, brightness: Brightness.dark),
      home: LibraryScreen(library: library),
    );
  }
}
