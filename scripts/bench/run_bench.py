#!/usr/bin/env python3
"""
Banc de mesure de la chaine de transcription Voxa.

Lance transcribe_bridge.py (protocole JSON Lines, comme l'app) sur chaque
extrait du jeu de test, puis compare au transcript de reference :

  - WER          : taux d'erreur sur les mots (texte normalise)
  - Spk err      : part du temps de parole attribue au mauvais intervenant,
                   apres appariement optimal des etiquettes (SPEAKER_XX)
  - Nb spk       : nombre d'intervenants trouves / attendus
  - Reconnus     : intervenants nommes automatiquement correctement (les
                   extraits "enroll" alimentent la base de voix du banc,
                   les extraits "recognize" sont testes contre elle)
  - RTF          : temps de traitement / duree audio

Le jeu de test (prive) vit hors du depot, par defaut ~/Projets/voxa-bench :
    items/<id>/audio.wav
    items/<id>/reference.json   (voir scripts/bench/README.md)

Usage :
    python scripts/bench/run_bench.py --label baseline
    python scripts/bench/run_bench.py --label community1 --items call-olivier-2
    python scripts/bench/run_bench.py --compare baseline community1
    python scripts/bench/run_bench.py --rescore baseline   # apres modif des metriques

A lancer avec le Python du venv Voxa :
    "~/Library/Application Support/Voxa/.venv/bin/python"
"""

import argparse
import json
import os
import re
import subprocess
import sys
import time
import unicodedata

import numpy as np
from scipy.optimize import linear_sum_assignment

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DEFAULT_BRIDGE = os.path.join(REPO, "TranscriptionApp", "TranscriptionApp", "Resources", "transcribe_bridge.py")
DEFAULT_BENCH = os.environ.get("VOXA_BENCH_DIR", os.path.expanduser("~/Projets/voxa-bench"))
FRAME = 0.1  # resolution (s) du calcul d'erreur d'intervenant
UNLABELED = {"", "Inconnu", None}
# Hesitations ignorees dans le WER (convention de l'Open ASR Leaderboard)
FILLERS = {"uh", "um", "uhm", "hmm", "mhm", "mm", "euh", "heu", "hum", "ah", "oh", "eh"}


# --------------------------------------------------------------------------
# Metriques
# --------------------------------------------------------------------------

def normalize_words(text):
    """Minuscules, sans ponctuation ni accents combines bizarres, apostrophes unifiees."""
    text = unicodedata.normalize("NFC", text.lower())
    text = text.replace("’", "'").replace("'", " ")
    text = re.sub(r"[^\w\s-]", " ", text)
    text = text.replace("-", " ")
    return [w for w in text.split() if w not in FILLERS]


def punctuation_rate(segments):
    """Signes de fin de phrase pour 100 mots (0 : texte sans ponctuation)."""
    text = " ".join(s["text"] for s in segments)
    words = len(text.split())
    return 100.0 * len(re.findall(r"[.?!…]", text)) / words if words else None


def max_repeat(segments, n=4):
    """Nombre de repetitions du groupe de n mots le plus repete (hallucinations en boucle)."""
    words = normalize_words(" ".join(s["text"] for s in segments))
    counts = {}
    for i in range(len(words) - n + 1):
        key = tuple(words[i:i + n])
        counts[key] = counts.get(key, 0) + 1
    return max(counts.values()) if counts else 0


def word_errors(ref, hyp):
    """Distance d'edition (substitutions + insertions + suppressions) entre listes de mots."""
    previous = list(range(len(hyp) + 1))
    for i, r in enumerate(ref, 1):
        current = [i] + [0] * len(hyp)
        for j, h in enumerate(hyp, 1):
            current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (r != h))
        previous = current
    return previous[-1]


def wer(ref_segments, hyp_segments):
    ref = normalize_words(" ".join(s["text"] for s in ref_segments))
    hyp = normalize_words(" ".join(s["text"] for s in hyp_segments))
    if not ref:
        return None
    return word_errors(ref, hyp) / len(ref)


def frame_labels(segments, n_frames):
    labels = [None] * n_frames
    for s in segments:
        if s.get("speaker") in UNLABELED:
            continue
        for k in range(int(s["start"] / FRAME), min(int(s["end"] / FRAME), n_frames)):
            labels[k] = s["speaker"]
    return labels


