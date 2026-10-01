# Voxa

Native macOS application (SwiftUI) for audio transcription with speaker identification (diarization), meeting recording, and automatic meeting report generation.

![macOS](https://img.shields.io/badge/macOS-14.0%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5.9-orange)
![Python](https://img.shields.io/badge/Python-3.11-green)
![License](https://img.shields.io/badge/license-MIT-lightgrey)

## Features

- **Audio transcription** via [mlx-whisper](https://github.com/ml-explore/mlx-examples/tree/main/whisper) (Apple Silicon GPU optimized)
- **Diarization** (speaker identification) via [pyannote.audio](https://github.com/pyannote/pyannote-audio) 3.1
- **Meeting recording** with system audio + microphone capture (ScreenCaptureKit)
- **Speaker summaries** and **meeting reports** via [Ollama](https://ollama.com) (local LLM)
- **Claude Code integration (MCP)** — transcribe meetings, read transcripts and write meeting reports from Claude Code
- **Automatic speaker recognition** — known voices are named automatically in new transcriptions
- **Export** to TXT, JSON, SRT, Markdown
- **Menu bar** with real-time progress tracking
- **Built-in audio player** with segment navigation
- **Multilingual** — adapts to your Mac's language (English / French)
- Drag & drop audio or video files (m4a, wav, mp3, mp4, mov...) — only the audio track of videos is kept
- Automatic updates via [Sparkle](https://sparkle-project.org)

## Prerequisites

- macOS 14.0+ (Sonoma) on Apple Silicon (M1/M2/M3/M4)
- Python 3.11+ (`brew install python@3.12` or [python.org](https://www.python.org/downloads/))
- A [HuggingFace](https://huggingface.co/settings/tokens) token (for pyannote diarization models)

## Installation

### Quick Install (recommended)

1. Download `Voxa.dmg` from [Releases](https://github.com/ArmanetPierre/Local-Transcription-Mac/releases)
2. Open the DMG and drag **Voxa** to **Applications**
3. Launch Voxa — the setup wizard will guide you through the rest
4. Enter your HuggingFace token when prompted

Voxa is signed and notarized by Apple. Later versions are installed with **Voxa → Check for Updates…**.

> **Note:** Versions up to 1.3.0 cannot update themselves (the update feed was missing from the app). Install 1.3.1 or later manually once from the DMG.

The setup wizard automatically:
- Detects your Python installation
- Creates a dedicated Python environment in `~/Library/Application Support/Voxa/`
- Installs all required ML packages (mlx-whisper, pyannote, torch...)
- This takes 5-10 minutes on first launch depending on your internet connection

> **Note:** You must accept the terms of use for pyannote models on HuggingFace:
> - [pyannote/segmentation-3.0](https://huggingface.co/pyannote/segmentation-3.0)
> - [pyannote/speaker-diarization-3.1](https://huggingface.co/pyannote/speaker-diarization-3.1)

### Optional: FFmpeg

FFmpeg improves audio format compatibility. Install with:

```bash
brew install ffmpeg
```

### Optional: Ollama

For AI-powered meeting summaries and speaker synthesis:

1. Install [Ollama](https://ollama.com)
2. Pull a model:

```bash
ollama pull llama3.1:8b
```

## Usage

### Transcription

1. **Drag** an audio file into the import zone (or use File → Import)
2. **Transcription** starts automatically (progress shown in menu bar)
3. Once complete, **identify speakers** by giving them names
4. **Generate summaries** with Ollama (brain icon)
5. **Export** the result in your preferred format

### Meeting Recording

1. Click **Record a meeting** in the menu bar
2. Voxa captures both **system audio** (other participants) and your **microphone**
3. Click **Stop and transcribe** to end recording
4. The recording is automatically transcribed

### Claude Code (MCP)

Voxa ships an [MCP](https://modelcontextprotocol.io) server so [Claude Code](https://claude.com/claude-code) can drive it. Transcription stays local; only the transcript text is sent to Claude when it reads it.

**Setup** (once): copy the command from **Settings → Claude Code (MCP)**, or run:

```bash
claude mcp add voxa --scope user -- "$HOME/Library/Application Support/Voxa/.venv/bin/python" "$HOME/Library/Application Support/Voxa/Scripts/voxa_mcp.py"
```

Then start a new Claude Code session (`/mcp` lists the Voxa tools). Voxa must be installed; if it is not running, it is launched in the background.

**Examples**:
- "Transcribe `~/Desktop/meeting.mov` and write the meeting report"
- "List my transcriptions from this week"
- Prompt `/compte_rendu`: transcribe if needed, confirm who is who, write the report and save it in Voxa

| Tool | Description |
|---|---|
| `transcribe_file` | Import an audio/video file and start transcription (returns an id) |
| `wait_for_transcription`, `get_transcription_status` | Wait for / check progress |
| `get_transcript` | Read the transcript (paginated for long meetings) |
| `rename_speakers` | Name speakers (`SPEAKER_00` → name); voices are remembered |
| `save_meeting_report` | Save a Markdown report in Voxa (report tab and exports) |
| `export_transcript` | Export to txt, md, srt or json |
| `list_transcriptions`, `list_known_speakers` | Search the library, list known voices |

## Build from source

```bash
git clone https://github.com/ArmanetPierre/Local-Transcription-Mac.git
cd transcription
```

Open `TranscriptionApp/TranscriptionApp.xcodeproj` in Xcode, then Build & Run (Cmd+R).

The Xcode project is generated from `TranscriptionApp/project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen). After adding or removing files, edit `project.yml` rather than the `.xcodeproj`, then run:

```bash
cd TranscriptionApp && xcodegen generate
```

### Tests and benchmark

```bash
./scripts/test.sh            # Python + Swift unit tests (or: python | swift)
```

`scripts/bench/run_bench.py` measures transcription quality and speed on a private set of real recordings kept outside the repo (word error rate, speaker attribution, automatic speaker recognition, speed). See [scripts/bench/README.md](scripts/bench/README.md). Run it before and after any change to the models or the pipeline.

To test the UI without running the models, launch a Debug build with the fake bridge (it replays a fictional meeting):

```bash
open --env VOXA_BRIDGE_SCRIPT="$PWD/scripts/dev/fake_bridge.py" build/DerivedData/Build/Products/Debug/Voxa.app
```

### Releasing a new version

1. Run `./scripts/test.sh`. In `TranscriptionApp/project.yml`, bump `MARKETING_VERSION` **and** `CURRENT_PROJECT_VERSION` (build number). Sparkle compares build numbers: if it does not increase, users never see the update. Then run `xcodegen generate` and commit.
2. Build, sign, notarize and generate the appcast:

   ```bash
   ./scripts/build-dmg.sh
   ```

   Requires the "Developer ID Application" certificate and notarization credentials stored once with `xcrun notarytool store-credentials "Voxa-Notarize" --apple-id <apple-id> --team-id C3A57SQ939`. If the build fails with "Operation not permitted", delete `build/Build/Products/Release/Voxa.app` and retry.
3. Push, then create the release **before** publishing the appcast (so the feed never points to a missing file):

   ```bash
   git push
   gh release create vX.Y.Z Voxa.dmg Voxa.zip --title "Voxa vX.Y.Z"
   git add docs/appcast.xml && git commit -m "Update appcast.xml for vX.Y.Z" && git push
   ```

Sparkle settings (`SUFeedURL`, `SUPublicEDKey`) live in `TranscriptionApp/TranscriptionApp/Info.plist`: `INFOPLIST_KEY_*` build settings are ignored by Xcode for non-Apple keys.

## Architecture

```
TranscriptionApp/
└── TranscriptionApp/
    ├── Models/           # SwiftData models, enums
    ├── Services/         # PythonBridge, DependencyManager, OllamaService, RecordingService, LocalAPIServer
    ├── ViewModels/       # TranscriptionListVM, RecordingVM
    ├── Views/            # SwiftUI views (SetupView, Detail, Sidebar, Import, MenuBar)
    ├── Utilities/        # EstimationService, SpeakerColors, TimeFormatting
    └── Resources/        # Bundled Python scripts (transcription, MCP server), localizations
```

### Swift ↔ Python Communication

The Swift app launches the bundled Python script as a subprocess and communicates via a **JSON Lines** protocol on stdout:

```
Swift (PythonBridge) → Process() → transcribe_bridge.py
                     ← stdout (JSON Lines: progress, segments, diarization)
```

### Claude Code (MCP) Architecture

```
Claude Code ──stdio──▶ voxa_mcp.py ──HTTP 127.0.0.1:47821──▶ Voxa (LocalAPIServer) ──▶ SwiftData + transcribe_bridge.py
```

- `voxa_mcp.py` is a dependency-free MCP server (stdio, JSON-RPC). It is bundled with the app and redeployed to `~/Library/Application Support/Voxa/Scripts/` at each launch.
- `LocalAPIServer` listens on the loopback interface only. Requests need a bearer token stored with the port in `~/Library/Application Support/Voxa/api.json` (mode 600).
- The app stays the only writer of the SwiftData store, so everything done through Claude appears in the Voxa library.
- Only files inside the user's home folder can be transcribed through the API.

### Recording Architecture

Voxa uses a dual-track recording approach to avoid audio echo:
- **System audio** → ScreenCaptureKit → AVAssetWriter (.m4a)
- **Microphone** → AVAudioEngine → AVAudioFile (.wav)
- On stop → AVMutableComposition merges both tracks into a single .m4a file

## CLI Script

The Python scripts live in `TranscriptionApp/TranscriptionApp/Resources/` (single source, bundled in the app). `transcribe.py` can also be used standalone from the command line:

```bash
# Using the venv created by Voxa
source ~/Library/Application\ Support/Voxa/.venv/bin/activate
python TranscriptionApp/TranscriptionApp/Resources/transcribe.py --audio recording.m4a --model large-v3-turbo --hf-token YOUR_TOKEN
```

## License

MIT
