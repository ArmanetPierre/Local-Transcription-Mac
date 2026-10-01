#!/usr/bin/env python3
"""Faux bridge de transcription, pour produire des captures d'ecran.

Parle exactement le meme protocole JSON Lines que transcribe_bridge.py, mais
n'ouvre aucun modele et ne lit pas l'audio : il rejoue une reunion fictive.
L'application ne voit pas la difference, ce qui donne des captures d'un ecran
reel, rempli d'un contenu qu'on peut publier.

Usage : lancer une version Debug de Voxa en pointant vers ce script, sans
toucher au vrai transcribe_bridge.py :

    open --env VOXA_BRIDGE_SCRIPT="$PWD/scripts/dev/fake_bridge.py" \
        build/DerivedData/Build/Products/Debug/Voxa.app

(ou definir VOXA_BRIDGE_SCRIPT dans le schema Xcode, onglet Run > Arguments).
La variable n'est lue que par les builds Debug.

Reglages par variables d'environnement :
    VOXA_FAKE_DURATION   duree simulee du traitement, en secondes (defaut 25)
    VOXA_FAKE_MATCHES    all | partial | none  (defaut all)
    VOXA_FAKE_LANG       code langue annonce dans le resultat (defaut en)
    VOXA_FAKE_EMBEDDINGS 1 pour emettre des empreintes vocales (defaut 0).
                         Desactive par defaut : confirmer les noms dans l'app
                         les enregistrerait dans la VRAIE base de voix
                         (speaker_embeddings.json) et fausserait la
                         reconnaissance des vraies reunions.
"""

import argparse
import json
import os
import random
import subprocess
import sys
import time

JSON_PROTOCOL = "--json-protocol" in sys.argv

# Duree totale simulee du traitement. Assez longue pour avoir le temps de
# capturer la barre de menu et l'overlay de progression, assez courte pour
# ne pas attendre entre deux captures.
FAKE_DURATION = float(os.environ.get("VOXA_FAKE_DURATION", "25"))
FAKE_MATCHES = os.environ.get("VOXA_FAKE_MATCHES", "all").lower()
FAKE_LANG = os.environ.get("VOXA_FAKE_LANG", "en")
FAKE_EMBEDDINGS = os.environ.get("VOXA_FAKE_EMBEDDINGS", "0") == "1"

EMBEDDING_DIM = 256  # meme dimension que pyannote

SPEAKER_NAMES = {
    "SPEAKER_00": "Maya Lindqvist",
    "SPEAKER_01": "Tomas Brenner",
    "SPEAKER_02": "Aida Okonjo",
    "SPEAKER_03": "Jonas Feld",
}

