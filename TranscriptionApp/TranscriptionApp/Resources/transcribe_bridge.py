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
import re
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
    """Charger la base de voix : {nom: [empreinte, ...]}.

    Deux formats sur disque :
      - v1 (Voxa <= 1.4) : {"Nom": [floats]}            -> une empreinte par personne
      - v2               : {"version": 2, "speakers": {"Nom": [{"embedding": [floats], ...}, ...]}}
    """
    try:
        if filepath and os.path.isfile(filepath):
            with open(filepath, "r") as f:
                data = json.load(f)
            gallery = parse_gallery(data)
            samples = sum(len(v) for v in gallery.values())
            log(f"Voix connues: {len(gallery)} personnes, {samples} empreintes ({filepath})")
            return gallery
    except Exception as e:
        log(f"Impossible de charger les embeddings: {e}", level="debug")
    return {}


def parse_gallery(data):
    """Normalise les formats v1/v2 en {nom: [empreinte, ...]}."""
    if isinstance(data, dict) and data.get("version") == 2:
        return {
            name: [s["embedding"] for s in samples if s.get("embedding")]
            for name, samples in data.get("speakers", {}).items()
        }
    gallery = {}
    for name, value in (data or {}).items():
        if value and isinstance(value[0], (int, float)):
            gallery[name] = [value]          # v1 : une seule empreinte
        else:
            gallery[name] = list(value or [])  # liste d'empreintes
    return gallery


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


def speaker_scores(new_embeddings, gallery):
    """Similarite de chaque nouvel intervenant avec chaque personne connue.

    Le score d'une personne est le meilleur score sur ses empreintes : une voix
    enregistree en reunion et la meme en visio peuvent etre tres differentes,
    il suffit qu'un des contextes connus ressemble.
    Retourne {label: {nom: score}}.
    """
    gallery = parse_gallery(gallery)
    scores = {}
    warned = set()
    for label, emb in new_embeddings.items():
        scores[label] = {}
        for name, samples in gallery.items():
            usable = [s for s in samples if len(s) == len(emb)]
            if len(usable) < len(samples) and name not in warned:
                warned.add(name)
                log(f"Voix '{name}' : {len(samples) - len(usable)} empreinte(s) ignoree(s), "
                    f"dimension differente de {len(emb)} (autre modele)", level="warning")
            if usable:
                scores[label][name] = max(cosine_similarity(emb, s) for s in usable)
    return scores


def match_speakers_with_saved(new_embeddings, saved_embeddings, threshold=0.65, scores_out=None):
    """Matcher les nouveaux speakers avec les personnes connues via similarite cosinus.

    Utilise un matching glouton (meilleur score d'abord) pour eviter les doublons.
    Retourne: {new_speaker_label: matched_name}. Si scores_out est un dict, il recoit
    le score de chaque match ({label: score}).
    """
    if not new_embeddings or not saved_embeddings:
        return {}

    candidates = [
        (sim, label, name)
        for label, by_name in speaker_scores(new_embeddings, saved_embeddings).items()
        for name, sim in by_name.items()
        if sim >= threshold
    ]

    # Trier par similarite decroissante et attribuer de maniere gloutonne
    candidates.sort(reverse=True)
    matches = {}
    used_names = set()

    for sim, new_label, saved_name in candidates:
        if new_label not in matches and saved_name not in used_names:
            matches[new_label] = saved_name
            used_names.add(saved_name)
            if scores_out is not None:
                scores_out[new_label] = round(sim, 3)
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


# Pipelines de diarisation, du prefere au repli. community-1 (pyannote 4) fait
# moins de confusions entre intervenants ; 3.1 sert de repli si l'utilisateur
# n'a pas encore accepte ses conditions sur HuggingFace.
DIARIZATION_MODELS = [
    "pyannote/speaker-diarization-community-1",
    "pyannote/speaker-diarization-3.1",
]


def load_diarization_pipeline(hf_token, preferred=None):
    """Charge le premier pipeline disponible. Retourne (pipeline, nom)."""
    candidates = [preferred] if preferred else DIARIZATION_MODELS
    errors = []
    for name in candidates:
        try:
            return PyannotePipeline.from_pretrained(name, token=hf_token), name
        except Exception as e:
            log(f"Pipeline {name} indisponible: {e}", level="debug")
            errors.append(e)
    raise errors[-1]


