# Publier Voxa sur le Mac App Store

Version App Store : cible Xcode **VoxaAppStore** (identifiant `com.pierre.voxa.appstore`), 100 % native (WhisperKit + SpeakerKit), sandboxée, sans Python ni Sparkle. Gratuite, sans achat intégré.

La version DMG (GitHub, mises à jour Sparkle) continue d'exister à côté : même code, cible `TranscriptionApp`.

---

## Étape 1 — Compte Apple (toi, ~15 min)

1. **Xcode → Réglages → Comptes** : ajouter ton Apple ID développeur (équipe *Pierre Armanet – C3A57SQ939*). Xcode crée tout seul les certificats « Apple Distribution » et « Mac Installer Distribution » au premier envoi.
2. **[developer.apple.com → Identifiers](https://developer.apple.com/account/resources/identifiers/list)** → **+** → *App IDs* → *App* → plateforme **macOS** :
   - Description : `Voxa`
   - Bundle ID (explicite) : `com.pierre.voxa.appstore`
   - Aucune capacité particulière à cocher (la sandbox se déclare dans l'app).
3. **[App Store Connect → Apps](https://appstoreconnect.apple.com/apps)** → **+** → *Nouvelle app* :
   - Plateforme : **macOS**
   - Nom : `Voxa` (s'il est déjà pris : `Voxa – Transcription de réunions` ou `Voxa: Meeting Transcription`)
   - Langue principale : Français (ou Anglais si tu vises l'international)
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

### Textes — Français

**Sous-titre** (30 car. max) :
`Transcription locale de réunions`

**Texte promotionnel** (170 car. max) :
`Transcrivez vos réunions sur votre Mac, sans cloud : qui a dit quoi, voix reconnues d'une réunion à l'autre, et intégration Claude Code. Gratuit et sans compte.`

**Mots-clés** (100 car. max, séparés par des virgules) :
`transcription,réunion,dictée,whisper,audio,compte rendu,diarisation,intervenants,sous-titres,local`

**Description** :
```
Voxa transcrit vos réunions, appels et enregistrements directement sur votre Mac. Rien n'est envoyé dans le cloud : vos conversations restent chez vous.

QUI A DIT QUOI
• Identification automatique des intervenants
• Reconnaissance des voix : nommez une personne une fois, Voxa la reconnaît dans les réunions suivantes, en salle comme en visio
• Attribution mot par mot : les « OK », « oui » et interruptions vont à la bonne personne

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
• Intégration Claude Code (MCP) : demandez à Claude de transcrire une réunion et d'en faire le compte rendu

100 % LOCAL, 100 % GRATUIT
Pas de compte, pas d'abonnement, pas de publicité, aucune donnée collectée. Au premier lancement, Voxa télécharge les modèles open source (environ 1,6 Go), puis fonctionne sans internet.

Voxa est un projet open source : github.com/ArmanetPierre/Local-Transcription-Mac
```

### Texts — English

**Subtitle**: `Private meeting transcription`

**Promotional text**:
`Transcribe your meetings on your Mac, no cloud: who said what, voices recognized from one meeting to the next, and Claude Code integration. Free, no account.`

**Keywords**:
`transcription,meeting,dictation,whisper,speech to text,diarization,speakers,subtitles,offline,notes`

**Description**:
```
Voxa transcribes your meetings, calls and recordings right on your Mac. Nothing is sent to the cloud: your conversations stay with you.

WHO SAID WHAT
• Automatic speaker identification
• Voice recognition: name someone once and Voxa recognizes them in your next meetings, in the room or on a video call
• Word-level attribution: "OK", "yes" and interruptions go to the right person

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
• Claude Code integration (MCP): ask Claude to transcribe a meeting and write the report

100% LOCAL, 100% FREE
No account, no subscription, no ads, no data collected. On first launch Voxa downloads the open-source models (about 1.6 GB), then works offline.

Voxa is open source: github.com/ArmanetPierre/Local-Transcription-Mac
```

### Captures d'écran (obligatoire : 1 à 10)
Taille acceptée : **2880 × 1800** (ou 2560 × 1600, 1440 × 900, 1280 × 800). Suggestions, avec une réunion fictive (lancer la version Debug avec `scripts/dev/fake_bridge.py`, voir README) :
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
- On first launch, the app downloads open-source Core ML model weights (about 1.6 GB) from Hugging Face (argmaxinc/whisperkit-coreml and argmaxinc/speakerkit-coreml). These are data files only, no executable code is downloaded. The download and Core ML optimization take a few minutes on first launch.
- To test: click "Download and prepare", wait for completion, then drag any audio file (m4a/mp3/wav) into the window. A transcript with speakers appears after processing.
- Microphone and screen recording permissions are requested only when the user starts a meeting recording from the menu bar (to capture the other participants' audio and the user's voice).
- Optional: the app runs a local HTTP server bound to 127.0.0.1 only, protected by a random token stored in the app container, used by the user's own Claude Code installation (Model Context Protocol). It is never reachable from the network.
- Optional: meeting reports use Ollama if the user already runs it on their Mac (localhost). The app works fully without it.
- No user data is collected or transmitted.
```

## Étape 5 — Soumettre (toi)

App Store Connect → ta version 1.6.0 → sélectionner le **build** envoyé → *Ajouter pour vérification* → *Soumettre*. Délai habituel : 1 à 3 jours.

### Risques de refus et réponses prévues
| Règle | Risque | Ce qui est prévu |
|---|---|---|
| 2.5.2 (code téléchargé) | Le téléchargement des modèles | Ce sont des poids de modèles (données), expliqué dans les notes |
| 4.2.3 (dépendance à une autre app) | Ollama, Claude Code | Facultatifs, l'app fonctionne entièrement sans |
| 5.1.1 (confidentialité) | Micro, écran, serveur local | Demandés seulement à l'usage, serveur local sur 127.0.0.1, rien collecté |
| 2.1 (app complète) | Premier lancement long | Écran d'accueil qui explique le téléchargement et la préparation |

## Mises à jour ensuite

1. Dans `TranscriptionApp/project.yml`, cible `VoxaAppStore` : augmenter `CURRENT_PROJECT_VERSION` (à chaque envoi) et `MARKETING_VERSION` (nouvelle version).
2. `./scripts/build-appstore.sh`
3. App Store Connect : nouvelle version, notes de version, choisir le build, soumettre.

Après une mise à jour, Core ML reprépare les modèles en arrière-plan au premier lancement (quelques minutes, sans nouveau téléchargement).

## Pour se faire connaître
- Lien App Store dans le README et sur la page GitHub
- Billet « Transcrire ses réunions en local sur Mac » (LinkedIn, Product Hunt, Reddit r/macapps)
- L'intégration Claude Code (MCP) est un bon angle : peu d'apps de transcription le proposent
