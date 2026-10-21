# Publier Voxa sur le Mac App Store

Version App Store : cible Xcode **VoxaAppStore** (identifiant `com.pierre.voxa.appstore`), 100 % native (WhisperKit + SpeakerKit), sandboxée, sans Python ni Sparkle. Gratuite, sans achat intégré.

La version DMG (GitHub, mises à jour Sparkle) continue d'exister à côté : même code, cible `TranscriptionApp`.

**Pas de serveur local ni d'intégration Claude Code (MCP) dans l'édition App Store.** Apple a refusé deux fois la soumission à cause de l'entitlement `com.apple.security.network.server` (guideline 2.4.5). Depuis la build 1.6.1 (3), la cible VoxaAppStore ne compile plus `LocalAPIServer`, `FolderAccess`, `ScriptDeployment` ni `voxa_mcp.py` (exclus dans `project.yml`, et `#if !APPSTORE` autour du démarrage et des réglages MCP). Ses entitlements : sandbox, `network.client` (téléchargement des modèles, Ollama local), micro, fichiers choisis par l'utilisateur ; plus de `network.server` ni de `files.bookmarks.app-scope`. L'intégration Claude Code n'existe que dans la version directe (DMG).

---

## Étape 1 — Compte Apple (toi, ~15 min)

1. **Xcode → Réglages → Comptes** : ajouter ton Apple ID développeur (équipe *Pierre Armanet – C3A57SQ939*). Xcode crée tout seul les certificats « Apple Distribution » et « Mac Installer Distribution » au premier envoi.
2. **[developer.apple.com → Identifiers](https://developer.apple.com/account/resources/identifiers/list)** → **+** → *App IDs* → *App* → plateforme **macOS** :
   - Description : `Voxa`
   - Bundle ID (explicite) : `com.pierre.voxa.appstore`
   - Aucune capacité particulière à cocher (la sandbox se déclare dans l'app).
3. **[App Store Connect → Apps](https://appstoreconnect.apple.com/apps)** → **+** → *Nouvelle app* :
   - Plateforme : **macOS**
   - Nom : `Voxa` (s'il est déjà pris : `Voxa: Meeting Transcription`)
   - Langue principale : **Anglais (U.S.)**
4. Une fois l'app créée : page de la version → menu des langues en haut à droite (« English (U.S.) ») → **Ajouter une langue → Français**. Chaque langue a sa propre fiche (nom, sous-titre, description, mots-clés, captures). Sans captures françaises, l'App Store affiche les anglaises.
   - Bundle ID : `com.pierre.voxa.appstore`
   - SKU : `voxa-macos`
   - Accès : complet

## Étape 2 — Politique de confidentialité en ligne (moi, avec ton accord)

`docs/privacy.html` est prête (FR + EN). Une fois poussée sur `main`, elle sera en ligne sur :
**https://armanetpierre.github.io/Local-Transcription-Mac/privacy.html**

## Étape 3 — Envoyer le build (toi, 1 commande)

```bash
./scripts/build-appstore.sh
```

Le script lance les tests, archive la cible VoxaAppStore en Release, la signe et l'envoie à App Store Connect. Il apparaît dans *TestFlight* après 10 à 30 min de traitement.
(Variante : `./scripts/build-appstore.sh --archive`, puis Xcode → Window → Organizer → *Distribute App* → *App Store Connect*.)

Recommandé : l'installer via **TestFlight** sur ton Mac et faire un dernier test avant de soumettre.

## Étape 4 — Fiche App Store (toi, copier-coller)

### Informations générales
- **Catégorie** : Productivité (secondaire : Économie et entreprise)
- **Prix** : Gratuit — disponibilité : tous les pays
- **URL d'assistance** : `https://github.com/ArmanetPierre/Local-Transcription-Mac/issues`
- **URL marketing** : `https://github.com/ArmanetPierre/Local-Transcription-Mac`
- **Politique de confidentialité** : `https://armanetpierre.github.io/Local-Transcription-Mac/privacy.html`
- **Copyright** : `2026 Pierre Armanet`
- **Classification par âge** : répondre « Non / Aucun » partout → 4+
- **Confidentialité de l'app** (questionnaire) : **« Données non collectées »**

### Texts — English (langue principale)

**Subtitle**: `Private meeting transcription`

**Promotional text**:
`Transcribe your meetings on your Mac, no cloud: who said what, and voices recognized from one meeting to the next. Free, no account, no data collected.`

**Keywords**:
`transcription,meeting,dictation,whisper,speech to text,diarization,speakers,subtitles,offline,notes`

**Description**:
```
Voxa transcribes your meetings, calls and recordings right on your Mac. Nothing is sent to the cloud: your conversations stay with you.

WHO SAID WHAT
• Automatic speaker identification
• Voice recognition: name someone once and Voxa recognizes them in your next meetings, in the room or on a video call
• Quick exchanges are split at every change of speaker, short replies included

ACCURATE TRANSCRIPTION
• Whisper large-v3-turbo, optimized for Apple silicon
• English, French and 90+ languages, including meetings that mix languages
• Audio and video files: m4a, mp3, wav, mov, mp4…

MEETING RECORDING
• Record your Mac's audio and your microphone from the menu bar
• Transcription starts automatically when you stop

AND THEN
• Export to text, Markdown, SRT subtitles or JSON
• Built-in player: click a sentence to hear it
• Meeting reports with Ollama (optional, local)

100% LOCAL, 100% FREE
No account, no subscription, no ads, no data collected. On first launch Voxa downloads the open-source models (about 650 MB) in the background, then works offline.

Voxa is open source: github.com/ArmanetPierre/Local-Transcription-Mac
```

### Textes — Français (localisation)

**Sous-titre** (30 car. max) :
`Transcription locale de réunions`

**Texte promotionnel** (170 car. max) :
`Transcrivez vos réunions sur votre Mac, sans cloud : qui a dit quoi et voix reconnues d'une réunion à l'autre. Gratuit, sans compte, aucune donnée collectée.`

**Mots-clés** (100 car. max, séparés par des virgules) :
`transcription,réunion,dictée,whisper,audio,compte rendu,diarisation,intervenants,sous-titres,local`

**Description** :
```
Voxa transcrit vos réunions, appels et enregistrements directement sur votre Mac. Rien n'est envoyé dans le cloud : vos conversations restent chez vous.

QUI A DIT QUOI
• Identification automatique des intervenants
• Reconnaissance des voix : nommez une personne une fois, Voxa la reconnaît dans les réunions suivantes, en salle comme en visio
• Les échanges rapides sont découpés à chaque changement d'intervenant, répliques courtes comprises

TRANSCRIPTION PRÉCISE
• Modèle Whisper large-v3-turbo, optimisé pour la puce Apple
• Français, anglais et plus de 90 langues, y compris les réunions qui mélangent les deux
• Fichiers audio et vidéo : m4a, mp3, wav, mov, mp4…

ENREGISTREMENT DE RÉUNIONS
• Enregistrez le son de votre Mac et votre micro depuis la barre des menus
• La transcription démarre automatiquement à la fin

ET ENSUITE
• Export en texte, Markdown, sous-titres SRT ou JSON
• Lecteur intégré : cliquez sur une phrase pour l'écouter
• Comptes rendus avec Ollama (facultatif, en local)

100 % LOCAL, 100 % GRATUIT
Pas de compte, pas d'abonnement, pas de publicité, aucune donnée collectée. Au premier lancement, Voxa télécharge en arrière-plan les modèles open source (environ 650 Mo), puis fonctionne sans internet.

Voxa est un projet open source : github.com/ArmanetPierre/Local-Transcription-Mac
```

### Captures d'écran (obligatoire : 1 à 10)
Captures en anglais (langue principale), app lancée en anglais ; captures françaises facultatives. Taille acceptée : **2880 × 1800** (ou 2560 × 1600, 1440 × 900, 1280 × 800). Suggestions, avec une réunion fictive (lancer la version Debug avec `scripts/dev/fake_bridge.py`, voir README) :
1. Une transcription ouverte, intervenants nommés en couleur
2. L'écran « Identifier les intervenants » (voix reconnues pré-remplies)
3. La barre des menus pendant un enregistrement
4. Le compte rendu de réunion
5. Réglages → Voix connues

### Notes pour l'équipe de relecture (App Review)
À coller dans *Informations de vérification de l'app → Notes* :

```
Voxa transcribes audio and video files locally (Whisper via WhisperKit, speaker diarization via SpeakerKit, all on-device with Core ML).

- No account is needed.
- On first launch, the app downloads open-source Core ML model weights (about 650 MB, a compressed Whisper large-v3 turbo) from Hugging Face (argmaxinc/whisperkit-coreml and argmaxinc/speakerkit-coreml). These are data files only, no executable code is downloaded.
- The app is usable immediately: the download and the one-time Core ML optimization for the Mac run in the background, with a progress card showing the downloaded size and percentage, then the optimization step with elapsed time. On our M3 Pro test Mac, the full preparation takes about 4 minutes (download under 1 minute, optimization about 3 minutes). If the network drops, the app shows a clear message with a Retry button and resumes the download where it stopped.
- To test: launch the app, then right away drag any audio file (m4a/mp3/wav) into the window (or click +). The file waits in the queue ("Waiting for the transcription models") and is transcribed automatically as soon as the models are ready. A transcript with speakers appears after processing.
- Microphone and screen recording permissions are requested only when the user starts a meeting recording from the menu bar (to capture the other participants' audio and the user's voice).
- The app does not run any server and does not accept incoming network connections (no com.apple.security.network.server entitlement). It only makes outgoing connections to download the models and, optionally, to a local Ollama.
- Optional: meeting reports use Ollama if the user already runs it on their Mac (localhost). The app works fully without it.
- No user data is collected or transmitted.
```

### Build 4 (1.6.1) — réponse au refus « Guideline 4 - Design »
Refus du build 3 : sur un MacBook Air M3, la préparation des modèles a pris plus de 5 minutes, l'app bloquée sur un écran d'accueil avec un simple sablier (et un message technique en français dans l'app anglaise).

Mesuré sur M3 Pro, dossier de modèles vierge :

| | Téléchargement | Modèles d'intervenants | Optimisation Core ML | Total |
|---|---|---|---|---|
| Build 3 (large-v3 turbo, 1,64 Go) | 50 s | 26 s | 143 s | 219 s |
| Build 4 (turbo compressé, 646 Mo) | 33 s | 26 s | 188 s | 247 s (app réelle : 251 à 263 s) |

L'optimisation pour la puce (hors ligne) domine ; le modèle compressé télécharge 1 Go de moins (gain net dès que la connexion est sous ~20 Mo/s, cas le plus courant) mais s'optimise un peu plus lentement. Charger sans passe de « prewarm » ne fait rien gagner (182 s). Banc 64 min : WER 18,9 % (contre 18,6 %), erreur d'intervenant 3,6 % (3,5 %), transcription 12 % plus rapide.

Changements du build 4 :
- Plus d'écran bloquant : la fenêtre principale s'ouvre tout de suite (liste, import, enregistrement). L'accueil affiche une carte de progression ; une transcription importée attend dans la file (« En attente des modèles ») et démarre seule quand ils sont prêts.
- Progression réelle : Mo téléchargés / total et pourcentage, puis « Optimisation des modèles pour ce Mac » (étape 2 sur 2) avec le temps écoulé.
- Erreur réseau : message clair + bouton Réessayer, reprise automatique au retour de la connexion ; le téléchargement reprend où il s'était arrêté.
- Tous les textes en anglais dans le code, traduits en français.
- Modèle `large-v3-v20240930_turbo_632MB` (édition App Store seulement ; la version directe garde le modèle complet). Un ancien dossier de modèle est supprimé une fois le nouveau prêt.

Message proposé pour le Resolution Center :

```
Thank you for the review. In this build (1.6.1, build 4):
- Voxa no longer blocks on first launch. The main window is usable immediately; the model download and the one-time Core ML optimization run in the background. Files imported or recorded meanwhile wait in the queue and are transcribed automatically when the models are ready.
- The progress is now explicit: downloaded size and percentage, then the "Optimizing for this Mac" step with elapsed time. Network errors show a Retry button and the download resumes where it stopped.
- The download is 2.5 times smaller (about 650 MB instead of 1.6 GB, a compressed model with equivalent accuracy). On our M3 Pro test Mac the complete preparation takes about 4 minutes, during which the app can be used.
```

## Étape 5 — Soumettre (toi)

App Store Connect → ta version 1.6.0 → sélectionner le **build** envoyé → *Ajouter pour vérification* → *Soumettre*. Délai habituel : 1 à 3 jours.

### Risques de refus et réponses prévues
| Règle | Risque | Ce qui est prévu |
|---|---|---|
| 2.5.2 (code téléchargé) | Le téléchargement des modèles | Ce sont des poids de modèles (données), expliqué dans les notes |
| 4.2.3 (dépendance à une autre app) | Ollama | Facultatif, l'app fonctionne entièrement sans |
| 5.1.1 (confidentialité) | Micro, écran | Demandés seulement à l'usage, rien collecté |
| 2.4.5 (entitlements) | `network.server` (refusé deux fois) | Retiré : plus de serveur local dans l'édition App Store (build 3) |
| 2.1 (app complète) | Premier lancement long | Écran d'accueil qui explique le téléchargement et la préparation |
| 4 (Design) | Préparation des modèles trop lente (refus du build 3 : « more than 5 minutes ») | Build 4 : app utilisable tout de suite, préparation en arrière-plan avec progression réelle, modèle 2,5 fois plus léger (voir ci-dessous) |

## Mises à jour ensuite

1. Dans `TranscriptionApp/project.yml`, cible `VoxaAppStore` : augmenter `CURRENT_PROJECT_VERSION` (à chaque envoi) et `MARKETING_VERSION` (nouvelle version).
2. `./scripts/build-appstore.sh`
3. App Store Connect : nouvelle version, notes de version, choisir le build, soumettre.

Après une mise à jour, Core ML reprépare les modèles en arrière-plan au premier lancement (quelques minutes, sans nouveau téléchargement).

## Pour se faire connaître
- Lien App Store dans le README et sur la page GitHub
- Billet « Transcrire ses réunions en local sur Mac » (LinkedIn, Product Hunt, Reddit r/macapps)
- L'intégration Claude Code (MCP) est un bon angle pour la version directe (DMG) : peu d'apps de transcription le proposent. Elle n'existe pas dans l'édition App Store.