def _speaker_at(start, end, turns, max_gap=1.0):
    """Intervenant qui couvre le plus [start, end] ; sinon le tour le plus proche
    (a moins de max_gap secondes)."""
    best, best_overlap = None, 0.0
    nearest, nearest_gap = None, float("inf")
    for t_start, t_end, speaker in turns:
        overlap = min(end, t_end) - max(start, t_start)
        if overlap > best_overlap:
            best, best_overlap = speaker, overlap
        gap = max(t_start - end, start - t_end, 0.0)
        if gap < nearest_gap:
            nearest, nearest_gap = speaker, gap
    if best is not None:
        return best
    # Mot entre deux tours de parole (silence, debut de phrase) : tour le plus proche
    return nearest if nearest_gap <= max_gap else None


# Boucles d'hallucination de Whisper ("la la la la...", "voila voila voila...")
MAX_REPEATS = 3


def _norm(word):
    return re.sub(r"[^\w']", "", word.lower())


def collapse_repetitions(words, max_ngram=4, max_repeats=MAX_REPEATS):
    """Retire les repetitions en boucle d'un mot ou groupe de mots (au-dela de
    max_repeats occurrences consecutives, on n'en garde qu'une).
    Travaille sur la liste des mots horodates de Whisper."""
    out = list(words)
    for n in range(1, max_ngram + 1):
        i = 0
        result = []
        while i < len(out):
            gram = [_norm(w["word"]) for w in out[i:i + n]]
            count = 1
            while i + (count + 1) * n <= len(out) and \
                    [_norm(w["word"]) for w in out[i + count * n:i + (count + 1) * n]] == gram:
                count += 1
            if len(gram) == n and any(gram) and count > max_repeats:
                result.extend(out[i:i + n])   # une seule occurrence
                i += count * n
            else:
                result.append(out[i])
                i += 1
        out = result
    return out


def remove_hallucination_loops(segments):
    """Applique collapse_repetitions a chaque segment (texte reconstruit depuis les mots)."""
    removed = 0
    for seg in segments:
        words = seg.get("words") or []
        if not words:
            continue
        kept = collapse_repetitions(words)
        if len(kept) < len(words):
            removed += len(words) - len(kept)
            seg["words"] = kept
            seg["text"] = "".join(w["word"] for w in kept)
            seg["end"] = kept[-1]["end"]
    if removed:
        log(f"Boucles d'hallucination retirees : {removed} mots")
    return segments


# Lissage de l'attribution mot par mot : les frontieres de la diarisation et
# l'horodatage des mots ont quelques dixiemes de seconde d'imprecision, ce qui
# fait basculer des mots isoles ("dans", "Et", "Ca") chez le mauvais intervenant.
MIN_TURN_WORDS = 3
MIN_TURN_SECONDS = 1.0
SNAP_WORDS = 2          # distance max (en mots) pour recaler une coupure sur la ponctuation
SENTENCE_END = (".", "?", "!", "…", ",", ";", ":")


def _runs(words, speakers):
    """Regroupe des mots consecutifs du meme intervenant : [[speaker, [mots]], ...]."""
    runs = []
    for w, spk in zip(words, speakers):
        if runs and runs[-1][0] == spk:
            runs[-1][1].append(w)
        else:
            runs.append([spk, [w]])
    return runs


def _is_short(run):
    words = run[1]
    return len(words) < MIN_TURN_WORDS or (words[-1]["end"] - words[0]["start"]) < MIN_TURN_SECONDS


def smooth_word_speakers(words, speakers):
    """Supprime les micro-tours et recale les coupures sur la ponctuation."""
    runs = _runs(words, speakers)
    # 1. Les tours trop courts rejoignent un voisin
    changed = True
    while changed and len(runs) > 1:
        changed = False
        for i, run in enumerate(runs):
            if not _is_short(run):
                continue
            prev = runs[i - 1] if i > 0 else None
            nxt = runs[i + 1] if i + 1 < len(runs) else None
            if prev and nxt and prev[0] == nxt[0]:
                target = prev
            elif prev and prev[1][-1]["word"].strip().endswith(SENTENCE_END):
                target = nxt or prev          # la phrase precedente est finie : debut de la suivante
            elif prev:
                target = prev                 # fin de la phrase de l'intervenant precedent
            else:
                target = nxt
            run[0] = target[0]
            runs = _runs([w for r in runs for w in r[1]], [r[0] for r in runs for _ in r[1]])
            changed = True
            break
    labels = [r[0] for r in runs for _ in r[1]]
    # 2. Recaler chaque coupure sur la ponctuation la plus proche
    for i in range(1, len(labels)):
        if labels[i] == labels[i - 1]:
            continue
        if words[i - 1]["word"].strip().endswith(SENTENCE_END):
            continue
        for k in range(1, SNAP_WORDS + 1):
            # ponctuation un peu plus loin : les premiers mots du nouveau tour finissent la phrase
            if i + k - 1 < len(words) and words[i + k - 1]["word"].strip().endswith(SENTENCE_END) \
                    and all(labels[j] == labels[i] for j in range(i, i + k)):
                for j in range(i, i + k):
                    labels[j] = labels[i - 1]
                break
            # ponctuation un peu avant : les derniers mots de l'ancien tour commencent la phrase
            if i - k - 1 >= 0 and words[i - k - 1]["word"].strip().endswith(SENTENCE_END) \
                    and all(labels[j] == labels[i - 1] for j in range(i - k, i)):
                for j in range(i - k, i):
                    labels[j] = labels[i]
                break
    return labels


