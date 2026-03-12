#!/usr/bin/env python3
"""
Transcription + diarisation audio - Bridge JSON Lines pour l'app SwiftUI.
Adapte de transcribe.py avec sortie structuree JSON Lines sur stdout.
"""

import argparse
import json
import os
import subprocess
import sys
import tempfile
import time
import warnings

# Supprimer le warning verbeux de torchcodec (non necessaire, on passe l'audio en memoire)
warnings.filterwarnings("ignore", message="torchcodec is not installed")

# === JSON Lines Protocol ===

JSON_PROTOCOL = "--json-protocol" in sys.argv


def _sanitize_floats(obj):
    """Remplacer NaN/Infinity par None pour produire du JSON valide."""
    import math
    if isinstance(obj, float):
        if math.isnan(obj) or math.isinf(obj):
            return None
        return obj
    if isinstance(obj, dict):
        return {k: _sanitize_floats(v) for k, v in obj.items()}
    if isinstance(obj, (list, tuple)):
        return [_sanitize_floats(v) for v in obj]
    return obj


def emit(msg):
    """Ecrire un message JSON Lines sur stdout et flusher immediatement."""
    sys.stdout.write(json.dumps(_sanitize_floats(msg), ensure_ascii=False) + "\n")
    sys.stdout.flush()


def log(message, level="info"):
    if JSON_PROTOCOL:
        emit({"type": "log", "level": level, "message": message})
    else:
        print(message)


# === Monkey-patch tqdm pour la progression transcription ===

if JSON_PROTOCOL:
    import tqdm as tqdm_module

    class JsonProgressBar:
        """Remplacement de tqdm qui emet des messages JSON Lines."""
        def __init__(self, *args, total=None, unit=None, disable=False, **kwargs):
            self.total = total or 0
            self.n = 0
            self._last_emit = 0

        def update(self, n=1):
            self.n += n
            if self.total > 0 and (self.n - self._last_emit) / self.total >= 0.02:
                emit({
                    "type": "progress", "step": "transcription",
                    "completed": self.n, "total": self.total,
                    "percent": round(100.0 * self.n / self.total, 1),
                })
                self._last_emit = self.n

        def __enter__(self):
            return self

        def __exit__(self, *args):
            pass

        def close(self):
            pass

    tqdm_module.tqdm = JsonProgressBar


# === Imports lourds (apres le monkey-patch de tqdm) ===

os.environ["PYTORCH_ENABLE_MPS_FALLBACK"] = "1"

import mlx_whisper
import numpy as np
import soundfile as sf
import torch
from pyannote.audio import Pipeline as PyannotePipeline


def get_device():
    if torch.backends.mps.is_available():
        return "mps"
    return "cpu"


def get_audio_duration(audio_path):
    """Obtenir la duree audio via ffprobe."""
    try:
        result = subprocess.run(
            ["ffprobe", "-v", "quiet", "-show_entries", "format=duration",
             "-of", "default=noprint_wrappers=1:nokey=1", audio_path],
            capture_output=True, text=True, check=True,
        )
        return float(result.stdout.strip())
    except Exception:
        return 0.0


# === Speaker Embedding Matching ===


def load_embeddings_file(filepath):
    """Charger les embeddings sauvegardes depuis un fichier JSON."""
    try:
        if filepath and os.path.isfile(filepath):
            with open(filepath, "r") as f:
                data = json.load(f)
                log(f"Embeddings charges: {len(data)} speakers depuis {filepath}")
                return data
    except Exception as e:
        log(f"Impossible de charger les embeddings: {e}", level="debug")
    return {}


def cosine_similarity(a, b):
    """Calcul de la similarite cosinus entre deux vecteurs."""
    a = np.array(a, dtype=np.float32)
    b = np.array(b, dtype=np.float32)
    dot = float(np.dot(a, b))
    norm_a = float(np.linalg.norm(a))
    norm_b = float(np.linalg.norm(b))
    if norm_a == 0 or norm_b == 0:
        return 0.0
    return dot / (norm_a * norm_b)


