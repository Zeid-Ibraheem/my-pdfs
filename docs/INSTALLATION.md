# Installer My PDFs

[← Retour au README](../README.md)

## 1. Le serveur (sur la machine allumée 24 h/24, avec Tailscale)

```bash
git clone https://github.com/Zeid-Ibraheem/my-pdfs.git
cd my-pdfs/server
./install.sh
```

Le script affiche à la fin l'**adresse** et le **jeton** à saisir dans l'appli. Détails : [server/README.md](server/README.md).

## 2. L'appli (sur le PC, téléphone branché en USB)

Prérequis : Flutter **3.47 ou plus** (`flutter upgrade`) et le SDK Android.

```bash
cd my-pdfs
./setup.sh            # crée android/, ajoute les paquets, vérifie le code (relançable)
flutter run --release # installe et lance sur le téléphone
```

Puis dans l'appli : onglet **Réglages** > adresse + jeton > « Tester et enregistrer ». Tailscale doit être actif sur le téléphone, dans le même profil que l'appli.

## Dépannage

| Problème | Solution |
| --- | --- |
| `pdfrx requires Flutter >= 3.47` | `flutter upgrade` puis `./setup.sh` |
| « Serveur injoignable » | Tailscale activé sur le téléphone ? Serveur allumé ? `systemctl status my-pdfs` sur le serveur |
| « Jeton refusé » | Recopie le jeton : `sed -n 's/^MYPDFS_TOKEN=//p' ~/my-pdfs-data/server.env` |
| Erreur de compilation native (NDK) | Android Studio > SDK Manager > SDK Tools > NDK |
| `flutter test` : « No compiler configured » | pdfrx compile PDFium pour le PC pendant les tests : `sudo pacman -S --needed clang lld llvm` |
| `minSdkVersion` trop bas | `android/app/build.gradle.kts` : `minSdk = 24` |
