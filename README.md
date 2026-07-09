# TwitchSevenTV — Guide Complet

> Intègre les emotes 7TV dans l'app Twitch iOS (IPA modifiée sideloadée)  
> **Niveau requis: zéro connaissance technique**

---

## 🧠 Comment ça marche (en simple)

```
TON IPHONE avec Twitch modifié
         │
         ▼
  Le tweak intercepte les
  messages du chat (IRC)
         │
         ▼
  Détecte les noms d'emotes 7TV
  ex: "KEKW" dans le chat
         │
         ▼
  Ajoute l'info d'emote au message
  (comme si c'était une emote Twitch)
         │
         ▼
  Twitch charge l'image → redirigée
  vers le CDN de 7TV automatiquement
         │
         ▼
  L'emote 7TV apparaît dans le chat ! ✅
```

**Pas de conflit avec l'adblocker** car on ne touche pas au lecteur vidéo.

---

## 📁 Fichiers du projet

```
TwitchSevenTV/
│
├── TweakSevenTV.xm              ← Le tweak principal (hooks)
├── SevenTVManager.h/.m          ← Gestion des emotes 7TV
├── SevenTVURLProtocol.h/.m      ← Redirection des images
├── SevenTVSettingsController.h/.m ← Écran de paramètres
├── Makefile                     ← Config de compilation
├── control                      ← Infos du paquet
└── .github/workflows/build.yml  ← Automatisation GitHub
```

---

## 🚀 GUIDE D'INSTALLATION ÉTAPE PAR ÉTAPE

### ÉTAPE 1 — Créer un compte GitHub (gratuit)

1. Va sur **https://github.com**
2. Clique sur "Sign up" (en haut à droite)
3. Entre ton email, un mot de passe, un pseudo
4. Vérifie ton email → clique le lien de confirmation
5. ✅ Tu as un compte GitHub

---

### ÉTAPE 2 — Créer le repository (dossier en ligne)

1. Sur GitHub, clique sur le **"+"** en haut à droite
2. Sélectionne **"New repository"**
3. Remplis:
   - **Repository name**: `TwitchSevenTV`
   - **Visibility**: `Private` ← important! (pour garder ton IPA privée)
4. Clique **"Create repository"**
5. ✅ Ton repo est créé

---

### ÉTAPE 3 — Uploader les fichiers du projet

1. Dans ton repo, clique **"uploading an existing file"** (lien au milieu)
2. Glisse-dépose **TOUS** les fichiers de ce projet:
   - `TweakSevenTV.xm`
   - `SevenTVManager.h`, `SevenTVManager.m`
   - `SevenTVURLProtocol.h`, `SevenTVURLProtocol.m`
   - `SevenTVSettingsController.h`, `SevenTVSettingsController.m`
   - `Makefile`
   - `control`
3. Pour le dossier `.github/workflows/`, tu dois créer les dossiers manuellement:
   - Clique "Create new file"
   - Dans le nom, tape: `.github/workflows/build.yml`
   - Copie-colle le contenu du fichier `build.yml`
4. Clique **"Commit changes"** → **"Commit directly to main"**
5. ✅ Tous les fichiers sont en ligne

---

### ÉTAPE 4 — Préparer ton IPA Twitch

Tu as besoin d'un lien direct vers ton IPA Twitch modifiée.

**Option A — WeTransfer (recommandé, gratuit):**
1. Va sur **https://wetransfer.com**
2. Clique "Transfer" → "Get a link"
3. Upload ton IPA Twitch modifiée
4. Copie le lien généré

**Option B — Google Drive:**
1. Upload l'IPA sur Google Drive
2. Clic droit → "Partager" → "Copier le lien"
3. ⚠️ Change les paramètres pour "Tout le monde avec le lien peut voir"

**⚠️ Note WeTransfer**: Le lien direct ne marche que 7 jours.

---

### ÉTAPE 5 — Configurer le secret GitHub (sécurité)

Pour que GitHub puisse télécharger ton IPA sans que l'URL soit visible publiquement:

1. Dans ton repo GitHub, clique **Settings** (onglet en haut)
2. Dans le menu gauche: **"Secrets and variables"** → **"Actions"**
3. Clique **"New repository secret"**
4. Remplis:
   - **Name**: `TWITCH_IPA_URL`
   - **Secret**: colle l'URL de ton IPA (WeTransfer ou Drive)
5. Clique **"Add secret"**
6. ✅ L'URL est stockée en sécurité

---

### ÉTAPE 6 — Lancer la compilation

