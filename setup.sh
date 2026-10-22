#!/usr/bin/env bash
# Prépare le projet Flutter autour du code de lib/.
# Sans risque à relancer : rien d'existant n'est écrasé.
set -euo pipefail
cd "$(dirname "$0")"

echo "== Version de Flutter (il faut 3.47 ou plus pour pdfrx 2.9) =="
flutter --version

echo "== Création du dossier android/ (les fichiers existants ne sont pas écrasés) =="
flutter create --platforms=android --org io.github.zeidibraheem --project-name my_pdfs .
rm -f test/widget_test.dart # test d'exemple généré, il ne correspond pas à l'appli

echo "== Ajout des paquets (dernières versions compatibles) =="
flutter pub add pdfrx material_ui file_picker sqflite path_provider path crypto http url_launcher
# Nettoyage de l'option retirée (import depuis Téléchargements) : paquet qui
# exigeait Android SDK 37, permission et code Android associés.
if grep -q 'permission_handler' pubspec.yaml; then
  flutter pub remove permission_handler
fi
flutter pub add dev:flutter_lints

MANIFEST=android/app/src/main/AndroidManifest.xml

# Nom affiché sous l'icône de l'appli
sed -i 's/android:label="my_pdfs"/android:label="My PDFs"/' "$MANIFEST"

# Accès réseau (serveur personnel via Tailscale) :
# - permission Internet, absente par défaut des versions « release » ;
# - HTTP simple autorisé : le trafic passe déjà dans le tunnel chiffré
#   de Tailscale, et le serveur n'est joignable que par lui.
if ! grep -q 'android.permission.INTERNET' "$MANIFEST"; then
  sed -i 's|<application|<uses-permission android:name="android.permission.INTERNET"/>\n    <application|' "$MANIFEST"
fi
sed -i '/MANAGE_EXTERNAL_STORAGE/d' "$MANIFEST"
MAIN_ACTIVITY="$(find android/app/src/main -name 'MainActivity.kt' | head -n1)"
if [ -n "$MAIN_ACTIVITY" ] && grep -q 'my_pdfs/stockage' "$MAIN_ACTIVITY"; then
  PACKAGE_LINE="$(grep -m1 '^package ' "$MAIN_ACTIVITY")"
  printf '%s\n\nimport io.flutter.embedding.android.FlutterActivity\n\nclass MainActivity : FlutterActivity()\n' \
    "$PACKAGE_LINE" > "$MAIN_ACTIVITY"
fi

if ! grep -q 'usesCleartextTraffic' "$MANIFEST"; then
  sed -i 's|<application|<application\n        android:usesCleartextTraffic="true"|' "$MANIFEST"
fi

echo "== Vérification du code =="
flutter analyze || echo ">> Problèmes trouvés : envoie la sortie ci-dessus à Claude."
if command -v clang >/dev/null; then
  flutter test || echo ">> Un test a échoué : envoie la sortie ci-dessus à Claude."
else
  echo ">> Tests sautés : installe clang pour les lancer (sudo pacman -S --needed clang lld llvm)"
fi

echo
echo "Prêt. Branche le Pixel en USB puis lance : flutter run --release"