def split_segments_by_speaker(segments, diarization):
    """Attribue un intervenant a chaque MOT, lisse, puis coupe les segments Whisper
    aux changements d'intervenant.

    Un segment Whisper peut contenir la fin de la phrase de l'un et le debut de
    la reponse de l'autre : l'attribuer en bloc colle la reponse au mauvais
    intervenant. Les segments sans horodatage par mot sont attribues en bloc.
    """
    turns = [(t.start, t.end, spk) for t, _, spk in diarization.itertracks(yield_label=True)]
    output = []
    for seg in segments:
        words = [w for w in seg.get("words") or [] if w.get("word", "").strip()]
        if not words:
            speaker = _speaker_at(seg["start"], seg["end"], turns, max_gap=5.0) or "Inconnu"
            output.append(dict(seg, speaker=speaker))
            continue
        speakers = []
        for w in words:
            spk = _speaker_at(w["start"], w["end"], turns)
            speakers.append(spk if spk is not None else (speakers[-1] if speakers else None))
        # Segment entier hors des tours detectes (ex. "Ciao, ciao." en fin d'appel)
        fallback = _speaker_at(seg["start"], seg["end"], turns, max_gap=5.0) or "Inconnu"
        speakers = [spk or fallback for spk in speakers]
        speakers = smooth_word_speakers(words, speakers)
        for speaker, run_words in _runs(words, speakers):
            output.append(dict(
                seg, speaker=speaker,
                start=run_words[0]["start"], end=run_words[-1]["end"],
                text="".join(w["word"] for w in run_words).strip(),
            ))
    for seg in output:
        seg.pop("words", None)
    return [s for s in output if s["text"]]


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
    parser.add_argument("--diarization-model", default=None, choices=DIARIZATION_MODELS,
                        help="Forcer un pipeline de diarisation (defaut : le meilleur disponible)")
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
        transcribe_kwargs = {
            "path_or_hf_repo": model_id,
            "verbose": not JSON_PROTOCOL,
            # Horodatage par mot : necessaire pour couper aux changements d'intervenant
            "word_timestamps": True,
        }
        # Reglages Whisper supplementaires (banc de mesure uniquement)
        if os.environ.get("VOXA_WHISPER_OPTIONS"):
            transcribe_kwargs.update(json.loads(os.environ["VOXA_WHISPER_OPTIONS"]))
            log(f"Options Whisper: {transcribe_kwargs}")
        if args.language:
            transcribe_kwargs["language"] = args.language

        result = mlx_whisper.transcribe(args.audio, **transcribe_kwargs)

        detected_language = result.get("language", args.language or "?")
        segments = result["segments"]

        # Filtrer les hallucinations
        segments = remove_hallucination_loops(segments)
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
                pipeline, pipeline_name = load_diarization_pipeline(hf_token, args.diarization_model)
                log(f"Pipeline de diarisation: {pipeline_name}")
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

            # Extraire l'annotation (pyannote 4.x retourne DiarizeOutput).
            # La version "exclusive" (un seul intervenant a la fois) est celle
            # prevue pour etre alignee sur une transcription.
            if hasattr(diarize_output, "speaker_diarization"):
                diarization = diarize_output.speaker_diarization
                exclusive = getattr(diarize_output, "exclusive_speaker_diarization", None)
                assignment_diarization = exclusive if exclusive is not None else diarization
            else:
                diarization = diarize_output
                assignment_diarization = diarization

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

            segments = split_segments_by_speaker(segments, assignment_diarization)
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
            speaker_match_scores = {}
            if speaker_embeddings and args.embeddings_file:
                saved = load_embeddings_file(args.embeddings_file)
                if saved:
                    speaker_matches = match_speakers_with_saved(
                        speaker_embeddings, saved, threshold=0.65, scores_out=speaker_match_scores
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
                    result_msg["speaker_match_scores"] = speaker_match_scores

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
