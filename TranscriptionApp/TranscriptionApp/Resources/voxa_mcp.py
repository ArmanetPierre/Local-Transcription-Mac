#!/usr/bin/env python3
"""
Serveur MCP (stdio) pour Voxa.

Permet a Claude Code de lancer des transcriptions, lire les transcripts,
nommer les intervenants et enregistrer un compte rendu dans Voxa.

Ce script ne fait que relayer les appels vers l'API locale de l'app
(127.0.0.1, jeton dans ~/Library/Application Support/Voxa/api.json).
Il n'a aucune dependance hors bibliotheque standard.

Installation : copier la commande depuis Voxa > Reglages > Claude Code (MCP).
"""

import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

SERVER_NAME = "voxa"
SERVER_VERSION = "1.0.0"
DEFAULT_PROTOCOL_VERSION = "2025-06-18"

# api.json est ecrit par l'app dans son dossier de donnees, parent du dossier
# Scripts ou vit ce script. Dans la version App Store (sandbox), ce dossier est
# dans ~/Library/Containers/<app>/Data/... : le chemin relatif marche partout.
_HERE = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.path.join(os.path.dirname(_HERE), "api.json")
if not os.path.exists(CONFIG_PATH):
    CONFIG_PATH = os.path.expanduser("~/Library/Application Support/Voxa/api.json")
DEFAULT_BUNDLE_ID = "com.pierre.Voxa"
FINISHED_STATUSES = ("completed", "awaitingSpeakerNames", "failed")


class VoxaError(Exception):
    pass


class AppUnreachable(Exception):
    """L'app ne tourne pas (ou n'a jamais ecrit sa config API)."""


# --------------------------------------------------------------------------
# Client de l'API locale
# --------------------------------------------------------------------------

def load_config():
    try:
        with open(CONFIG_PATH) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def request(method, path, query=None, body=None, raw=False):
    """Appel a l'API de Voxa. Lance l'app si elle ne repond pas."""
    try:
        return _request(method, path, query, body, raw)
    except AppUnreachable:
        launch_app()
        return _request(method, path, query, body, raw)


def _request(method, path, query=None, body=None, raw=False):
    config = load_config()
    if not config:
        raise AppUnreachable()
    url = "http://127.0.0.1:%d%s" % (config["port"], path)
    if query:
        query = {k: v for k, v in query.items() if v is not None and v != ""}
        if query:
            url += "?" + urllib.parse.urlencode(query)
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", "Bearer " + config["token"])
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            payload = resp.read().decode("utf-8")
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace")
        try:
            detail = json.loads(detail).get("error", detail)
        except ValueError:
            pass
        raise VoxaError("Voxa API error %d: %s" % (e.code, detail))
    except (urllib.error.URLError, ConnectionError) as e:
        raise AppUnreachable("Voxa is not reachable (%s)" % getattr(e, "reason", e))
    return payload if raw else json.loads(payload)


