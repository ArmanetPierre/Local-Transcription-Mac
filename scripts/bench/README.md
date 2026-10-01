# Banc de mesure

`run_bench.py` lance la chaîne de transcription (`transcribe_bridge.py`, comme l'app) sur un jeu d'extraits et mesure :

| Colonne | Signification |
|---|---|
| **WER** | Taux d'erreur sur les mots par rapport au texte de référence (texte normalisé : minuscules, sans ponctuation) |
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

Le jeton HuggingFace est lu dans les préférences de Voxa (ou `HF_TOKEN`).

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