def speaker_mapping(ref_segments, hyp_segments, duration):
    """Appariement optimal hyp -> ref (Hongrois sur le temps commun) et taux de confusion."""
    n = int(duration / FRAME) + 1
    ref, hyp = frame_labels(ref_segments, n), frame_labels(hyp_segments, n)
    ref_ids = sorted({r for r in ref if r})
    hyp_ids = sorted({h for h in hyp if h})
    if not ref_ids or not hyp_ids:
        return {}, None
    overlap = np.zeros((len(hyp_ids), len(ref_ids)))
    both = 0
    for r, h in zip(ref, hyp):
        if r and h:
            overlap[hyp_ids.index(h), ref_ids.index(r)] += 1
            both += 1
    rows, cols = linear_sum_assignment(-overlap)
    mapping = {hyp_ids[i]: ref_ids[j] for i, j in zip(rows, cols) if overlap[i, j] > 0}
    correct = sum(overlap[i, j] for i, j in zip(rows, cols))
    return mapping, (1 - correct / both) if both else None


# --------------------------------------------------------------------------
# Execution du bridge
# --------------------------------------------------------------------------

def hf_token():
    if os.environ.get("HF_TOKEN"):
        return os.environ["HF_TOKEN"]
    # Trousseau (Voxa >= 1.4), puis anciennes preferences
    for cmd in (["security", "find-generic-password", "-s", "com.pierre.Voxa", "-a", "hf_token", "-w"],
                ["defaults", "read", "com.pierre.Voxa", "hf_token"]):
        try:
            token = subprocess.check_output(cmd, stderr=subprocess.DEVNULL).decode().strip()
            if token:
                return token
        except subprocess.CalledProcessError:
            continue
    return None


def run_bridge(bridge, audio, language, embeddings_file, log_path):
    cmd = [sys.executable, "-u", bridge, "--audio", audio, "--json-protocol"]
    if language:
        cmd += ["--language", language]
    if embeddings_file:
        cmd += ["--embeddings-file", embeddings_file]
    token = hf_token()
    if token:
        cmd += ["--hf-token", token]
    env = dict(os.environ, PYTORCH_ENABLE_MPS_FALLBACK="1", PYTHONUNBUFFERED="1")

    result, steps, errors = None, {}, []
    start = time.time()
    with open(log_path, "w") as log:
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=log, text=True, env=env)
        for line in proc.stdout:
            try:
                msg = json.loads(line)
            except ValueError:
                continue
            if msg.get("type") == "result":
                result = msg
            elif msg.get("type") == "step_complete":
                steps[msg["step"]] = round(msg.get("duration_sec", 0), 1)
            elif msg.get("type") == "error":
                errors.append(msg.get("message"))
            if msg.get("type") in ("log", "error"):
                log.write("[%s] %s\n" % (msg.get("level", "error"), msg.get("message")))
                log.flush()
        proc.wait()
    elapsed = time.time() - start
    if result is None:
        raise RuntimeError("Pas de resultat (exit %s): %s — voir %s" % (proc.returncode, errors, log_path))
    return result, steps, elapsed


def load_gallery(gallery_path):
    """Base de voix du banc, au format v2 de Voxa : {nom: [empreinte, ...]}."""
    if not os.path.exists(gallery_path):
        return {}
    with open(gallery_path) as f:
        data = json.load(f)
    if data.get("version") != 2:  # anciens runs : {nom: empreinte}
        return {name: [vector] for name, vector in data.items()}
    return {name: [s["embedding"] for s in samples] for name, samples in data.get("speakers", {}).items()}


def enroll(gallery_path, item_id, result, mapping, names, mode):
    """Simule la confirmation des noms par l'utilisateur : ajoute les voix a la base du banc.

    mode "multi" : une empreinte de plus par contexte (Voxa >= 1.5)
    mode "single" : la nouvelle empreinte remplace l'ancienne (Voxa <= 1.4)
    """
    data = {"version": 2, "speakers": {}}
    if os.path.exists(gallery_path):
        with open(gallery_path) as f:
            data = json.load(f)
    for hyp_label, embedding in (result.get("speaker_embeddings") or {}).items():
        name = names.get(mapping.get(hyp_label, ""))
        if not name:
            continue
        sample = {"embedding": embedding, "source": "%s:%s" % (item_id, hyp_label)}
        if mode == "single":
            data["speakers"][name] = [sample]
        else:
            data["speakers"].setdefault(name, []).append(sample)
    with open(gallery_path, "w") as f:
        json.dump(data, f)