def launch_app():
    """Ouvre Voxa en arriere-plan et attend que l'API reponde."""
    config = load_config() or {}
    bundle_id = config.get("bundle_id", DEFAULT_BUNDLE_ID)
    subprocess.run(["open", "-g", "-b", bundle_id], check=False,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    deadline = time.time() + 30
    while time.time() < deadline:
        time.sleep(1)
        try:
            _request("GET", "/health")
            return
        except AppUnreachable:
            continue
    raise VoxaError(
        "Voxa is not reachable. Open the Voxa app (and finish its setup), then retry."
    )


# --------------------------------------------------------------------------
# Outils
# --------------------------------------------------------------------------

def tool_list_transcriptions(args):
    return request("GET", "/transcriptions", {
        "query": args.get("query"),
        "since": args.get("since"),
        "limit": args.get("limit", 20),
    })


def tool_transcribe_file(args):
    path = os.path.abspath(os.path.expanduser(args["path"]))
    body = {"path": path}
    if args.get("language"):
        body["language"] = args["language"]
    return request("POST", "/transcriptions", body=body)


def tool_get_transcription_status(args):
    return request("GET", "/transcriptions/%s" % args["id"])


def tool_wait_for_transcription(args):
    timeout = min(int(args.get("timeout_sec", 300)), 600)
    deadline = time.time() + timeout
    while True:
        status = request("GET", "/transcriptions/%s" % args["id"])
        if status.get("status") in FINISHED_STATUSES or time.time() >= deadline:
            return status
        time.sleep(5)


def tool_get_transcript(args):
    return request("GET", "/transcriptions/%s/transcript" % args["id"], {
        "offset": args.get("offset", 0),
        "limit": args.get("limit", 400),
    })


def tool_rename_speakers(args):
    return request("POST", "/transcriptions/%s/speakers" % args["id"],
                   body={"names": args["names"]})


def tool_save_meeting_report(args):
    return request("PUT", "/transcriptions/%s/report" % args["id"],
                   body={"markdown": args["markdown"], "model": "Claude"})


def tool_export_transcript(args):
    fmt = args.get("format", "md")
    content = request("GET", "/transcriptions/%s/export" % args["id"],
                      {"format": fmt}, raw=True)
    output = os.path.abspath(os.path.expanduser(args["output_path"]))
    if os.path.isdir(output):
        info = request("GET", "/transcriptions/%s" % args["id"])
        safe_title = "".join(c for c in info["title"] if c not in '/\\:') or "transcript"
        output = os.path.join(output, "%s.%s" % (safe_title, fmt))
    with open(output, "w", encoding="utf-8") as f:
        f.write(content)
    return {"written": output, "bytes": len(content.encode("utf-8"))}


def tool_list_known_speakers(args):
    return request("GET", "/speakers")


ID_PROP = {"type": "string", "description": "Transcription id (UUID) returned by Voxa."}

TOOLS = [
    {
        "name": "list_transcriptions",
        "description": "List transcriptions stored in Voxa, newest first. "
                       "Filter by text (title, speaker name or spoken words) and by date.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "query": {"type": "string", "description": "Text to search for."},
                "since": {"type": "string", "description": "Only transcriptions created on/after this date (YYYY-MM-DD or ISO 8601)."},
                "limit": {"type": "integer", "description": "Max results (default 20)."},
            },
        },
        "handler": tool_list_transcriptions,
        "annotations": {"readOnlyHint": True},
    },
    {
        "name": "transcribe_file",
        "description": "Import an audio or video file (m4a, mp3, wav, mov, mp4...) into Voxa and "
                       "start a local transcription with speaker diarization. Returns immediately "
                       "with the transcription id; transcription takes roughly 10-30% of the audio "
                       "duration. Use wait_for_transcription to wait for it.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "path": {"type": "string", "description": "Absolute path of the file (must be inside the user's home folder)."},
                "language": {"type": "string", "description": "Optional ISO language code (e.g. 'fr', 'en'). Auto-detected if omitted."},
            },
            "required": ["path"],
        },
        "handler": tool_transcribe_file,
    },
    {
        "name": "get_transcription_status",
        "description": "Get status, progress, duration and speakers of a transcription. Speakers named by "
                       "automatic voice recognition have recognized_automatically=true and a recognition_score "
                       "(cosine similarity, 0-1; below ~0.75 ask the user to confirm).",
        "inputSchema": {"type": "object", "properties": {"id": ID_PROP}, "required": ["id"]},
        "handler": tool_get_transcription_status,
        "annotations": {"readOnlyHint": True},
    },
    {
        "name": "wait_for_transcription",
        "description": "Wait until a transcription finishes (or the timeout elapses) and return its status. "
                       "Status 'awaitingSpeakerNames' means it is done but speakers are still unnamed.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "id": ID_PROP,
                "timeout_sec": {"type": "integer", "description": "Max seconds to wait (default 300, max 600). Call again if still running."},
            },
            "required": ["id"],
        },
        "handler": tool_wait_for_transcription,
        "annotations": {"readOnlyHint": True},
    },
    {
        "name": "get_transcript",
        "description": "Read the transcript text, one line per speaker turn: '[HH:MM:SS] Speaker: text'. "
                       "Speakers show their name if identified, otherwise their label (SPEAKER_00...). "
                       "Long meetings are paginated: if 'next_offset' is present, call again with it.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "id": ID_PROP,
                "offset": {"type": "integer", "description": "Index of the first speaker turn (default 0)."},
                "limit": {"type": "integer", "description": "Max speaker turns to return (default 400)."},
            },
            "required": ["id"],
        },
        "handler": tool_get_transcript,
        "annotations": {"readOnlyHint": True},
    },
    {
        "name": "rename_speakers",
        "description": "Give real names to speaker labels, e.g. {\"SPEAKER_00\": \"Olivier\"}. "
                       "Names are saved in Voxa and their voices are remembered for future recognition "
                       "(also use it to confirm a name Voxa recognized automatically: it adds a voice sample). "
                       "Only do this with names the user confirmed.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "id": ID_PROP,
                "names": {
                    "type": "object",
                    "description": "Mapping from speaker label to person name.",
                    "additionalProperties": {"type": "string"},
                },
            },
            "required": ["id", "names"],
        },
        "handler": tool_rename_speakers,
    },
    {
        "name": "save_meeting_report",
        "description": "Save a meeting report (Markdown) into Voxa for this transcription. "
                       "It appears in the app's report tab and in exports. Replaces any previous report.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "id": ID_PROP,
                "markdown": {"type": "string", "description": "The report in Markdown."},
            },
            "required": ["id", "markdown"],
        },
        "handler": tool_save_meeting_report,
    },
    {
        "name": "export_transcript",
        "description": "Export a transcription (with its report if any) to a file: txt, md, srt or json.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "id": ID_PROP,
                "format": {"type": "string", "enum": ["txt", "md", "srt", "json"], "description": "Default md."},
                "output_path": {"type": "string", "description": "Destination file path, or a folder (file named after the transcription)."},
            },
            "required": ["id", "output_path"],
        },
        "handler": tool_export_transcript,
    },
    {
        "name": "list_known_speakers",
        "description": "List people whose voice Voxa already knows (recognized automatically in new transcriptions), "
                       "with the number of voice samples kept for each (one per transcription where they were named; "
                       "more samples = better recognition across recording setups).",
        "inputSchema": {"type": "object", "properties": {}},
        "handler": tool_list_known_speakers,
        "annotations": {"readOnlyHint": True},
    },
]