def match_speakers_with_saved(new_embeddings, saved_embeddings, threshold=0.65):
    """Matcher les nouveaux speakers avec les sauvegardes via similarite cosinus.

    Utilise un matching glouton (meilleur score d'abord) pour eviter les doublons.
    Retourne: {new_speaker_label: matched_name}
    """
    if not new_embeddings or not saved_embeddings:
        return {}

    # Calculer toutes les similarites
    scores = []
    for new_label, new_emb in new_embeddings.items():
        for saved_name, saved_emb in saved_embeddings.items():
            sim = cosine_similarity(new_emb, saved_emb)
            if sim >= threshold:
                scores.append((sim, new_label, saved_name))

    # Trier par similarite decroissante et attribuer de maniere gloutonne
    scores.sort(reverse=True)
    matches = {}
    used_names = set()
    used_labels = set()

    for sim, new_label, saved_name in scores:
        if new_label not in used_labels and saved_name not in used_names:
            matches[new_label] = saved_name
            used_labels.add(new_label)
            used_names.add(saved_name)
            log(f"Speaker match: {new_label} -> {saved_name} (similarite: {sim:.3f})")

    return matches


def assign_speakers_to_segments(segments, diarization):
    """Attribue un speaker a chaque segment de transcription base sur la diarisation."""
    for seg in segments:
        seg_start = seg["start"]
        seg_end = seg["end"]
        speaker_durations = {}
        for turn, _, speaker in diarization.itertracks(yield_label=True):
            overlap_start = max(seg_start, turn.start)
            overlap_end = min(seg_end, turn.end)
            overlap = max(0, overlap_end - overlap_start)
            if overlap > 0:
                speaker_durations[speaker] = speaker_durations.get(speaker, 0) + overlap
        if speaker_durations:
            seg["speaker"] = max(speaker_durations, key=speaker_durations.get)
        else:
            seg["speaker"] = "Inconnu"
    return segments


MLX_MODELS = {
    "tiny": "mlx-community/whisper-tiny-mlx",
    "base": "mlx-community/whisper-base-mlx",
    "small": "mlx-community/whisper-small-mlx",
    "medium": "mlx-community/whisper-medium-mlx",
    "large-v3": "mlx-community/whisper-large-v3-mlx",
    "large-v3-turbo": "mlx-community/whisper-large-v3-turbo",
}