def cosine(a, b):
    a, b = np.asarray(a, dtype=np.float32), np.asarray(b, dtype=np.float32)
    denom = float(np.linalg.norm(a) * np.linalg.norm(b))
    return float(np.dot(a, b)) / denom if denom else 0.0


# --------------------------------------------------------------------------
# Banc
# --------------------------------------------------------------------------

def load_items(bench_dir, only):
    items_dir = os.path.join(bench_dir, "items")
    items = []
    for item_id in sorted(os.listdir(items_dir)):
        ref_path = os.path.join(items_dir, item_id, "reference.json")
        if not os.path.exists(ref_path) or (only and item_id not in only):
            continue
        with open(ref_path) as f:
            ref = json.load(f)
        ref["_dir"] = os.path.join(items_dir, item_id)
        items.append(ref)
    # Les extraits d'enrolement passent en premier pour alimenter la base de voix
    items.sort(key=lambda r: (r.get("role") != "enroll", r["id"]))
    return items


def evaluate(ref, result, steps, elapsed, gallery=None):
    hyp = result["segments"]
    duration = ref["duration_sec"]
    mapping, spk_err = speaker_mapping(ref["segments"], hyp, duration)
    ref_speakers = {s["speaker"] for s in ref["segments"] if s["speaker"] not in UNLABELED}
    hyp_speakers = {s.get("speaker") for s in hyp if s.get("speaker") not in UNLABELED}

    names = ref.get("speaker_names") or {}
    matches = result.get("speaker_matches") or {}
    recognition = None
    if names and ref.get("role") == "recognize":
        gallery = gallery or {}
        truth = {h: names[r] for h, r in mapping.items() if r in names}
        # On ne peut reconnaitre que les voix deja apprises
        expected = {h: n for h, n in truth.items() if n in gallery}
        correct = sum(1 for h, name in expected.items() if matches.get(h) == name)
        wrong = sum(1 for h, name in matches.items() if truth.get(h) != name)
        # Diagnostic : score de la bonne personne et meilleur score d'une mauvaise
        embeddings = result.get("speaker_embeddings") or {}
        details = {}
        for h, emb in embeddings.items():
            scores = {n: max(cosine(emb, s) for s in samples) for n, samples in gallery.items()}
            right = truth.get(h)
            details[h] = {
                "truth": right,
                "matched": matches.get(h),
                "score_truth": round(scores[right], 3) if right in scores else None,
                "best_other": round(max([v for n, v in scores.items() if n != right] or [0]), 3),
            }
        recognition = {"correct": correct, "expected": len(expected), "wrong": wrong,
                       "known": sorted(gallery), "details": details}

    ref_words = len(normalize_words(" ".join(s["text"] for s in ref["segments"])))
    hyp_words = len(normalize_words(" ".join(s["text"] for s in hyp)))
    return {
        "id": ref["id"],
        "duration_sec": duration,
        "wer": wer(ref["segments"], hyp),
        "words_ratio": hyp_words / ref_words if ref_words else None,
        "punctuation": punctuation_rate(hyp),
        "max_repeat": max_repeat(hyp),
        "speaker_error": spk_err,
        "speakers_found": len(hyp_speakers),
        "speakers_expected": len(ref_speakers),
        "recognition": recognition,
        "rtf": elapsed / duration,
        "elapsed_sec": round(elapsed, 1),
        "steps": steps,
        "mapping": mapping,
    }


def fmt_pct(x):
    return "—" if x is None else "%.1f %%" % (100 * x)


def fmt_recognition(r):
    if not r:
        return "—"
    text = "%d/%d" % (r["correct"], r["expected"])
    return text + (" (%d faux)" % r["wrong"] if r["wrong"] else "")


def print_table(rows, title):
    print("\n### " + title + "\n")
    print("| Extrait | Durée | WER | Mots | Ponct. | Répét. | Spk err | Nb spk | Reconnus | RTF |")
    print("|---|---|---|---|---|---|---|---|---|---|")
    for r in rows:
        punct = r.get("punctuation")
        print("| %s | %d min | %s | %s | %s | %s | %s | %d/%d | %s | %.3f |" % (
            r["id"], round(r["duration_sec"] / 60), fmt_pct(r["wer"]), fmt_pct(r.get("words_ratio")),
            "—" if punct is None else "%.1f" % punct, r.get("max_repeat", "—"),
            fmt_pct(r["speaker_error"]),
            r["speakers_found"], r["speakers_expected"], fmt_recognition(r["recognition"]), r["rtf"]))
    total = sum(r["duration_sec"] for r in rows)
    if total:
        def weighted(key):
            vals = [(r.get(key), r["duration_sec"]) for r in rows if r.get(key) is not None]
            return sum(v * d for v, d in vals) / sum(d for _, d in vals) if vals else None
        print("| **Total (pondéré)** | %d min | %s | %s | %s | | %s | | | %.3f |" % (
            round(total / 60), fmt_pct(weighted("wer")), fmt_pct(weighted("words_ratio")),
            "—" if weighted("punctuation") is None else "%.1f" % weighted("punctuation"),
            fmt_pct(weighted("speaker_error")),
            sum(r["elapsed_sec"] for r in rows) / total))