TOOLS_BY_NAME = {t["name"]: t for t in TOOLS}


# --------------------------------------------------------------------------
# Prompts
# --------------------------------------------------------------------------

REPORT_PROMPT = """Fais le compte rendu de la reunion {target} avec les outils Voxa.

1. Si c'est un fichier, lance transcribe_file puis wait_for_transcription jusqu'a la fin.
2. Lis le transcript complet avec get_transcript (suis next_offset s'il y en a).
3. Si des intervenants sont encore SPEAKER_XX, propose-moi qui est qui (avec un extrait
   de chacun) et attends ma confirmation avant d'appeler rename_speakers. Les noms
   reconnus automatiquement avec un recognition_score sous 0.75 sont a confirmer aussi ;
   au-dessus, mentionne-les simplement.
4. Redige le compte rendu en Markdown, dans la langue de la reunion :
   - Contexte et participants
   - Points discutes (resume par sujet)
   - Decisions prises
   - Actions a mener (responsable, echeance si mentionnee)
   - Questions ouvertes
5. Enregistre-le avec save_meeting_report et montre-le moi."""

PROMPTS = [
    {
        "name": "compte_rendu",
        "description": "Transcrire (si besoin) une reunion et en faire le compte rendu dans Voxa.",
        "arguments": [
            {"name": "source", "description": "Chemin d'un fichier audio/video, id ou titre d'une transcription Voxa. Vide = la plus recente.", "required": False},
        ],
    },
]


def get_prompt(name, arguments):
    if name != "compte_rendu":
        raise VoxaError("Unknown prompt: %s" % name)
    source = (arguments or {}).get("source") or ""
    target = ("'%s'" % source) if source else "la plus recente dans Voxa (list_transcriptions)"
    return {
        "description": PROMPTS[0]["description"],
        "messages": [{"role": "user", "content": {"type": "text", "text": REPORT_PROMPT.format(target=target)}}],
    }


# --------------------------------------------------------------------------
# JSON-RPC / MCP stdio
# --------------------------------------------------------------------------

def handle(message):
    method = message.get("method")
    params = message.get("params") or {}

    if method == "initialize":
        return {
            "protocolVersion": params.get("protocolVersion", DEFAULT_PROTOCOL_VERSION),
            "capabilities": {"tools": {}, "prompts": {}},
            "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
            "instructions": "Voxa transcribes meetings locally on this Mac (Whisper + speaker diarization). "
                            "Use these tools to transcribe files, read transcripts, name speakers "
                            "and store meeting reports in the Voxa app.",
        }
    if method == "ping":
        return {}
    if method == "tools/list":
        return {"tools": [
            {k: v for k, v in t.items() if k != "handler"} for t in TOOLS
        ]}
    if method == "tools/call":
        tool = TOOLS_BY_NAME.get(params.get("name"))
        if tool is None:
            raise JsonRpcError(-32602, "Unknown tool: %s" % params.get("name"))
        try:
            result = tool["handler"](params.get("arguments") or {})
            text = json.dumps(result, ensure_ascii=False, indent=2)
            return {"content": [{"type": "text", "text": text}], "isError": False}
        except Exception as e:  # erreurs metier renvoyees a Claude
            return {"content": [{"type": "text", "text": str(e)}], "isError": True}
    if method == "prompts/list":
        return {"prompts": PROMPTS}
    if method == "prompts/get":
        try:
            return get_prompt(params.get("name"), params.get("arguments"))
        except VoxaError as e:
            raise JsonRpcError(-32602, str(e))
    raise JsonRpcError(-32601, "Method not found: %s" % method)


class JsonRpcError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


def send(obj):
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except ValueError:
            send({"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "Parse error"}})
            continue

        msg_id = message.get("id")
        if msg_id is None:
            continue  # notification (ex: notifications/initialized)
        try:
            send({"jsonrpc": "2.0", "id": msg_id, "result": handle(message)})
        except JsonRpcError as e:
            send({"jsonrpc": "2.0", "id": msg_id, "error": {"code": e.code, "message": str(e)}})
        except Exception as e:
            send({"jsonrpc": "2.0", "id": msg_id, "error": {"code": -32603, "message": str(e)}})


if __name__ == "__main__":
    main()
