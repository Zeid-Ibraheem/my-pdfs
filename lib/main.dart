import 'package:material_ui/material_ui.dart';

import 'data/library.dart';
import 'ui/home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // En version release, une erreur d'affichage donne un simple écran gris.
  // On affiche plutôt le message, pour pouvoir le signaler et le corriger.
  ErrorWidget.builder = (details) => Material(
        color: const Color(0xFFFFF4F4),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Erreur d’affichage (fais une capture d’écran pour la '
              'signaler) :\n\n${details.exception}\n\n${details.stack ?? ''}',
              textDirection: TextDirection.ltr,
              style: const TextStyle(color: Color(0xFF8B0000), fontSize: 12),
            ),
          ),
        ),
      );
  final library = await Library.open();
  runApp(PdfApp(library: library));
}

class PdfApp extends StatelessWidget {
  const PdfApp({super.key, required this.library});

  final Library library;

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF3D5A80);
    return MaterialApp(
      title: 'My PDFs',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: ThemeData(colorSchemeSeed: seed, brightness: Brightness.light),
      darkTheme: ThemeData(colorSchemeSeed: seed, brightness: Brightness.dark),
      home: HomeScreen(library: library),
    );
  }
}
