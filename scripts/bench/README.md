# Banc de mesure

`run_bench.py` lance la chaîne de transcription (`transcribe_bridge.py`, comme l'app) sur un jeu d'extraits et mesure :

| Colonne | Signification |
|---|---|
| **WER** | Taux d'erreur sur les mots par rapport au texte de référence (texte normalisé : minuscules, sans ponctuation) |
| **Mots** | Nombre de mots produits / nombre de mots de la référence (bien en dessous de 100 % : passages sautés) |
| **Ponct.** | Signes de fin de phrase pour 100 mots (proche de 0 : Whisper a perdu la ponctuation) |
| **Répét.** | Répétitions du groupe de 4 mots le plus répété (élevé : hallucination en boucle) |
| **Spk err** | Part du temps de parole attribuée au mauvais intervenant, après appariement optimal des étiquettes `SPEAKER_XX` |
| **Nb spk** | Intervenants trouvés / attendus |
| **Reconnus** | Intervenants nommés automatiquement à juste titre (voir « Reconnaissance » ci-dessous) |
| **RTF** | Temps de traitement / durée audio (0,1 = 10 fois plus rapide que le temps réel) |

## Utilisation

```bash
PY="$HOME/Library/Application Support/Voxa/.venv/bin/python"

# Mesurer la chaîne actuelle
"$PY" scripts/bench/run_bench.py --label baseline

# Mesurer une variante (autre script, sous-ensemble d'extraits)
"$PY" scripts/bench/run_bench.py --label essai --bridge /chemin/transcribe_bridge.py --items call-olivier-2

# Comparer des runs déjà faits
"$PY" scripts/bench/run_bench.py --compare baseline essai
```

Le jeton HuggingFace est lu dans le Trousseau (là où Voxa le range depuis la 1.4), sinon dans `HF_TOKEN`.

## Jeu de test

Les enregistrements sont privés : ils vivent **hors du dépôt**, dans `~/Projets/voxa-bench` (ou `VOXA_BENCH_DIR`).

```
voxa-bench/
├── items/<id>/audio.wav          # 16 kHz mono
├── items/<id>/reference.json
└── results/<label>/              # sorties brutes, logs et summary.json de chaque run
```

`reference.json` :

```json
{
  "id": "reunion-0309-b",
  "audio": "audio.wav",
  "language": "fr",
  "duration_sec": 586.4,
  "role": "recognize",
  "speaker_names": {"SPEAKER_02": "Olivier"},
  "source": "…",
  "text_reference": "machine (…) | human",
  "speaker_reference": "machine | human",
  "segments": [{"start": 0.0, "end": 4.2, "speaker": "SPEAKER_02", "text": "…"}]
}
```

- `role` : `enroll` (ses voix nommées alimentent la base de voix du banc), `recognize` (testé contre cette base) ou absent.
- Les segments dont l'intervenant vaut `Inconnu` sont ignorés pour l'erreur d'intervenant.

### Limite importante

Les références actuelles ont été **produites par la chaîne elle-même** (Whisper large-v3-turbo + pyannote 3.1), pas corrigées à la main. Le WER et le Spk err mesurent donc **l'écart avec l'ancienne chaîne**, pas la justesse absolue : un meilleur modèle peut afficher un WER plus élevé simplement parce qu'il corrige des erreurs de la référence. À lire avec les sorties brutes sous les yeux.

Seule vérité humaine disponible : les **noms** des intervenants de la réunion du 09/03, donnés par l'utilisateur dans Voxa. La réunion est coupée en deux : la première moitié (`enroll`) apprend les voix, la seconde (`recognize`) mesure la reconnaissance automatique.

Corriger à la main quelques minutes de référence (champ `text_reference: "human"`) rendrait le WER absolu.

## Variante Parakeet (expérimentale)

`parakeet_bridge.py` remplace Whisper par NVIDIA Parakeet TDT 0.6B v3 (`parakeet-mlx`) et garde la même diarisation. `parakeet-mlx` est installé **hors du venv de Voxa** :

```bash
PY="$HOME/Library/Application Support/Voxa/.venv/bin/python"
"$PY" -m pip install --no-deps --target ~/Projets/voxa-bench/.overlay-parakeet parakeet-mlx==0.5.2 \
    annotated-doc dacite decorator lazy-loader librosa msgpack platformdirs pooch shellingham soxr typer
PYTHONPATH=~/Projets/voxa-bench/.overlay-parakeet "$PY" scripts/bench/run_bench.py --label parakeet --bridge scripts/bench/parakeet_bridge.py
```

Résultat (octobre 2026) : comparable à Whisper sur la réunion en anglais, mais inutilisable sur les réunions en français (40 à 60 % de mots perdus, phrases traduites en anglais). Transcription environ 2,5 fois plus rapide que Whisper sur Mac.

## Variante native WhisperKit (expérimentale)

`whisperkit_bridge.py` fait tourner la chaîne 100 % native d'Argmax (`whisperkit-cli` : WhisperKit sur Core ML + diarisation SpeakerKit), sans Python :

```bash
brew install whisperkit-cli
# premier lancement : télécharge le modèle (~1,5 Go) et le prépare pour la puce (plusieurs minutes)
VOXA_WHISPERKIT_MODEL=~/Projets/voxa-bench/.whisperkit-models/openai_whisper-large-v3-v20240930_turbo \
    "$PY" scripts/bench/run_bench.py --label whisperkit --bridge scripts/bench/whisperkit_bridge.py
```

Résultat (octobre 2026, M3 Pro, même modèle large-v3-turbo) :

| | Chaîne actuelle (MLX + pyannote) | WhisperKit + SpeakerKit |
|---|---|---|
| Vitesse (à chaud) | ×6,2 le temps réel | **×16** le temps réel |
| Premier lancement | rapide | plusieurs minutes (préparation Core ML, une fois par emplacement du modèle) |
| Mots gardés | 93,8 % | 91,6 % (saute des passages où deux personnes parlent en même temps) |
| Ponctuation (pour 100 mots) | 9,9 | 8,3 |
| Nombre d'intervenants juste | 5 extraits sur 6 (en oublie un sur Parc Sophia) | 4 extraits sur 6 (en compte un de trop sur 2 appels) |
| Reconnaissance des voix | mesurée | non mesurable via la CLI (empreintes non exposées) |

`VOXA_WHISPERKIT_CHUNKING=none` (sans découpage par détection de voix) donne de moins bons résultats.
