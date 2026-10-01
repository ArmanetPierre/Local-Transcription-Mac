#!/usr/bin/env python3
"""
Variante experimentale du bridge pour le banc : chaine 100 % native via
whisperkit-cli (Argmax) : transcription WhisperKit (Core ML / Neural Engine)
+ diarisation SpeakerKit, sans Python ni PyTorch.

Parle le protocole JSON Lines de transcribe_bridge.py :

    brew install whisperkit-cli
    VOXA_WHISPERKIT_MODEL=/chemin/openai_whisper-large-v3-v20240930_turbo \\
        "$PY" scripts/bench/run_bench.py --label whisperkit --bridge scripts/bench/whisperkit_bridge.py

Limite : la CLI ne fournit pas les empreintes vocales, la reconnaissance des
voix n'est donc pas mesuree (elle le serait via l'API Swift de SpeakerKit).
"""

import argparse
import json
import os
import re
import subprocess
import tempfile
import time

MODEL = os.environ.get("VOXA_WHISPERKIT_MODEL")
DIARIZATION_HEADER = "---- Speaker Diarization Results ----"


def emit(obj):
    print(json.dumps(obj, ensure_ascii=False), flush=True)


def clean(text):
    # La sortie RTTM de la CLI separe les apostrophes : "j 'ai" -> "j'ai"
    return re.sub(r"(\w) '(\w)", r"\1'\2", text).strip()


def parse_rttm(stdout):
    """Lignes 'SPEAKER <fichier> 1 <debut> <duree> <texte...> <NA> <locuteur> <NA> <NA>'."""
    segments = []
    in_block = False
    for line in stdout.splitlines():
        if line.startswith(DIARIZATION_HEADER):
            in_block = True
            continue
        if not in_block or not line.startswith("SPEAKER "):
            continue
        parts = line.split(" ")
        start, duration = float(parts[3]), float(parts[4])
        text = clean(" ".join(parts[5:-4]))
        if text:
            segments.append({"id": len(segments), "start": round(start, 2),
                             "end": round(start + duration, 2), "text": text,
                             "speaker": "SPEAKER_%s" % parts[-3]})
    return segments


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--audio", required=True)
    parser.add_argument("--language", default=None)
    parser.add_argument("--embeddings-file", default=None)
    parser.add_argument("--hf-token", default=None)
    parser.add_argument("--json-protocol", action="store_true")
    args = parser.parse_args()
    if not MODEL:
        raise SystemExit("VOXA_WHISPERKIT_MODEL non defini")

    emit({"type": "step_start", "step": "transcription", "step_number": 1, "total_steps": 1})
    t0 = time.time()
    with tempfile.TemporaryDirectory() as report_dir:
        cmd = ["whisperkit-cli", "transcribe", "--audio-path", args.audio, "--model-path", MODEL,
               "--word-timestamps", "--diarization", "--report", "--report-path", report_dir]
        if args.language:
            cmd += ["--language", args.language]
        if os.environ.get("VOXA_WHISPERKIT_CHUNKING"):
            cmd += ["--chunking-strategy", os.environ["VOXA_WHISPERKIT_CHUNKING"]]
        proc = subprocess.run(cmd, capture_output=True, text=True)
        if proc.returncode != 0:
            emit({"type": "error", "message": proc.stderr[-2000:], "fatal": True})
            raise SystemExit(1)
        language = "?"
        for name in os.listdir(report_dir):
            if name.endswith(".json"):
                with open(os.path.join(report_dir, name)) as f:
                    language = json.load(f).get("language", "?")
    segments = parse_rttm(proc.stdout)
    elapsed = round(time.time() - t0, 1)
    emit({"type": "step_complete", "step": "transcription", "duration_sec": elapsed,
          "segments_count": len(segments)})
    emit({"type": "result", "segments": segments, "language": language, "total_duration_sec": elapsed})


if __name__ == "__main__":
    main()