# Reunion fictive : revue hebdomadaire d'une equipe produit inventee.
# Les tours de parole consecutifs d'un meme speaker seront fusionnes par
# l'application, ce qui produit des paragraphes comme sur une vraie sortie.
TRANSCRIPT = [
    ("SPEAKER_00", "Right, let's start. Three things to close before the release on Thursday, and I would like to be quick about it."),
    ("SPEAKER_00", "Tomas, where are we on the sync failures?"),
    ("SPEAKER_01", "Better than last week. The retry loop was firing on every network change, including the ones where nothing was actually lost."),
    ("SPEAKER_01", "So a phone moving from wifi to cellular would replay the entire queue. That is where the duplicate entries were coming from."),
    ("SPEAKER_00", "Is that the same bug Aida reported in January?"),
    ("SPEAKER_01", "Same symptom, different cause. Hers was the conflict resolver picking the wrong side. This one never got that far."),
    ("SPEAKER_02", "I can confirm the duplicates are gone on my device. I have been running the build since Friday."),
    ("SPEAKER_02", "What I still see is the spinner staying up for about four seconds after the sync finishes."),
    ("SPEAKER_01", "That is the UI waiting for a completion callback that now fires earlier than it used to. I have a fix, it is two lines."),
    ("SPEAKER_00", "Ship it with the release or hold it?"),
    ("SPEAKER_01", "With the release. It is a cosmetic path, there is no data behind it."),
    ("SPEAKER_00", "Fine. Jonas, testing."),
    ("SPEAKER_03", "I ran the regression suite twice on the release candidate. One failure, and it is a real one."),
    ("SPEAKER_03", "If you delete an entry while it is still uploading, the app keeps the local row and the server keeps the file. Nothing crashes, but you end up with an orphan."),
    ("SPEAKER_00", "How often does that happen in practice?"),
    ("SPEAKER_03", "In practice, rarely. You have to delete within the upload window, which is usually under two seconds. But we have seen it twice in the beta channel."),
    ("SPEAKER_02", "Twice out of how many?"),
    ("SPEAKER_03", "About four hundred sessions. So it is not common, but it leaves the account in a state we cannot explain to the person on the phone."),
    ("SPEAKER_01", "The clean fix is to make delete wait for the upload to settle. That is a day of work and it touches the queue, which I would rather not touch two days before a release."),
    ("SPEAKER_00", "What is the dirty fix?"),
    ("SPEAKER_01", "Block the delete button while an upload is in flight. Ten minutes, and it makes the bad state unreachable."),
    ("SPEAKER_02", "A button that goes dead with no explanation is its own bug report. If we grey it out, it needs a line of text saying why."),
    ("SPEAKER_01", "Agreed. Give me the wording and I will put it in."),
    ("SPEAKER_02", "Something like uploading, one moment. I will send it in both languages this afternoon."),
    ("SPEAKER_00", "Good. So we block the button for Thursday, and the real fix goes in the sprint after. Jonas, open a ticket for the orphan cleanup as well, we still have the two accounts from the beta."),
    ("SPEAKER_03", "Will do. Do you want a migration for those, or do I fix them by hand?"),
    ("SPEAKER_00", "By hand. Two accounts is not a migration."),
    ("SPEAKER_03", "That is what I hoped you would say."),
    ("SPEAKER_00", "Third item, the onboarding numbers. Aida?"),
    ("SPEAKER_02", "The new flow is doing what we wanted, mostly. Completion went from fifty one to sixty eight percent."),
    ("SPEAKER_02", "The drop is concentrated on one screen, the one asking for calendar access. About a quarter of people stop there and never come back to it."),
    ("SPEAKER_00", "Do they refuse, or do they leave?"),
    ("SPEAKER_02", "They leave. They do not tap deny, they close the app. Which tells me the screen is asking too early, before they know why we want it."),
    ("SPEAKER_01", "We could delay the request until they open the calendar view for the first time."),
    ("SPEAKER_02", "That is what I would do. The permission means something at that point, and the people who never open that view are never asked."),
    ("SPEAKER_03", "It also makes the permission dialog testable, which right now it is not, because it fires before any state exists."),
    ("SPEAKER_00", "Any reason not to?"),
    ("SPEAKER_01", "One. If they say no at that point, the calendar view has to work in a degraded mode, and today it does not. It just shows an empty screen."),
    ("SPEAKER_02", "I have a design for the empty state from the last review. It was cut for time."),
    ("SPEAKER_00", "Then let's put it back in. Aida, send me the empty state, Tomas takes the permission move, and we look at the numbers again in three weeks."),
    ("SPEAKER_01", "Three weeks is short for a number that moved four points in a month."),
    ("SPEAKER_00", "It is short, but I want to see the direction before the board update. If the sample is thin we say the sample is thin."),
    ("SPEAKER_01", "Fair."),
    ("SPEAKER_00", "Anything else before we finish?"),
    ("SPEAKER_03", "One small thing. The crash reporter is still pointing at the old project. Everything since version four point two is landing in a dashboard nobody reads."),
    ("SPEAKER_00", "How long has that been the case?"),
    ("SPEAKER_03", "Since we renamed the bundle. So about six weeks."),
    ("SPEAKER_00", "So the quiet crash week we were pleased about was a reporting problem."),
    ("SPEAKER_03", "It was a reporting problem."),
    ("SPEAKER_01", "I will move it today. It is a configuration line."),
    ("SPEAKER_00", "Please do, and once it is moved, tell us what the real numbers look like. I would rather know."),
    ("SPEAKER_00", "That is everything. Thursday morning for the release, and Jonas signs off before it goes out."),
    ("SPEAKER_03", "Understood."),
    ("SPEAKER_02", "Thanks everyone."),
]

