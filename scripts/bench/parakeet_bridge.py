#!/usr/bin/env python3
"""
Variante experimentale du bridge pour le banc : transcription par NVIDIA
Parakeet TDT 0.6B v3 (parakeet-mlx) au lieu de Whisper, diarisation et
reconnaissance des voix identiques a transcribe_bridge.py.

Parle le meme protocole JSON Lines, donc run_bench.py l'utilise tel quel :

    PYTHONPATH=~/Projets/voxa-bench/.overlay-parakeet \\
        "$PY" scripts/bench/run_bench.py --label parakeet --bridge scripts/bench/parakeet_bridge.py

parakeet-mlx n'est PAS installe dans le venv de Voxa : il vit dans un dossier
a part (voir scripts/bench/README.md) pour ne pas toucher a l'app.
"""

import argparse
import json
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
RESOURCES = os.path.join(HERE, "..", "..", "TranscriptionApp", "TranscriptionApp", "Resources")
sys.path.insert(0, os.path.abspath(RESOURCES))

# Le bridge emet ses logs en JSON seulement si --json-protocol est dans argv
import transcribe_bridge as bridge  # noqa: E402

import numpy as np  # noqa: E402
import soundfile as sf  # noqa: E402
import torch  # noqa: E402
from parakeet_mlx import from_pretrained  # noqa: E402

PARAKEET_MODEL = os.environ.get("VOXA_PARAKEET_MODEL", "mlx-community/parakeet-tdt-0.6b-v3")


def emit(obj):
    print(json.dumps(obj, ensure_ascii=False), flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--audio", required=True)
    parser.add_argument("--language", default=None, help="Ignore : Parakeet detecte la langue")
    parser.add_argument("--embeddings-file", default=None)
    parser.add_argument("--hf-token", default=None)
    parser.add_argument("--diarization-model", default=None)
    parser.add_argument("--json-protocol", action="store_true")
    args = parser.parse_args()

    # 1. Transcription
    emit({"type": "step_start", "step": "transcription", "step_number": 1, "total_steps": 3})
    t0 = time.time()
    model = from_pretrained(PARAKEET_MODEL)
    # Morceaux de 30 s : sans decoupage (ou avec 120 s), Parakeet renvoie du vide
    # ou traduit en anglais sur nos enregistrements (teste sur call-olivier-2)
    result = model.transcribe(args.audio, chunk_duration=30, overlap_duration=5)
    segments = [
        {"id": i, "start": round(s.start, 2), "end": round(s.end, 2), "text": s.text.strip()}
        for i, s in enumerate(result.sentences) if s.text.strip()
    ]
    emit({"type": "step_complete", "step": "transcription",
          "duration_sec": round(time.time() - t0, 1), "segments_count": len(segments)})

    # 2. Diarisation (meme pipeline que l'app)
    emit({"type": "step_start", "step": "diarization", "step_number": 2, "total_steps": 3})
    t1 = time.time()
    token = args.hf_token or os.environ.get("HF_TOKEN")
    pipeline, name = bridge.load_diarization_pipeline(token, args.diarization_model)
    bridge.log(f"Pipeline de diarisation: {name}")
    device = "mps" if torch.backends.mps.is_available() else "cpu"
    pipeline.to(torch.device(device))
    waveform, sample_rate = sf.read(args.audio, dtype="float32")
    waveform = waveform[np.newaxis, :] if waveform.ndim == 1 else waveform.T
    output = pipeline({"waveform": torch.from_numpy(waveform), "sample_rate": sample_rate})
    diarization = getattr(output, "speaker_diarization", output)
    exclusive = getattr(output, "exclusive_speaker_diarization", None)
    bridge.assign_speakers_to_segments(segments, exclusive if exclusive is not None else diarization)

    embeddings = {}
    raw = getattr(output, "speaker_embeddings", None)
    if raw is not None:
        for label, vector in zip(diarization.labels(), np.array(raw)):
            embeddings[label] = vector.tolist()
    matches = {}
    if embeddings and args.embeddings_file:
        saved = bridge.load_embeddings_file(args.embeddings_file)
        if saved:
            matches = bridge.match_speakers_with_saved(embeddings, saved, threshold=0.65)
    emit({"type": "step_complete", "step": "diarization", "duration_sec": round(time.time() - t1, 1)})

    out = {"type": "result", "segments": segments, "language": "auto",
           "total_duration_sec": round(time.time() - t0, 1)}
    if embeddings:
        out["speaker_embeddings"] = embeddings
    if matches:
        out["speaker_matches"] = matches
    emit(out)


if __name__ == "__main__":
    main()
