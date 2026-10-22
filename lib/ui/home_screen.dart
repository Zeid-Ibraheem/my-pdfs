import 'package:material_ui/material_ui.dart';

import '../data/library.dart';
import 'discover_screen.dart';
import 'library_screen.dart';
import 'search_screen.dart';
import 'settings_screen.dart';

/// Écran principal : 4 onglets en bas (Bibliothèque, Recherche,
/// Découvrir, Réglages). Chaque onglet garde son état quand on change.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.library});

  final Library library;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Retour depuis un autre onglet : on revient à la bibliothèque.
      canPop: _tab == 0,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) setState(() => _tab = 0);
      },
      child: Scaffold(
        body: IndexedStack(
          index: _tab,
          children: [
            LibraryScreen(library: widget.library),
            SearchScreen(library: widget.library),
            DiscoverScreen(library: widget.library),
            SettingsScreen(library: widget.library),
          ],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _tab,
          onDestinationSelected: (index) => setState(() => _tab = index),
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.menu_book_outlined),
              selectedIcon: Icon(Icons.menu_book),
              label: 'Bibliothèque',
            ),
            NavigationDestination(
              icon: Icon(Icons.manage_search),
              label: 'Recherche',
            ),
            NavigationDestination(
              icon: Icon(Icons.travel_explore),
              label: 'Découvrir',
            ),
            NavigationDestination(
              icon: Icon(Icons.settings_outlined),
              selectedIcon: Icon(Icons.settings),
              label: 'Réglages',
            ),
          ],
        ),
      ),
    );
  }
}