def run(args):
    run_dir = os.path.join(args.bench_dir, "results", args.label)
    os.makedirs(run_dir, exist_ok=True)
    gallery = os.path.join(run_dir, "gallery.json")
    if os.path.exists(gallery):
        os.remove(gallery)

    rows = []
    for ref in load_items(args.bench_dir, args.items):
        print("→ %s (%d min)..." % (ref["id"], round(ref["duration_sec"] / 60)), flush=True)
        audio = os.path.join(ref["_dir"], ref["audio"])
        result, steps, elapsed = run_bridge(
            args.bridge, audio, ref.get("language"),
            gallery if os.path.exists(gallery) else None,
            os.path.join(run_dir, ref["id"] + ".log"))
        with open(os.path.join(run_dir, ref["id"] + ".json"), "w") as f:
            json.dump(result, f, ensure_ascii=False)
        row = evaluate(ref, result, steps, elapsed, load_gallery(gallery))
        rows.append(row)
        if ref.get("role") == "enroll" and ref.get("speaker_names"):
            enroll(gallery, ref["id"], result, row["mapping"], ref["speaker_names"], args.gallery_mode)

    summary = {"label": args.label, "bridge": args.bridge, "date": time.strftime("%Y-%m-%d %H:%M"), "items": rows}
    with open(os.path.join(run_dir, "summary.json"), "w") as f:
        json.dump(summary, f, ensure_ascii=False, indent=1)
    print_table(rows, args.label)


def rescore(args):
    """Recalcule les metriques a partir des sorties deja enregistrees (sans relancer les modeles)."""
    run_dir = os.path.join(args.bench_dir, "results", args.rescore)
    with open(os.path.join(run_dir, "summary.json")) as f:
        summary = json.load(f)
    previous = {r["id"]: r for r in summary["items"]}
    rows = []
    for ref in load_items(args.bench_dir, list(previous)):
        with open(os.path.join(run_dir, ref["id"] + ".json")) as f:
            result = json.load(f)
        old = previous[ref["id"]]
        gallery = load_gallery(os.path.join(run_dir, "gallery.json"))
        known = (old.get("recognition") or {}).get("known")
        if known is not None:
            gallery = {n: samples for n, samples in gallery.items() if n in known}
        rows.append(evaluate(ref, result, old["steps"], old["elapsed_sec"], gallery))
    summary["items"] = rows
    with open(os.path.join(run_dir, "summary.json"), "w") as f:
        json.dump(summary, f, ensure_ascii=False, indent=1)
    print_table(rows, summary["label"])


def compare(args):
    runs = []
    for label in args.compare:
        with open(os.path.join(args.bench_dir, "results", label, "summary.json")) as f:
            runs.append(json.load(f))
    for summary in runs:
        print_table(summary["items"], "%s (%s)" % (summary["label"], summary["date"]))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--label", help="Nom du run (dossier de resultats)")
    parser.add_argument("--items", nargs="*", help="Limiter a ces extraits")
    parser.add_argument("--bridge", default=DEFAULT_BRIDGE, help="Script de transcription a tester")
    parser.add_argument("--bench-dir", default=DEFAULT_BENCH)
    parser.add_argument("--compare", nargs="+", metavar="LABEL", help="Afficher des runs deja faits")
    parser.add_argument("--gallery-mode", choices=["multi", "single"], default="multi",
                        help="multi : plusieurs empreintes par personne ; single : comportement Voxa <= 1.4")
    parser.add_argument("--rescore", metavar="LABEL", help="Recalculer les metriques d'un run sans relancer les modeles")
    args = parser.parse_args()
    if args.compare:
        compare(args)
    elif args.rescore:
        rescore(args)
    elif args.label:
        run(args)
    else:
        parser.error("--label ou --compare requis")


if __name__ == "__main__":
    main()