# Rythme de parole, en mots par seconde. Sert a donner aux segments des durees
# credibles avant la mise a l'echelle sur la duree reelle du fichier.
WORDS_PER_SECOND = 2.6
PAUSE_SAME_SPEAKER = 0.35
PAUSE_TURN_CHANGE = 0.9


def emit(msg):
    sys.stdout.write(json.dumps(msg, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def log(message, level="info"):
    if JSON_PROTOCOL:
        emit({"type": "log", "level": level, "message": message})
    else:
        print(message)


def probe_duration(path):
    """Duree reelle du fichier, via ffprobe. None si indisponible."""
    try:
        out = subprocess.run(
            ["ffprobe", "-v", "error", "-show_entries", "format=duration",
             "-of", "default=nw=1:nk=1", path],
            capture_output=True, text=True, timeout=15,
        )
        value = float(out.stdout.strip())
        return value if value > 1 else None
    except Exception:
        return None


def build_segments(audio_duration):
    """Construit la piste de segments, etiree sur la duree du fichier.

    Les timestamps doivent tomber a l'interieur de l'audio : le lecteur de
    l'application navigue vraiment dedans, et un segment qui commence apres la
    fin du fichier se voit tout de suite sur une capture.
    """
    raw = []
    cursor = 0.0
    previous_speaker = None
    for speaker, text in TRANSCRIPT:
        gap = PAUSE_SAME_SPEAKER if speaker == previous_speaker else PAUSE_TURN_CHANGE
        cursor += gap
        spoken = max(1.4, len(text.split()) / WORDS_PER_SECOND)
        raw.append({"start": cursor, "end": cursor + spoken, "speaker": speaker, "text": text})
        cursor += spoken
        previous_speaker = speaker

    scripted_end = raw[-1]["end"]
    if audio_duration:
        # On vise 98 % du fichier : la reunion se termine juste avant la fin de
        # l'enregistrement, comme une vraie.
        scale = (audio_duration * 0.98) / scripted_end
    else:
        scale = 1.0

    segments = []
    for i, seg in enumerate(raw):
        segments.append({
            "id": i,
            "start": round(seg["start"] * scale, 3),
            "end": round(seg["end"] * scale, 3),
            "text": seg["text"],
            "speaker": seg["speaker"],
            "avg_logprob": round(random.uniform(-0.42, -0.11), 4),
            "no_speech_prob": round(random.uniform(0.001, 0.06), 4),
        })
    return segments


def build_embeddings(speakers):
    """Vecteurs deterministes, de norme 1, un par speaker.

    Deterministes pour qu'une deuxieme execution produise les memes voix : si
    les noms ont ete confirmes une fois, la reconnaissance automatique se
    declenche vraiment au run suivant, et la capture montre le vrai comportement.
    """
    embeddings = {}
    for label in speakers:
        rng = random.Random(f"voxa-fake-{label}")
        vector = [rng.gauss(0, 1) for _ in range(EMBEDDING_DIM)]
        norm = sum(v * v for v in vector) ** 0.5
        embeddings[label] = [round(v / norm, 6) for v in vector]
    return embeddings


def play_progress(step, seconds, substep=None, start_at=0.0):
    """Emet une progression par paliers de 2 %, comme le vrai script."""
    ticks = 50
    total = 1000
    for i in range(1, ticks + 1):
        time.sleep(seconds / ticks)
        completed = int(total * i / ticks)
        msg = {
            "type": "progress", "step": step,
            "completed": completed, "total": total,
            "percent": round(100.0 * i / ticks, 1),
        }
        if substep:
            msg["substep"] = substep
        emit(msg)


def main():
    parser = argparse.ArgumentParser(description="Faux bridge, pour captures d'ecran")
    parser.add_argument("--audio", required=True)
    parser.add_argument("--language", "-l", default=None)
    parser.add_argument("--model", "-m", default="large-v3-turbo")
    parser.add_argument("--num-speakers", "-n", type=int, default=None)
    parser.add_argument("--min-speakers", type=int, default=None)
    parser.add_argument("--max-speakers", type=int, default=None)
    parser.add_argument("--output", "-o", default="txt")
    parser.add_argument("--output-dir", default=None)
    parser.add_argument("--hf-token", default=None)
    parser.add_argument("--no-diarize", action="store_true")
    parser.add_argument("--embeddings-file", default=None)
    parser.add_argument("--json-protocol", action="store_true")
    # Tolerant aux arguments que le vrai script gagnerait plus tard : ce fichier
    # ne doit jamais etre la raison d'un echec.
    args, unknown = parser.parse_known_args()
    if unknown:
        log(f"Arguments ignores par le faux bridge : {unknown}", level="debug")

    if not os.path.isfile(args.audio):
        emit({"type": "error", "step": "init",
              "message": f"Fichier introuvable : {args.audio}", "fatal": True})
        sys.exit(1)

    audio_duration = probe_duration(args.audio)
    segments = build_segments(audio_duration)
    speakers = sorted({seg["speaker"] for seg in segments})
    declared_duration = audio_duration or segments[-1]["end"]
    total_steps = 2 if args.no_diarize else 3

    log("FAUX BRIDGE : aucune inference, contenu fictif destine aux captures.",
        level="debug")

    emit({
        "type": "init",
        "audio_file": args.audio,
        "audio_duration_sec": round(declared_duration, 3),
        "model": args.model,
        "language": args.language,
        "diarization_enabled": not args.no_diarize,
    })

    # Repartition du temps simule : la transcription est la plus longue des
    # trois etapes sur une vraie execution, l'attente doit y ressembler.
    if args.no_diarize:
        share = {"transcription": FAKE_DURATION}
    else:
        share = {
            "transcription": FAKE_DURATION * 0.55,
            "diarization": FAKE_DURATION * 0.38,
            "assignment": FAKE_DURATION * 0.07,
        }

    started = time.time()

    emit({"type": "step_start", "step": "transcription",
          "step_number": 1, "total_steps": total_steps})
    t0 = time.time()
    play_progress("transcription", share["transcription"])
    emit({"type": "step_complete", "step": "transcription",
          "duration_sec": round(time.time() - t0, 1),
          "segments_count": len(segments),
          "detected_language": FAKE_LANG})

    speaker_embeddings = {}
    speaker_matches = {}

    if not args.no_diarize:
        emit({"type": "step_start", "step": "diarization",
              "step_number": 2, "total_steps": total_steps})
        t1 = time.time()
        # Les trois sous-etapes que pyannote annonce via son hook.
        for substep, weight in (("segmentation", 0.4),
                                ("embeddings", 0.4),
                                ("clustering", 0.2)):
            play_progress("diarization", share["diarization"] * weight, substep=substep)

        if FAKE_EMBEDDINGS:
            speaker_embeddings = build_embeddings(speakers)
            log(f"Embeddings: {len(speaker_embeddings)} speakers, dim={EMBEDDING_DIM}")

        if FAKE_MATCHES == "all":
            speaker_matches = dict(SPEAKER_NAMES)
        elif FAKE_MATCHES == "partial":
            speaker_matches = {"SPEAKER_00": SPEAKER_NAMES["SPEAKER_00"],
                               "SPEAKER_02": SPEAKER_NAMES["SPEAKER_02"]}
        speaker_matches = {k: v for k, v in speaker_matches.items() if k in speakers}
        for label, name in speaker_matches.items():
            log(f"Speaker match: {label} -> {name} (similarite: "
                f"{random.uniform(0.71, 0.93):.3f})")

        emit({"type": "step_complete", "step": "diarization",
              "duration_sec": round(time.time() - t1, 1),
              "speakers": speakers})

        emit({"type": "step_start", "step": "speaker_assignment",
              "step_number": 3, "total_steps": total_steps})
        time.sleep(share["assignment"])
    else:
        for seg in segments:
            seg["speaker"] = None

    result = {
        "type": "result",
        "segments": segments,
        "language": FAKE_LANG,
        "total_duration_sec": round(time.time() - started, 1),
    }
    if not args.no_diarize:
        if speaker_embeddings:
            result["speaker_embeddings"] = speaker_embeddings
        if speaker_matches:
            result["speaker_matches"] = speaker_matches

    emit(result)


if __name__ == "__main__":
    main()
