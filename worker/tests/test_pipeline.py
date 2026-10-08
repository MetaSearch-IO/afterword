import argparse
import contextlib
import io
import json
import hashlib
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import wave

from afterword_worker.artifacts import NOTE_FIELDS, validate_transcript
from afterword_worker.pipeline import process, runtime_hashes, summary_checkpoint
from afterword_worker.protocol import Cancelled, Control, WorkerError
from afterword_worker.summary import extraction_identity, validate_extraction_checkpoint


class PipelineTests(unittest.TestCase):
    def test_broken_unrelated_work_entry_cannot_block_summary_retry(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            work = root / "work/current"
            work.mkdir(parents=True)
            (root / "work/broken-old-run").symlink_to(root / "missing")
            (root / "work/not-a-run").write_text("unrelated file")
            engine = SimpleNamespace(context=8192, reserve=2048, execution_identity=None)
            self.assertIsNone(summary_checkpoint(root, work, {"segments": []}, {}, {}, engine,
                                                  Control("run", watch_stdin=False)))

    def test_summary_retry_recovers_complete_native_groups_without_rerunning_extraction(self):
        for fault in (None, "incomplete", "different_model", "different_names"):
            with self.subTest(fault=fault), tempfile.TemporaryDirectory() as folder:
                root = Path(folder)
                args = self.fixture(root)
                runtime = json.loads((root / "runtime.json").read_text())
                runtime.update(llama_summary_batch=sys.executable, native={"summary_batch": {"enabled": True, "helper_version": 1}})
                (root / "runtime.json").write_text(json.dumps(runtime))
                notes = {field: [] for field in ("overview", "discussion_points", "decisions", "action_items", "open_questions")}
                segments = [{"source": "microphone", "sample_start": 0, "sample_end": 8000, "text": "Hello 中文"},
                            {"source": "microphone", "sample_start": 8000, "sample_end": 16000, "text": "Follow-up"}]
                def interrupted(engine, transcript, names, **options):
                    identity = extraction_identity(transcript, names, options["model_fingerprints"],
                                                   engine.context, engine.reserve, engine.execution_identity)
                    if fault == "different_model": identity["models"] = {"summary_model": "wrong"}
                    if fault == "different_names": identity["names"] = "wrong"
                    for index, segment in enumerate(transcript["segments"]):
                        if fault == "incomplete" and index == 1: continue
                        receipt = {"schema_version": 1, "kind": "summary_extraction_group", "identity": identity,
                                   "covered_segment_ids": [segment["id"]], "notes": notes}
                        (engine.work / f"extraction-summary-{index}.json").write_text(json.dumps(receipt))
                    raise WorkerError("native_exit", "Interrupted before aggregate checkpoint")
                with contextlib.redirect_stdout(io.StringIO()), patch("afterword_worker.pipeline.transcribe", return_value=segments), \
                     patch("afterword_worker.pipeline.summarize", side_effect=interrupted), self.assertRaises(WorkerError):
                    process(args, Control(args.run_id, watch_stdin=False))
                old_receipts = {p.name: p.read_bytes() for p in (root / "work/run1").glob("extraction-*.json")}
                args.run_id, args.summary_id, args.summary_only, args.prepared = "run2", "summary2", True, None
                def resumed(engine, transcript, names, **options):
                    checkpoint = options["checkpoint_path"]
                    if fault:
                        self.assertIsNone(checkpoint)
                    else:
                        self.assertIsNotNone(checkpoint)
                        identity = extraction_identity(transcript, names, options["model_fingerprints"],
                                                       engine.context, engine.reserve, engine.execution_identity)
                        groups = validate_extraction_checkpoint(json.loads(checkpoint.read_text()), transcript, identity)
                        self.assertEqual(len(groups), 2)
                    return notes
                with contextlib.redirect_stdout(io.StringIO()), patch("afterword_worker.pipeline.summarize", side_effect=resumed):
                    process(args, Control(args.run_id, watch_stdin=False))
                self.assertEqual(old_receipts, {p.name: p.read_bytes() for p in (root / "work/run1").glob("extraction-*.json")})
                summary = json.loads((root / "revisions/revision1/summaries/summary2.json").read_text())
                self.assertEqual(summary["summary_policy"]["extraction_reused"], fault is None)

    def test_enabled_summary_helper_is_fingerprinted_and_protocol_failure_cannot_publish(self):
        for failing in (False, True):
            with self.subTest(failing=failing), tempfile.TemporaryDirectory() as folder:
                root = Path(folder)
                args = self.fixture(root)
                runtime_path = root / "runtime.json"
                runtime = json.loads(runtime_path.read_text())
                runtime.update(llama_summary_batch=sys.executable, native={"summary_batch": {"enabled": True, "helper_version": 1}})
                runtime_path.write_text(json.dumps(runtime))
                original = (root / "meeting.json").read_bytes()
                segments = [{"source": "microphone", "sample_start": 0, "sample_end": 16000, "text": "Plan the release"}]
                notes = {key: [] for key in (*NOTE_FIELDS, "action_items")}
                def summary(engine, transcript, names, **options):
                    self.assertTrue(engine.serial_map_enabled)
                    self.assertIn("llama_summary_batch", options["model_fingerprints"])
                    if failing:
                        raise WorkerError("native_protocol", "Fixture receipt identity mismatch")
                    return notes
                with contextlib.redirect_stdout(io.StringIO()), patch("afterword_worker.pipeline.transcribe", return_value=segments), \
                     patch("afterword_worker.pipeline.summarize", side_effect=summary):
                    if failing:
                        with self.assertRaisesRegex(WorkerError, "receipt identity"):
                            process(args, Control(args.run_id, watch_stdin=False))
                    else:
                        process(args, Control(args.run_id, watch_stdin=False))
                revision = root / "revisions/revision1"
                self.assertTrue((revision / "transcript.json").is_file())
                result = revision / "summaries/summary1.json"
                self.assertEqual(result.exists(), not failing)
                if not failing:
                    artifact = json.loads(result.read_text())
                    self.assertIn("llama_summary_batch", artifact["runtime_fingerprints"])
                    self.assertEqual(artifact["summary_policy"]["map_execution"]["mode"], "serial_shared_model")
                self.assertEqual((root / "meeting.json").read_bytes(), original)

    def fixture(self, root, silent=False, remote=False):
        work = root / "work/run1"
        work.mkdir(parents=True)
        meeting = {"schema_version": 1, "id": "meeting", "capture_state": "stopped", "chunks": []}
        (root / "meeting.json").write_text(json.dumps(meeting))
        (root / "model").write_bytes(b"fixture")
        runtime = {"schema_version": 1, **{key: sys.executable for key in ("python", "whisper_cli", "vad_cli", "llama_completion", "llama_tokenize")},
                   **{key: str(root / "model") for key in ("asr_model", "vad_model", "summary_model")}}
        (root / "runtime.json").write_text(json.dumps(runtime))
        with wave.open(str(work / "microphone.wav"), "wb") as audio:
            audio.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
            audio.writeframes((b"\0\0" if silent else b"\0\1") * 16000)
        prepared = {"schema_version": 1, "run_id": "run1", "meeting_id": "meeting", "sample_rate": 16000,
                    "sources": [{"source": "microphone", "relative_path": "work/run1/microphone.wav", "pieces": [
                        {"sample_start": 0, "sample_end": 16000, "meeting_start_us": 0}]}]}
        if remote:
            prepared["sources"].append({**prepared["sources"][0], "source": "system"})
        (work / "prepared.json").write_text(json.dumps(prepared))
        return argparse.Namespace(meeting=str(root), runtime=str(root / "runtime.json"), run_id="run1", revision_id="revision1",
                                  summary_id="summary1", prepared="work/run1/prepared.json", summary_only=False, names=None)

    def test_transcript_first_survives_missing_or_invalid_model_native_failure_and_cancel(self):
        for failure in ("missing", "integrity", "native", "cancel"):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as folder:
                root = Path(folder)
                args = self.fixture(root, remote=True)
                args.transcript_first = True
                segments = [{"source": "microphone", "sample_start": 0, "sample_end": 8000, "text": "Local speech"},
                            {"source": "system", "sample_start": 8000, "sample_end": 16000, "text": "远程 speech"}]
                if failure == "integrity":
                    model_root = root / "diarization"
                    model_root.mkdir()
                    (model_root / "weights").write_bytes(b"changed")
                    runtime = json.loads((root / "runtime.json").read_text())
                    runtime.update(diarization_model=str(model_root), models={"diarization": {"files": [
                        {"path": str(model_root / "weights"), "sha256": "incorrect"}]}})
                    (root / "runtime.json").write_text(json.dumps(runtime))
                published = {}
                class PreviewControl(Control):
                    def emit(self, kind, **fields):
                        super().emit(kind, **fields)
                        if kind == "stage_completed" and fields.get("stage") == "transcript":
                            for key in ("transcript_path", "provenance_path"):
                                published[key] = (root / fields[key]).read_bytes()
                            published["event"] = fields
                            if failure == "cancel":
                                self.cancelled.set()
                events = io.StringIO()
                with contextlib.ExitStack() as stack:
                    stack.enter_context(contextlib.redirect_stdout(events))
                    asr = stack.enter_context(patch("afterword_worker.pipeline.transcribe", return_value=segments))
                    if failure == "native":
                        def failed_diarize(*_, **__):
                            self.assertIn("event", published)
                            raise WorkerError("native_exit", "Diarization failed")
                        stack.enter_context(patch("afterword_worker.pipeline.diarize", side_effect=failed_diarize))
                    with self.assertRaises(Cancelled if failure == "cancel" else WorkerError):
                        process(args, PreviewControl(args.run_id, watch_stdin=False))
                    asr.assert_called_once()
                preview = root / "revisions/run1"
                transcript = validate_transcript(json.loads((preview / "transcript.json").read_text()), "meeting", "run1")
                provenance = json.loads((preview / "provenance.json").read_text())
                self.assertEqual(provenance["diarization_mode"], "deferred")
                self.assertEqual(provenance["diarization_status"], "pending")
                self.assertEqual(published["event"]["revision_id"], "run1")
                self.assertEqual(published["event"]["input_fingerprint"], provenance["input_fingerprint"])
                self.assertEqual(published["event"]["artifacts"], ["revisions/run1/transcript.json", "revisions/run1/provenance.json"])
                self.assertEqual(transcript["segments"][0]["speaker_id"], "local")
                self.assertIsNone(transcript["segments"][1]["speaker_id"])
                self.assertEqual(transcript["segments"][1]["attribution_reason"], "speaker_labeling_pending")
                for key, filename in (("transcript_path", "transcript.json"), ("provenance_path", "provenance.json")):
                    self.assertEqual((preview / filename).read_bytes(), published[key])
                self.assertTrue((root / "work/run1/asr.json").is_file())
                self.assertFalse((root / "revisions/revision1").exists())

    def test_transcript_first_final_revision_preserves_preview_and_evidence_then_summary_retry(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            args = self.fixture(root, remote=True)
            args.transcript_first = True
            segments = [{"source": "system", "sample_start": 8000, "sample_end": 16000, "text": "远程 speech"},
                        {"source": "microphone", "sample_start": 0, "sample_end": 8000, "text": "Local speech"}]
            turn = {"sample_start": 0, "sample_end": 16000, "speaker": "A"}
            preview_bytes = {}
            def label_speakers(*_, **__):
                for name in ("transcript.json", "provenance.json"):
                    preview_bytes[name] = (root / "revisions/run1" / name).read_bytes()
                return {"regular": [turn], "exclusive": [turn], "mode": "community1", "status": "completed"}
            notes = {key: [] for key in (*NOTE_FIELDS, "action_items")}
            events = io.StringIO()
            with contextlib.redirect_stdout(events), patch("afterword_worker.pipeline.transcribe", return_value=segments) as asr, \
                 patch("afterword_worker.pipeline.diarize", side_effect=label_speakers) as diarization, \
                 patch("afterword_worker.pipeline.summarize", return_value=notes):
                process(args, Control(args.run_id, watch_stdin=False))
                asr.assert_called_once()
                diarization.assert_called_once()
            preview = json.loads(preview_bytes["transcript.json"])
            final_path = root / "revisions/revision1/transcript.json"
            final_bytes = final_path.read_bytes()
            final = validate_transcript(json.loads(final_bytes), "meeting", "revision1")
            keys = ("id", "source", "start_us", "end_us", "text")
            self.assertEqual([{key: segment[key] for key in keys} for segment in preview["segments"]],
                             [{key: segment[key] for key in keys} for segment in final["segments"]])
            self.assertEqual(final["segments"][1]["speaker_id"], "remote-001")
            for name, content in preview_bytes.items():
                self.assertEqual((root / "revisions/run1" / name).read_bytes(), content)
            published = [event for line in events.getvalue().splitlines() for event in [json.loads(line)]
                         if event["type"] == "stage_completed" and event.get("transcript_path")]
            self.assertEqual([(event["stage"], event["revision_id"]) for event in published], [("transcript", "run1"), ("alignment", "revision1")])
            args.run_id, args.summary_id, args.summary_only, args.prepared = "run2", "summary2", True, None
            with contextlib.redirect_stdout(io.StringIO()), patch("afterword_worker.pipeline.transcribe") as asr, \
                 patch("afterword_worker.pipeline.diarize") as diarization, patch("afterword_worker.pipeline.summarize", return_value=notes):
                process(args, Control(args.run_id, watch_stdin=False))
                asr.assert_not_called()
                diarization.assert_not_called()
            self.assertFalse((root / "revisions/run2").exists())
            self.assertEqual(final_path.read_bytes(), final_bytes)

    def test_transcript_first_rejects_colliding_or_existing_preview_before_asr(self):
        for collision in ("same_id", "existing"):
            with self.subTest(collision=collision), tempfile.TemporaryDirectory() as folder:
                root = Path(folder)
                args = self.fixture(root, remote=True)
                args.transcript_first = True
                if collision == "same_id":
                    args.revision_id = args.run_id
                else:
                    (root / "revisions/run1").mkdir(parents=True)
                    (root / "revisions/run1/retained").write_bytes(b"unchanged")
                with patch("afterword_worker.pipeline.transcribe") as asr, self.assertRaises(WorkerError):
                    process(args, Control(args.run_id, watch_stdin=False))
                asr.assert_not_called()
                self.assertFalse((root / "work/run1/.worker-started").exists())
                if collision == "existing":
                    self.assertEqual((root / "revisions/run1/retained").read_bytes(), b"unchanged")

    def test_transcript_first_local_only_publishes_only_final_revision(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            args = self.fixture(root)
            args.transcript_first = True
            segments = [{"source": "microphone", "sample_start": 0, "sample_end": 16000, "text": "Local speech"}]
            notes = {key: [] for key in (*NOTE_FIELDS, "action_items")}
            with contextlib.redirect_stdout(io.StringIO()), patch("afterword_worker.pipeline.transcribe", return_value=segments), \
                 patch("afterword_worker.pipeline.summarize", return_value=notes):
                process(args, Control(args.run_id, watch_stdin=False))
            self.assertFalse((root / "revisions/run1").exists())
            self.assertTrue((root / "revisions/revision1/transcript.json").is_file())

    def test_transcript_survives_summary_failure_then_summary_only_retry(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            args = self.fixture(root)
            original = (root / "meeting.json").read_bytes()
            segments = [{"source": "microphone", "sample_start": 0, "sample_end": 16000, "text": "Plan the release"}]
            events = io.StringIO()
            with contextlib.redirect_stdout(events), patch("afterword_worker.pipeline.transcribe", return_value=segments), \
                 patch("afterword_worker.pipeline.summarize", side_effect=WorkerError("invalid_artifact", "Invalid model response")):
                with self.assertRaises(WorkerError):
                    process(args, Control(args.run_id, watch_stdin=False))
            transcript_path = root / "revisions/revision1/transcript.json"
            self.assertTrue(transcript_path.is_file())
            transcript_bytes = transcript_path.read_bytes()
            self.assertIn('"transcript_path"', events.getvalue())
            self.assertEqual((root / "meeting.json").read_bytes(), original)
            args.run_id, args.summary_id, args.summary_only, args.prepared = "run2", "summary2", True, None
            notes = {key: [] for key in (*NOTE_FIELDS, "action_items")}
            notes["overview"] = [{"text": "Release planning", "segment_ids": ["seg-000001"]}]
            with contextlib.redirect_stdout(io.StringIO()), patch("afterword_worker.pipeline.transcribe") as asr, \
                 patch("afterword_worker.pipeline.summarize", return_value=notes):
                process(args, Control(args.run_id, watch_stdin=False))
                asr.assert_not_called()
            self.assertEqual(transcript_path.read_bytes(), transcript_bytes)
            self.assertTrue((root / "revisions/revision1/summaries/summary2.json").is_file())
            self.assertEqual((root / "meeting.json").read_bytes(), original)
            with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(WorkerError):
                process(args, Control(args.run_id, watch_stdin=False))

    def test_cli_zero_exit_requires_published_transcript_and_terminal_event(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            args = self.fixture(root, silent=True)
            arguments = [sys.executable, "-m", "afterword_worker", "process"]
            for flag in ("meeting", "runtime", "run_id", "revision_id", "summary_id", "prepared"):
                arguments.extend(["--" + flag.replace("_", "-"), getattr(args, flag)])
            with tempfile.TemporaryFile() as output, tempfile.TemporaryFile() as errors:
                worker = subprocess.Popen(arguments, stdin=subprocess.PIPE, stdout=output, stderr=errors)
                try:
                    worker.wait(timeout=10)
                finally:
                    if worker.poll() is None:
                        worker.kill()
                        worker.wait(timeout=5)
                    worker.stdin.close()
                output.seek(0)
                errors.seek(0)
                events = [json.loads(line) for line in output.read().splitlines()]
                error = errors.read()
            self.assertEqual(worker.returncode, 0, error)
            self.assertEqual(events[-1]["type"], "completed")
            self.assertIsNone(events[-1]["summary_path"])
            self.assertTrue((root / events[-1]["transcript_path"]).is_file())

    def test_missing_remote_model_keeps_reusable_asr_without_publishing_revision(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            args = self.fixture(root)
            prepared_path = root / args.prepared
            prepared = json.loads(prepared_path.read_text())
            prepared["sources"][0]["source"] = "system"
            prepared_path.write_text(json.dumps(prepared))
            segments = [{"source": "system", "sample_start": 0, "sample_end": 16000, "text": "Remote speech"}]
            with contextlib.redirect_stdout(io.StringIO()), patch("afterword_worker.pipeline.transcribe", return_value=segments):
                with self.assertRaisesRegex(WorkerError, "Community-1"):
                    process(args, Control(args.run_id, watch_stdin=False))
            self.assertTrue((root / "work/run1/asr.json").is_file())
            self.assertFalse((root / "revisions/revision1").exists())
            self.assertFalse((root / "revisions/run1").exists())

    def test_full_regeneration_does_not_reuse_old_speaker_names(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            args = self.fixture(root)
            (root / "names.json").write_text(json.dumps({"schema_version": 1, "name_map_revision": "old", "speaker_names": {"remote-001": "Alice"}}))
            args.names = "names.json"
            with contextlib.redirect_stdout(io.StringIO()), self.assertRaisesRegex(WorkerError, "cannot reuse names"):
                process(args, Control(args.run_id, watch_stdin=False))

    def test_explicit_unknown_speaker_recovery_reuses_strict_run_asr(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            args = self.fixture(root)
            prepared_path = root / args.prepared
            prepared = json.loads(prepared_path.read_text())
            prepared["sources"][0]["source"] = "system"
            prepared_path.write_text(json.dumps(prepared))
            segments = [{"source": "system", "sample_start": 0, "sample_end": 16000, "text": "Remote speech"}]
            with contextlib.redirect_stdout(io.StringIO()), patch("afterword_worker.pipeline.transcribe", return_value=segments):
                with self.assertRaisesRegex(WorkerError, "Community-1"):
                    process(args, Control(args.run_id, watch_stdin=False))
            original_key = json.loads((root / "work/run1/asr.json").read_text())["input_fingerprint"]
            args.run_id, args.revision_id, args.summary_id = "run2", "revision2", "summary2"
            args.allow_unknown_speakers = True
            prepared["run_id"] = args.run_id
            (root / "work/run2").mkdir()
            (root / "work/run2/prepared.json").write_text(json.dumps(prepared))
            args.prepared = "work/run2/prepared.json"
            notes = {key: [] for key in (*NOTE_FIELDS, "action_items")}
            with contextlib.redirect_stdout(io.StringIO()), patch("afterword_worker.pipeline.transcribe") as asr, \
                 patch("afterword_worker.pipeline.summarize", return_value=notes):
                process(args, Control(args.run_id, watch_stdin=False))
                asr.assert_not_called()
            self.assertEqual(json.loads((root / "work/run2/asr.json").read_text())["input_fingerprint"], original_key)
            transcript = json.loads((root / "revisions/revision2/transcript.json").read_text())
            self.assertTrue(all(segment["speaker_id"] is None and segment["attribution_reason"] == "diarization_unavailable"
                                for segment in transcript["segments"]))
            self.assertTrue(any("Community-1" in warning for warning in transcript["warnings"]))
            provenance = json.loads((root / "revisions/revision2/provenance.json").read_text())
            self.assertEqual(provenance["diarization_mode"], "unknown_speakers")
            self.assertEqual(provenance["diarization_status"], "unavailable")

    def test_integrity_check_includes_implicit_model_shards(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            first, second = root / "model-1.gguf", root / "model-2.gguf"
            first.write_bytes(b"first")
            second.write_bytes(b"second")
            runtime = {"summary_model": str(first), "models": {"summary": {"files": [
                {"path": str(path), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()} for path in (first, second)]}}}
            hashes = runtime_hashes(runtime, ["summary_model"], Control("run", watch_stdin=False))
            self.assertIn("summary_model/model-2.gguf", hashes)
            second.write_bytes(b"changed")
            with self.assertRaisesRegex(WorkerError, "shard failed"):
                runtime_hashes(runtime, ["summary_model"], Control("run", watch_stdin=False))

    def test_changing_transcription_language_invalidates_asr_checkpoint(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            args = self.fixture(root, silent=True)
            args.language = "auto"
            with contextlib.redirect_stdout(io.StringIO()), patch("afterword_worker.pipeline.transcribe", return_value=[]):
                process(args, Control(args.run_id, watch_stdin=False))
            first = json.loads((root / "work/run1/asr.json").read_text())["input_fingerprint"]
            args.run_id, args.revision_id, args.summary_id, args.language = "run2", "revision2", "summary2", "zh"
            prepared = json.loads((root / "work/run1/prepared.json").read_text())
            prepared["run_id"] = args.run_id
            (root / "work/run2").mkdir()
            (root / "work/run2/prepared.json").write_text(json.dumps(prepared))
            args.prepared = "work/run2/prepared.json"
            with contextlib.redirect_stdout(io.StringIO()), patch("afterword_worker.pipeline.transcribe", return_value=[]) as asr:
                process(args, Control(args.run_id, watch_stdin=False))
                asr.assert_called_once()
                self.assertEqual(asr.call_args.kwargs["language"], "zh")
            second = json.loads((root / "work/run2/asr.json").read_text())["input_fingerprint"]
            self.assertNotEqual(first, second)
            provenance = json.loads((root / "revisions/revision2/provenance.json").read_text())
            self.assertEqual(provenance["asr_language"], "zh")

    def test_auto_language_policy_changes_cache_and_provenance_without_overriding_explicit_language(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            args = self.fixture(root, silent=True)
            runtime = json.loads((root / "runtime.json").read_text())
            prepared = json.loads((root / args.prepared).read_text())
            fingerprints = []
            for index, (enabled, language) in enumerate(((False, "auto"), (True, "auto"), (True, "zh")), 1):
                args.run_id, args.revision_id, args.summary_id, args.language = f"run{index}", f"revision{index}", f"summary{index}", language
                runtime["native"] = {"whisper": {"auto_language_en_zh": enabled}}
                (root / "runtime.json").write_text(json.dumps(runtime))
                prepared["run_id"] = args.run_id
                work = root / "work" / args.run_id
                work.mkdir(exist_ok=True)
                (work / "prepared.json").write_text(json.dumps(prepared))
                args.prepared = str((work / "prepared.json").relative_to(root))
                with contextlib.redirect_stdout(io.StringIO()), patch("afterword_worker.pipeline.transcribe", return_value=[]) as asr:
                    process(args, Control(args.run_id, watch_stdin=False))
                    asr.assert_called_once()
                    self.assertEqual(asr.call_args.kwargs["language"], language)
                provenance = json.loads((root / "revisions" / args.revision_id / "provenance.json").read_text())
                self.assertEqual(provenance["language_policy"], "per-utterance-auto-en-zh-preserve" if enabled and language == "auto"
                                 else f"per-utterance-{language}-preserve")
                fingerprints.append(json.loads((work / "asr.json").read_text())["input_fingerprint"])
            self.assertEqual(len(set(fingerprints)), 3)

    def test_encoder_reuse_metadata_changes_asr_cache_and_is_recorded(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            args = self.fixture(root, silent=True)
            runtime = json.loads((root / "runtime.json").read_text())
            prepared = json.loads((root / args.prepared).read_text())
            keys = []
            for index, enabled in enumerate((False, True), 1):
                args.run_id, args.revision_id, args.summary_id = f"run{index}", f"revision{index}", f"summary{index}"
                runtime["native"] = {"whisper": {"encoder_reuse": enabled}}
                (root / "runtime.json").write_text(json.dumps(runtime))
                if index == 2:
                    prepared["run_id"] = args.run_id
                    (root / "work/run2").mkdir()
                    (root / "work/run2/prepared.json").write_text(json.dumps(prepared))
                    args.prepared = "work/run2/prepared.json"
                with contextlib.redirect_stdout(io.StringIO()), patch("afterword_worker.pipeline.transcribe", return_value=[]) as asr:
                    process(args, Control(args.run_id, watch_stdin=False))
                    asr.assert_called_once()
                keys.append(json.loads((root / f"work/run{index}/asr.json").read_text())["input_fingerprint"])
                provenance = json.loads((root / f"revisions/revision{index}/provenance.json").read_text())
                self.assertIs(provenance["runtime"]["native"]["whisper"]["encoder_reuse"], enabled)
            self.assertNotEqual(*keys)

    def test_diarization_device_is_recorded_and_changes_revision_fingerprint_only(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            args = self.fixture(root)
            prepared = json.loads((root / args.prepared).read_text())
            prepared["sources"][0]["source"] = "system"
            (root / args.prepared).write_text(json.dumps(prepared))
            segments = [{"source": "system", "sample_start": 0, "sample_end": 16000, "text": "Remote speech"}]
            notes = {key: [] for key in (*NOTE_FIELDS, "action_items")}
            revisions, asr_keys = [], []
            for index, device in enumerate(("cpu", "mps"), 1):
                args.run_id, args.revision_id, args.summary_id = f"run{index}", f"revision{index}", f"summary{index}"
                if index == 2:
                    prepared["run_id"] = args.run_id
                    (root / "work/run2").mkdir()
                    (root / "work/run2/prepared.json").write_text(json.dumps(prepared))
                    args.prepared = "work/run2/prepared.json"
                execution = {"device": device, "segmentation_batch_size": 32, "embedding_batch_size": 32, "torch_num_threads": 12}
                turns = {"schema_version": 1, "regular": [], "exclusive": [], "mode": "community1", "status": "completed", "execution": execution}
                with contextlib.redirect_stdout(io.StringIO()), patch("afterword_worker.pipeline.transcribe", return_value=segments) as asr, \
                     patch("afterword_worker.pipeline.diarize", return_value=turns), patch("afterword_worker.pipeline.summarize", return_value=notes):
                    process(args, Control(args.run_id, watch_stdin=False))
                    if index == 2:
                        asr.assert_not_called()
                provenance = json.loads((root / f"revisions/revision{index}/provenance.json").read_text())
                self.assertEqual(provenance["diarization_execution"], execution)
                revisions.append(provenance["input_fingerprint"])
                asr_keys.append(json.loads((root / f"work/run{index}/asr.json").read_text())["input_fingerprint"])
            self.assertNotEqual(revisions[0], revisions[1])
            self.assertEqual(asr_keys[0], asr_keys[1])


if __name__ == "__main__":
    unittest.main()
