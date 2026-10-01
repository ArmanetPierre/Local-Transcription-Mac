"""Tests du serveur MCP voxa_mcp.py (protocole JSON-RPC, outils), sans l'app."""

import io
import json
import os
import sys
import tempfile
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
RESOURCES = os.path.join(HERE, "..", "..", "TranscriptionApp", "TranscriptionApp", "Resources")
sys.path.insert(0, os.path.abspath(RESOURCES))

import voxa_mcp  # noqa: E402


def call(method, params=None, msg_id=1):
    return voxa_mcp.handle({"jsonrpc": "2.0", "id": msg_id, "method": method, "params": params or {}})


class ProtocolTests(unittest.TestCase):
    def test_initialize_echoes_protocol_version(self):
        result = call("initialize", {"protocolVersion": "2025-03-26"})
        self.assertEqual(result["protocolVersion"], "2025-03-26")
        self.assertEqual(result["serverInfo"]["name"], "voxa")
        self.assertIn("tools", result["capabilities"])

    def test_tools_list_hides_handlers_and_has_schemas(self):
        tools = call("tools/list")["tools"]
        names = {t["name"] for t in tools}
        self.assertIn("transcribe_file", names)
        self.assertIn("save_meeting_report", names)
        for tool in tools:
            self.assertNotIn("handler", tool)
            self.assertEqual(tool["inputSchema"]["type"], "object")

    def test_unknown_method_raises_method_not_found(self):
        with self.assertRaises(voxa_mcp.JsonRpcError) as ctx:
            call("does/not/exist")
        self.assertEqual(ctx.exception.code, -32601)

    def test_unknown_tool_raises_invalid_params(self):
        with self.assertRaises(voxa_mcp.JsonRpcError) as ctx:
            call("tools/call", {"name": "nope", "arguments": {}})
        self.assertEqual(ctx.exception.code, -32602)

    def test_prompt_mentions_source(self):
        result = call("prompts/get", {"name": "compte_rendu", "arguments": {"source": "~/call.mov"}})
        self.assertIn("~/call.mov", result["messages"][0]["content"]["text"])

    def test_main_loop_skips_notifications_and_answers_requests(self):
        lines = "\n".join([
            json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}),
            json.dumps({"jsonrpc": "2.0", "id": 7, "method": "ping"}),
            "not json",
        ]) + "\n"
        out = io.StringIO()
        with mock.patch.object(sys, "stdin", io.StringIO(lines)), mock.patch.object(sys, "stdout", out):
            voxa_mcp.main()
        responses = [json.loads(line) for line in out.getvalue().splitlines()]
        self.assertEqual(responses[0], {"jsonrpc": "2.0", "id": 7, "result": {}})
        self.assertEqual(responses[1]["error"]["code"], -32700)


class ToolTests(unittest.TestCase):
    def test_tool_error_is_returned_to_claude_not_raised(self):
        with mock.patch.object(voxa_mcp, "request", side_effect=voxa_mcp.VoxaError("Voxa API error 404: nope")):
            result = call("tools/call", {"name": "get_transcript", "arguments": {"id": "x"}})
        self.assertTrue(result["isError"])
        self.assertIn("404", result["content"][0]["text"])

    def test_transcribe_file_expands_path(self):
        with mock.patch.object(voxa_mcp, "request", return_value={"id": "1"}) as req:
            call("tools/call", {"name": "transcribe_file", "arguments": {"path": "~/a.m4a", "language": "fr"}})
        method, path = req.call_args[0][:2]
        body = req.call_args[1]["body"]
        self.assertEqual((method, path), ("POST", "/transcriptions"))
        self.assertEqual(body, {"path": os.path.expanduser("~/a.m4a"), "language": "fr"})

    def test_wait_returns_as_soon_as_finished(self):
        statuses = iter([{"status": "transcribing"}, {"status": "awaitingSpeakerNames"}])
        with mock.patch.object(voxa_mcp, "request", side_effect=lambda *a, **k: next(statuses)), \
                mock.patch.object(voxa_mcp.time, "sleep"):
            result = voxa_mcp.tool_wait_for_transcription({"id": "1", "timeout_sec": 60})
        self.assertEqual(result["status"], "awaitingSpeakerNames")

    def test_export_to_folder_uses_title(self):
        def fake_request(method, path, query=None, body=None, raw=False):
            return "contenu" if raw else {"title": "Call: Olivier/Pierre"}
        with tempfile.TemporaryDirectory() as folder, mock.patch.object(voxa_mcp, "request", side_effect=fake_request):
            result = voxa_mcp.tool_export_transcript({"id": "1", "format": "md", "output_path": folder})
            self.assertEqual(os.path.basename(result["written"]), "Call OlivierPierre.md")
            with open(result["written"]) as f:
                self.assertEqual(f.read(), "contenu")


class RequestTests(unittest.TestCase):
    def test_launches_app_when_unreachable_then_retries(self):
        calls = []

        def fake_request(*args, **kwargs):
            calls.append(args)
            if len(calls) == 1:
                raise voxa_mcp.AppUnreachable("down")
            return {"ok": True}

        with mock.patch.object(voxa_mcp, "_request", side_effect=fake_request), \
                mock.patch.object(voxa_mcp, "launch_app") as launch:
            self.assertEqual(voxa_mcp.request("GET", "/health"), {"ok": True})
        launch.assert_called_once()
        self.assertEqual(len(calls), 2)

    def test_api_errors_are_not_retried(self):
        with mock.patch.object(voxa_mcp, "_request", side_effect=voxa_mcp.VoxaError("400")), \
                mock.patch.object(voxa_mcp, "launch_app") as launch:
            with self.assertRaises(voxa_mcp.VoxaError):
                voxa_mcp.request("GET", "/x")
        launch.assert_not_called()


if __name__ == "__main__":
    unittest.main()
