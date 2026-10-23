import io
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
from types import SimpleNamespace
import tarfile
import tempfile
import threading
import unittest
from unittest.mock import patch

from afterword_remote_client import (CancellableBody, Remote, Run, UploadCancelled, WORKER_PROTOCOL,
                                     apply_changes, localize_profiles, meeting_archive)


class RemoteClientTests(unittest.TestCase):
    def fixture(self, root):
        (root / "work/run").mkdir(parents=True)
        (root / "audio").mkdir()
        (root / "audio/raw.caf").write_bytes(b"raw audio")
        (root / "meeting.json").write_text(json.dumps({"schema_version": 1, "id": "meeting",
            "capture_state": "stopped", "chunks": [{"relative_path": "audio/raw.caf"}],
            "title": "private title", "calendar_event": "private invitees"}))
        (root / "work/run/names.json").write_text('{"schema_version":1,"speaker_names":{}}')
        (root / "work/run/microphone.wav").write_bytes(b"prepared audio")
        (root / "work/run/prepared.json").write_text(json.dumps({"schema_version": 1,
            "sources": [{"source": "microphone", "relative_path": "work/run/microphone.wav"}]}))
        (root / "voice_profiles.json").write_text("private voiceprint")
        (root / "revisions/old").mkdir(parents=True)
        (root / "revisions/old/summaries.json").write_text("private notes")

    def test_full_archive_contains_only_current_inputs_and_minimal_meeting_metadata(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            self.fixture(root)
            args = SimpleNamespace(names="work/run/names.json", summary_only=False, prepared="work/run/prepared.json",
                                   revision_id="next", run_id="run", summary_checkpoint=None)
            output = io.BytesIO()
            meeting_archive(root, output, args)
            with tarfile.open(fileobj=io.BytesIO(output.getvalue())) as archive:
                self.assertEqual(sorted(archive.getnames()), ["meeting.json", "work/run/microphone.wav",
                    "work/run/names.json", "work/run/prepared.json"])
                metadata = json.load(archive.extractfile("meeting.json"))
            self.assertEqual(set(metadata), {"schema_version", "id", "capture_state", "chunks"})
            self.assertNotIn(b"private title", output.getvalue())
            self.assertNotIn(b"private voiceprint", output.getvalue())
            self.assertNotIn(b"private notes", output.getvalue())

    def test_summary_archive_omits_audio_and_unrelated_revisions(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            self.fixture(root)
            revision = root / "revisions/current"
            revision.mkdir()
            (revision / "transcript.json").write_text("transcript")
            (revision / "provenance.json").write_text("provenance")
            args = SimpleNamespace(names="work/run/names.json", summary_only=True, prepared=None,
                                   revision_id="current", run_id="run", summary_checkpoint=None)
            output = io.BytesIO()
            meeting_archive(root, output, args)
            with tarfile.open(fileobj=io.BytesIO(output.getvalue())) as archive:
                self.assertEqual(sorted(archive.getnames()), ["meeting.json", "revisions/current/provenance.json",
                    "revisions/current/transcript.json", "work/run/names.json"])

    def test_incompatible_server_refuses_before_upload(self):
        with tempfile.TemporaryDirectory() as folder:
            calls = []
            def call(method, *args, **kwargs):
                calls.append(method)
                return b'{"ok":true}'
            remote = SimpleNamespace(call=call)
            args = SimpleNamespace(meeting=folder, run_id="run")
            run = Run(args, remote)
            with self.assertRaisesRegex(ValueError, "compatible"):
                run.submit()
            self.assertEqual(calls, ["GET"])

    def test_cancel_before_submit_or_during_upload_does_not_send_more_audio(self):
        with tempfile.TemporaryDirectory() as folder:
            calls = []
            remote = SimpleNamespace(call=lambda method, *args, **kwargs: calls.append(method))
            run = Run(SimpleNamespace(meeting=folder, run_id="run"), remote)
            run.cancelled.set()
            with self.assertRaises(UploadCancelled):
                run.submit()
            self.assertEqual(calls, [])
            body = CancellableBody(io.BytesIO(b"audio"), run.cancelled)
            with self.assertRaises(UploadCancelled):
                body.read(5)

    def test_remote_process_group_ids_are_not_forwarded_to_mac(self):
        event = {"protocol_version": 1, "run_id": "run", "type": "completed",
                 "process_group_id": 123, "process_group_finished": True}

        class Response:
            status = 200
            def __init__(self): self.lines = [json.dumps(event).encode() + b"\n", b""]
            def readline(self): return self.lines.pop(0)

        class Connection:
            def request(self, *args): pass
            def getresponse(self): return Response()
            def close(self): pass

        remote = SimpleNamespace(connect=lambda **kwargs: Connection())
        run = Run(SimpleNamespace(meeting="/tmp", run_id="run"), remote)
        run.job = "job"
        run.pull = lambda: None
        output = SimpleNamespace(buffer=io.BytesIO(), flush=lambda: None)
        with patch("sys.stdout", output):
            code, terminal = run.relay()
            self.assertEqual(code, 0)
            run.emit_event(terminal)
        self.assertEqual(json.loads(output.buffer.getvalue()),
                         {"protocol_version": 1, "run_id": "run", "type": "completed"})

    def test_remote_outputs_cannot_follow_local_symlink(self):
        with tempfile.TemporaryDirectory() as folder, tempfile.TemporaryDirectory() as outside:
            root = Path(folder)
            (root / "work").symlink_to(outside)
            output = io.BytesIO()
            with tarfile.open(fileobj=output, mode="w") as archive:
                data = b"secret"
                info = tarfile.TarInfo("work/stolen.json")
                info.size = len(data)
                archive.addfile(info, io.BytesIO(data))
            with self.assertRaisesRegex(ValueError, "escapes"):
                apply_changes(root, output.getvalue())
            self.assertFalse((Path(outside) / "stolen.json").exists())

    def test_remote_output_cannot_replace_meeting_metadata(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "meeting.json").write_text("original")
            output = io.BytesIO()
            with tarfile.open(fileobj=output, mode="w") as archive:
                data = b"replacement"
                info = tarfile.TarInfo("meeting.json")
                info.size = len(data)
                archive.addfile(info, io.BytesIO(data))
            args = SimpleNamespace(run_id="run", revision_id="next", summary_id="notes",
                                   summary_only=False, transcript_first=True)
            with self.assertRaisesRegex(ValueError, "outside this processing run"):
                apply_changes(root, output.getvalue(), args)
            self.assertEqual((root / "meeting.json").read_text(), "original")

    def test_remote_voice_profile_is_kept_as_candidate_without_overwriting_local_profile(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "work/run").mkdir(parents=True)
            (root / "voice_profiles.json").write_text("local history")
            output = io.BytesIO()
            with tarfile.open(fileobj=output, mode="w") as archive:
                data = b"remote candidate"
                info = tarfile.TarInfo("voice_profiles.json")
                info.size = len(data)
                archive.addfile(info, io.BytesIO(data))
            args = SimpleNamespace(run_id="run", revision_id="next", summary_id="notes",
                                   summary_only=False, transcript_first=True)
            self.assertEqual(apply_changes(root, output.getvalue(), args), ["work/run/remote_voice_profiles.json"])
            self.assertEqual((root / "voice_profiles.json").read_text(), "local history")
            self.assertEqual((root / "work/run/remote_voice_profiles.json").read_bytes(), b"remote candidate")

    def test_remote_tar_is_fully_validated_before_replacing_any_file(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            output = io.BytesIO()
            with tarfile.open(fileobj=output, mode="w") as archive:
                for name in ("revisions/next/transcript.json", "z-other.json"):
                    data = name.encode()
                    info = tarfile.TarInfo(name)
                    info.size = len(data)
                    archive.addfile(info, io.BytesIO(data))
            args = SimpleNamespace(run_id="run", revision_id="next", summary_id="notes",
                                   summary_only=False, transcript_first=True)
            with self.assertRaisesRegex(ValueError, "outside this processing run"):
                apply_changes(root, output.getvalue(), args)
            self.assertFalse((root / "revisions/next/transcript.json").exists())

    def test_remote_voice_vector_matches_prior_meeting_locally(self):
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder)
            current = base / "00000000-0000-0000-0000-000000000001"
            prior = base / "00000000-0000-0000-0000-000000000002"
            (current / "work/run").mkdir(parents=True)
            (current / "revisions/next").mkdir(parents=True)
            prior.mkdir()
            (prior / "voice_profiles.json").write_text(json.dumps({"schema_version": 1,
                "meeting_id": prior.name, "revision_id": "old", "run_id": "old",
                "model_fingerprint": "f" * 64, "profiles": [{"speaker_id": "remote-001",
                    "voice_id": "a" * 32, "vector": [1.0, 0.0]}]}))
            (current / "revisions/next/transcript.json").write_text(json.dumps({"schema_version": 1,
                "meeting_id": current.name, "revision_id": "next", "run_id": "run",
                "speakers": [{"id": "remote-001", "source": "system"}]}))
            candidate = current / "work/run/remote_voice_profiles.json"
            candidate.write_text(json.dumps({"schema_version": 1, "meeting_id": current.name,
                "revision_id": "next", "run_id": "run", "model_fingerprint": "f" * 64,
                "profiles": [{"speaker_id": "remote-001", "voice_id": "b" * 32,
                              "vector": [0.9, 0.1]}]}))
            localize_profiles(current, candidate)
            saved = json.loads((current / "voice_profiles.json").read_text())
            self.assertEqual(saved["profiles"][0]["voice_id"], "a" * 32)
            localize_profiles(current, candidate)
            self.assertEqual(json.loads((current / "voice_profiles.json").read_text()), saved)

    def test_http_job_roundtrip_uploads_minimal_inputs_and_pulls_before_events(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            self.fixture(root)
            state = {"uploaded": None, "deleted": False, "cancelled": False, "delete_fail": False}
            output_tar = io.BytesIO()
            with tarfile.open(fileobj=output_tar, mode="w") as archive:
                data = b'{"schema_version":1}'
                info = tarfile.TarInfo("revisions/next/transcript.json")
                info.size = len(data)
                archive.addfile(info, io.BytesIO(data))

            class Handler(BaseHTTPRequestHandler):
                def log_message(self, *args): pass

                def reply(self, body, status=200):
                    self.send_response(status)
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)

                def do_GET(self):
                    if self.path == "/v1/health":
                        return self.reply(json.dumps({"ok": True, "worker_protocol": WORKER_PROTOCOL}).encode())
                    if self.path.endswith("/changes"):
                        return self.reply(output_tar.getvalue())
                    events = [dict(protocol_version=1, run_id="run", type="started"),
                              dict(protocol_version=1, run_id="run", type="stage_completed", stage="alignment",
                                   process_group_id=123, process_group_finished=True),
                              dict(protocol_version=1, run_id="run", type="completed")]
                    return self.reply(b"".join(json.dumps(event).encode() + b"\n" for event in events))

                def do_POST(self):
                    if self.path.endswith("/cancel"):
                        state["cancelled"] = True
                        return self.reply(b'{"cancelled":true}', 202)
                    body = self.rfile.read(int(self.headers["Content-Length"]))
                    with tarfile.open(fileobj=io.BytesIO(body)) as archive:
                        state["uploaded"] = archive.getnames()
                    self.reply(b'{"job":"00000000000000000000000000000000"}', 201)

                def do_DELETE(self):
                    if state["delete_fail"]:
                        return self.reply(b'{"error":"delete failed"}', 503)
                    state["deleted"] = True
                    self.reply(b'{"deleted":true}')

            server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                args = SimpleNamespace(meeting=str(root), run_id="run", revision_id="next", summary_id="notes",
                    language="auto", summary_only=False, transcript_first=True, progress_events=True,
                    allow_unknown_speakers=False, prepared="work/run/prepared.json",
                    names="work/run/names.json", summary_checkpoint=None)
                run = Run(args, Remote(f"http://127.0.0.1:{server.server_port}"))
                output = SimpleNamespace(buffer=io.BytesIO(), flush=lambda: None)
                read_fd, write_fd = os.pipe()
                try:
                    with os.fdopen(read_fd) as control, patch("sys.stdin", control), patch("sys.stdout", output):
                        self.assertEqual(run.run(), 0)
                finally:
                    os.close(write_fd)
                events = [json.loads(line) for line in output.buffer.getvalue().splitlines()]
                self.assertEqual([event["type"] for event in events], ["started", "stage_completed", "completed"])
                self.assertNotIn("process_group_id", events[1])
                self.assertTrue((root / "revisions/next/transcript.json").is_file())
                self.assertEqual(sorted(state["uploaded"]), ["meeting.json", "work/run/microphone.wav",
                    "work/run/names.json", "work/run/prepared.json"])
                self.assertTrue(state["deleted"])
                self.assertFalse(state["cancelled"])
                state["delete_fail"] = True
                state["deleted"] = False
                retry = Run(args, Remote(f"http://127.0.0.1:{server.server_port}"))
                retry_output = SimpleNamespace(buffer=io.BytesIO(), flush=lambda: None)
                read_fd, write_fd = os.pipe()
                try:
                    with os.fdopen(read_fd) as control, patch("sys.stdin", control), patch("sys.stdout", retry_output):
                        self.assertEqual(retry.run(), 1)
                finally:
                    os.close(write_fd)
                terminal = json.loads(retry_output.buffer.getvalue().splitlines()[-1])
                self.assertEqual((terminal["type"], terminal["code"]), ("failed", "remote_cleanup"))
                self.assertFalse(state["deleted"])
            finally:
                server.shutdown()
                server.server_close()
                thread.join()


if __name__ == "__main__":
    unittest.main()