1. Dans ton repo, clique l'onglet **"Actions"**
2. Si GitHub te demande d'activer les Actions → clique **"I understand, enable"**
3. Dans le menu gauche, clique **"Build TwitchSevenTV + Inject into IPA"**
4. Clique le bouton **"Run workflow"** (à droite)
5. Dans le menu déroulant: laisse l'URL vide (le secret est déjà configuré)
6. Clique **"Run workflow"** (bouton vert)
7. ✅ La compilation démarre!

---

### ÉTAPE 7 — Attendre et télécharger

1. Tu verras un cercle jaune/orange → en cours (~5 minutes)
2. ✅ Cercle vert = succès!
3. Clique sur le workflow terminé
4. En bas de la page, section **"Artifacts"**:
   - Clique **"TwitchSevenTV-Patched-IPA"** pour télécharger
5. Sur ton PC, tu obtiens un fichier `.zip` → extrait-le
6. À l'intérieur: `TwitchSevenTV_patched.ipa` ← c'est ta nouvelle IPA!

---

### ÉTAPE 8 — Installer sur ton iPhone

1. Transfère l'IPA sur ton iPhone (AirDrop, iCloud Drive, etc.)
2. Ouvre **SideStore** sur ton iPhone
3. Supprime l'ancienne version de Twitch dans SideStore
4. Importe la nouvelle IPA `TwitchSevenTV_patched.ipa`
5. Installe-la
6. ✅ Lance Twitch → cherche le bouton **"7TV"** violet flottant!

---

## 🎮 UTILISATION

### Le bouton flottant "7TV"

Un petit bouton violet **"7TV"** apparaît dans l'app Twitch:
- **Tap** → ouvre les paramètres 7TV
- **Glisse** → déplace le bouton où tu veux

### Paramètres disponibles

| Option | Description |
|--------|-------------|
| ✅ Activer 7TV | Active/désactive tout le tweak |
| ✨ Emotes animées | Afficher les GIFs (désactiver = économise batterie) |
| 🐞 Logs de débogage | Pour déboguer (laisse désactivé normalement) |
| 🔄 Recharger les emotes | Force le rechargement si les emotes n'apparaissent pas |

---

## ❓ FAQ & PROBLÈMES COURANTS

### "Les emotes globales s'affichent mais pas celles du channel"

C'est normal les premières secondes. Le tweak a besoin que Twitch charge
le channel pour obtenir l'ID du broadcaster. Attends 5-10 secondes après
avoir rejoint le stream. Si ça ne marche toujours pas, tape "Recharger les emotes".

### "Certaines emotes ne s'affichent pas"

Le streamer n'a peut-être pas ces emotes activées sur son channel 7TV,
ou bien ce sont des emotes d'un service différent (BTTV, FFZ).
Ce tweak supporte uniquement 7TV pour l'instant.

### "L'app Twitch crash au démarrage"

1. Vérifie que l'adblocker de ton IPA était bien fonctionnel AVANT l'injection
2. Essaie de télécharger uniquement le `.dylib` (artifact) et injecte-le
   manuellement avec **InjectionIPA** (app iOS, pas besoin d'ordi)
3. Vérifie le log d'erreur dans l'onglet Actions sur GitHub

### "Le bouton 7TV n'apparaît pas"

C'est parfois un problème de timing. Force-quitte Twitch et relance.
Si ça persiste, active les logs et vérifie dans Console.app (sur Mac)
ou via l'outil "libimobiledevice" sur Windows.

### "Erreur dans GitHub Actions: insert_dylib failed"

L'IPA est peut-être chiffrée (pas décryptée). Une IPA téléchargée depuis
l'App Store officiel EST chiffrée et ne peut pas être patchée directement.
Ton IPA modifiée doit déjà être décryptée (ce qui est généralement le cas
si elle contient déjà un adblocker fonctionnel).

---

## 🔧 MISE À JOUR DU TWEAK

Pour mettre à jour si une nouvelle version est disponible:
1. Modifie les fichiers `.m`/`.xm` dans ton repo GitHub
2. Retourne à l'onglet **Actions** → relance le workflow
3. Télécharge et réinstalle la nouvelle IPA

---

## ⚠️ AVERTISSEMENT LÉGAL

Ce projet est fourni à des fins éducatives. L'utilisation de modifications
non officielles peut violer les conditions d'utilisation de Twitch.
Utilise à tes propres risques.

---

*TwitchSevenTV v1.0.0 — API 7TV v3*