def main():
    parser = argparse.ArgumentParser(
        description="Transcription + diarisation audio (bridge JSON Lines)"
    )
    parser.add_argument("--audio", required=True, help="Chemin du fichier audio")
    parser.add_argument("--language", "-l", default=None)
    parser.add_argument("--model", "-m", default="large-v3-turbo", choices=MLX_MODELS.keys())
    parser.add_argument("--num-speakers", "-n", type=int, default=None)
    parser.add_argument("--min-speakers", type=int, default=None)
    parser.add_argument("--max-speakers", type=int, default=None)
    parser.add_argument("--output", "-o", default="txt", choices=["txt", "json", "srt", "md"])
    parser.add_argument("--output-dir", default=None)
    parser.add_argument("--hf-token", default=None)
    parser.add_argument("--no-diarize", action="store_true")
    parser.add_argument("--embeddings-file", default=None,
                        help="Fichier JSON des embeddings speakers sauvegardes")
    parser.add_argument("--json-protocol", action="store_true",
                        help="Sortie JSON Lines pour integration GUI")
    args = parser.parse_args()

    current_step = "init"

    try:
        if not os.path.isfile(args.audio):
            if JSON_PROTOCOL:
                emit({"type": "error", "step": "init",
                      "message": f"Fichier introuvable : {args.audio}", "fatal": True})
            else:
                print(f"Erreur : fichier introuvable : {args.audio}", file=sys.stderr)
            sys.exit(1)

        torch_device = get_device()
        model_id = MLX_MODELS[args.model]
        audio_duration = get_audio_duration(args.audio)
        total_steps = 2 if args.no_diarize else 3

        # === Init ===
        if JSON_PROTOCOL:
            emit({
                "type": "init",
                "audio_file": args.audio,
                "audio_duration_sec": audio_duration,
                "model": args.model,
                "language": args.language,
                "diarization_enabled": not args.no_diarize,
            })
        else:
            print(f"=== Transcription + Diarisation ===")
            print(f"Fichier       : {args.audio}")
            print(f"Modele        : {args.model} ({model_id})")
            print(f"Langue        : {args.language or 'auto'}")
            print(f"Device MLX    : GPU Apple Silicon (Metal)")
            print(f"Device PyTorch: {torch_device} (diarisation)")
            print()

        # === Etape 1 : Transcription ===
        current_step = "transcription"
        if JSON_PROTOCOL:
            emit({"type": "step_start", "step": "transcription",
                  "step_number": 1, "total_steps": total_steps})
        else:
            print("[1/3] Transcription en cours (mlx-whisper, GPU)...")

        t0 = time.time()
        transcribe_kwargs = {"path_or_hf_repo": model_id, "verbose": not JSON_PROTOCOL}
        if args.language:
            transcribe_kwargs["language"] = args.language

        result = mlx_whisper.transcribe(args.audio, **transcribe_kwargs)

        detected_language = result.get("language", args.language or "?")
        segments = result["segments"]

        # Filtrer les hallucinations
        filtered = []
        for seg in segments:
            if seg["start"] >= seg["end"]:
                continue
            text = seg["text"].strip()
            if not text or len(text) <= 1:
                continue
            filtered.append(seg)
        segments = filtered

        t1 = time.time()
        if JSON_PROTOCOL:
            emit({
                "type": "step_complete", "step": "transcription",
                "duration_sec": round(t1 - t0, 1),
                "segments_count": len(segments),
                "detected_language": detected_language,
            })
        else:
            print(f"       Langue detectee : {detected_language}")
            print(f"       Transcription terminee en {t1 - t0:.1f}s")
            print(f"       {len(segments)} segments trouves")

        # === Etape 2 : Diarisation ===
        if not args.no_diarize:
            current_step = "diarization"
            hf_token = args.hf_token or os.environ.get("HF_TOKEN") or None

            if JSON_PROTOCOL:
                emit({"type": "step_start", "step": "diarization",
                      "step_number": 2, "total_steps": total_steps})
            else:
                print("[2/3] Diarisation (pyannote, GPU via MPS)...")

            t2 = time.time()

            # Charger depuis le cache local si pas de token HF
            if hf_token is None:
                os.environ["HF_HUB_OFFLINE"] = "1"

            try:
                pipeline = PyannotePipeline.from_pretrained(
                    "pyannote/speaker-diarization-3.1",
                    token=hf_token,
                )
            except Exception as e:
                if hf_token is None:
                    msg = ("Modeles pyannote non trouves en cache local. "
                           "Lancez une premiere fois avec --hf-token pour les telecharger, "
                           "ensuite le token ne sera plus necessaire.")
                    if JSON_PROTOCOL:
                        emit({"type": "error", "step": "diarization",
                              "message": msg, "fatal": True})
                    else:
                        print(f"\nErreur : {msg}", file=sys.stderr)
                    sys.exit(1)
                else:
                    raise

            pipeline.to(torch.device(torch_device))

            diarize_kwargs = {}
            if args.num_speakers is not None:
                diarize_kwargs["num_speakers"] = args.num_speakers
            if args.min_speakers is not None:
                diarize_kwargs["min_speakers"] = args.min_speakers
            if args.max_speakers is not None:
                diarize_kwargs["max_speakers"] = args.max_speakers

            # Hook de progression pour la diarisation
            if JSON_PROTOCOL:
                def diarization_hook(step_name, step_artefact, file=None,
                                     completed=None, total=None):
                    if completed is not None and total is not None:
                        c, t = int(completed), int(total)
                        emit({
                            "type": "progress", "step": "diarization",
                            "substep": step_name,
                            "completed": c, "total": t,
                            "percent": round(100.0 * c / t, 1) if t > 0 else 0,
                        })
                diarize_kwargs["hook"] = diarization_hook

            # Charger l'audio en memoire
            audio_path = args.audio
            tmp_wav = None
            try:
                waveform_np, sample_rate = sf.read(audio_path, dtype="float32")
            except Exception:
                log("Conversion audio via ffmpeg...")
                tmp_wav = tempfile.NamedTemporaryFile(suffix=".wav", delete=False)
                tmp_wav.close()
                subprocess.run(
                    ["ffmpeg", "-i", audio_path, "-ar", "16000", "-ac", "1",
                     "-y", tmp_wav.name],
                    capture_output=True, check=True,
                )
                waveform_np, sample_rate = sf.read(tmp_wav.name, dtype="float32")

            if waveform_np.ndim == 1:
                waveform_np = waveform_np[np.newaxis, :]
            else:
                waveform_np = waveform_np.T
            audio_dict = {
                "waveform": torch.from_numpy(waveform_np),
                "sample_rate": sample_rate,
            }

            diarize_output = pipeline(audio_dict, **diarize_kwargs)
            if tmp_wav is not None:
                os.unlink(tmp_wav.name)

            # Extraire l'annotation (pyannote 4.x retourne DiarizeOutput)
            if hasattr(diarize_output, "speaker_diarization"):
                diarization = diarize_output.speaker_diarization
            else:
                diarization = diarize_output

            # Recuperer les centroids depuis DiarizeOutput (pyannote 4.x)
            # DiarizeOutput.speaker_embeddings = array (num_speakers, dimension)
            # trie dans l'ordre de diarization.labels()
            raw_embeddings = getattr(diarize_output, "speaker_embeddings", None)
            embedding_labels = None
            if raw_embeddings is not None:
                embedding_labels = list(diarization.labels())
                log(f"Centroids recuperes: shape={raw_embeddings.shape}, labels={embedding_labels}")
            else:
                # Fallback pyannote 3.x
                raw_embeddings = getattr(pipeline, "embeddings_", None)
                if raw_embeddings is not None:
                    log(f"Centroids (fallback 3.x): shape={raw_embeddings.shape}")
                else:
                    log("Pas de centroids disponibles", level="debug")

            t3 = time.time()

            # Attribution des speakers
            current_step = "speaker_assignment"
            if JSON_PROTOCOL:
                emit({"type": "step_start", "step": "speaker_assignment",
                      "step_number": 3, "total_steps": total_steps})
            else:
                print("[3/3] Attribution des speakers aux segments...")

            segments = assign_speakers_to_segments(segments, diarization)
            speakers = sorted(set(seg.get("speaker", "Inconnu") for seg in segments))

            # Construire le dictionnaire d'embeddings par speaker
            speaker_embeddings = {}
            if raw_embeddings is not None:
                try:
                    emb_array = np.array(raw_embeddings)
                    # Utiliser embedding_labels (ordre DiarizeOutput) si disponible,
                    # sinon speakers (ordre alphabetique)
                    labels = embedding_labels if embedding_labels else speakers
                    for i, speaker in enumerate(labels):
                        if i < len(emb_array):
                            speaker_embeddings[speaker] = emb_array[i].tolist()
                    log(f"Embeddings: {len(speaker_embeddings)} speakers, dim={emb_array.shape[-1] if emb_array.ndim > 1 else '?'}")
                except Exception as e:
                    log(f"Erreur extraction embeddings: {e}", level="debug")

            # Comparer avec les embeddings sauvegardes
            speaker_matches = {}
            if speaker_embeddings and args.embeddings_file:
                saved = load_embeddings_file(args.embeddings_file)
                if saved:
                    speaker_matches = match_speakers_with_saved(
                        speaker_embeddings, saved, threshold=0.65
                    )
                    if speaker_matches:
                        log(f"Matching automatique: {speaker_matches}")
                    else:
                        log("Aucun match trouve avec les speakers connus")

            if JSON_PROTOCOL:
                emit({
                    "type": "step_complete", "step": "diarization",
                    "duration_sec": round(t3 - t2, 1),
                    "speakers": speakers,
                })
            else:
                print(f"       {len(speakers)} speakers identifies : {', '.join(speakers)}")
                print(f"       Diarisation terminee en {t3 - t2:.1f}s")

        total_time = time.time() - t0

        # === Resultat ===
        if JSON_PROTOCOL:
            output_segments = []
            for i, seg in enumerate(segments):
                output_segments.append({
                    "id": i,
                    "start": round(seg["start"], 3),
                    "end": round(seg["end"], 3),
                    "text": seg["text"].strip(),
                    "speaker": seg.get("speaker"),
                    "avg_logprob": seg.get("avg_logprob"),
                    "no_speech_prob": seg.get("no_speech_prob"),
                })

            result_msg = {
                "type": "result",
                "segments": output_segments,
                "language": detected_language,
                "total_duration_sec": round(total_time, 1),
            }

            # Inclure les embeddings et matchs si disponibles
            if not args.no_diarize:
                if speaker_embeddings:
                    result_msg["speaker_embeddings"] = speaker_embeddings
                if speaker_matches:
                    result_msg["speaker_matches"] = speaker_matches

            emit(result_msg)
        else:
            # Mode CLI classique : ecrire le fichier de sortie
            from transcribe import OUTPUT_FORMATS
            output_dir = args.output_dir or os.path.dirname(os.path.abspath(args.audio))
            base_name = os.path.splitext(os.path.basename(args.audio))[0]
            output_path = os.path.join(output_dir, f"{base_name}.{args.output}")
            OUTPUT_FORMATS[args.output](segments, output_path)
            print(f"\nTermine en {total_time:.1f}s")

    except Exception as e:
        if JSON_PROTOCOL:
            emit({"type": "error", "step": current_step,
                  "message": str(e), "fatal": True})
        else:
            print(f"Erreur: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
