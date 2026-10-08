import hashlib
import contextlib
import io
import json
from pathlib import Path
import sys
import tempfile
import threading
import time
import unittest

from afterword_worker.artifacts import NOTE_FIELDS
from afterword_worker.protocol import Cancelled, Control, WorkerError
from afterword_worker.summary import SummaryEngine, extraction_identity, summarize


def payload(prompt):
    return json.loads(prompt.split("<|im_start|>user\n", 1)[1].split("<|im_end|>", 1)[0])


def token_ids(prompt):
    seed = int(hashlib.sha256(prompt.encode()).hexdigest()[:6], 16) % 100_000
    return [seed] * (1000 + 2000 * len(payload(prompt)["items"]))


def response(prompt):
    data = payload(prompt)
    ids = []
    for item in data["items"]:
        ids.extend([item["id"]] if "id" in item else [ref for note in item["overview"] for ref in note["segment_ids"]])
    return {**{field: [] for field in (*NOTE_FIELDS, "action_items")},
            "overview": [{"text": "Source evidence", "segment_ids": [sid]} for sid in ids]}


class NativeBoundary:
    def __init__(self):
        self.batch_counts = []
        self.completion_prompts = []

    def check(self):
        pass

    def run(self, arguments, output, **kwargs):
        if arguments[0] == "/tokenize":
            prompt = Path(arguments[arguments.index("--file") + 1]).read_text()
            output.write_text(json.dumps(token_ids(prompt)))
        elif arguments[0] == "/completion":
            prompt = Path(arguments[arguments.index("--binary-file") + 1]).read_text()
            self.completion_prompts.append(prompt)
            output.write_text(json.dumps(response(prompt)))
        elif arguments[0] == "/batch":
            manifest = json.loads(Path(arguments[arguments.index("--manifest") + 1]).read_text())
            self.batch_counts.append(len(manifest["jobs"]))
            jobs = []
            for job in manifest["jobs"]:
                prompt = Path(job["prompt_path"]).read_text()
                path = Path(job["output_path"])
                data = json.dumps(response(prompt)).encode()
                path.write_bytes(data)
                Path(str(path) + ".tokens.json").write_text(json.dumps({"prompt": token_ids(prompt), "generated": [9999]}))
                jobs.append(dict(id=job["id"], stop_reason="eog", prompt_tokens=len(token_ids(prompt)), generated_tokens=1, output_bytes=len(data)))
            receipt = dict(schema_version=1, helper_version=1, mode="serial", parallel=1, context_per_sequence=8192,
                           temperature=0, seed=0, status="completed", jobs=list(reversed(jobs)))
            self.mutate(manifest, receipt)
            Path(manifest["receipt_path"]).write_text(json.dumps(receipt))
            output.write_text("{}\n")
        else:
            raise AssertionError("Unexpected native executable")

    def mutate(self, manifest, receipt):
        pass


class SummaryBatchTests(unittest.TestCase):
    def engine(self, root, control, enabled=True):
        return SummaryEngine(control, root, {"llama_tokenize": "/tokenize", "llama_completion": "/completion", "llama_summary_batch": "/batch",
                             "summary_model": "/model", "native": {"summary_batch": {"enabled": enabled, "version": 1}}})

    def transcript(self, count):
        return {"segments": [{"id": f"seg-{index:03d}", "text": f"Source point {index}", "speaker_id": None, "start_us": index}
                             for index in range(count)]}

    def test_live_job_progress_is_counted_and_corrupt_streams_fail_before_acceptance(self):
        for fault in (None, "unknown", "duplicate", "budget", "boolean", "prompt", "missing_terminal"):
            class Streaming(NativeBoundary):
                progress_enabled = True

                def __init__(self):
                    super().__init__()
                    self.events = Control("run", watch_stdin=False, progress_events=True)
                    self.events.begin("summary")

                def progress(self, *args, **kwargs):
                    self.events.progress(*args, **kwargs)

                def run(self, arguments, output, **kwargs):
                    super().run(arguments, output, **kwargs)
                    if arguments[0] != "/batch":
                        return
                    callback = kwargs["line_callback"]
                    manifest = json.loads(Path(arguments[arguments.index("--manifest") + 1]).read_text())
                    receipt = json.loads(Path(manifest["receipt_path"]).read_text())
                    indexed = {job["id"]: job for job in receipt["jobs"]}
                    for job in manifest["jobs"]:
                        value = indexed[job["id"]]
                        callback(dict(type="job_started", id=job["id"], prompt_tokens=value["prompt_tokens"]))
                        update = dict(type="job_completed", **value)
                        if fault == "unknown": update["id"] = "unexpected-job"
                        if fault == "budget": update["generated_tokens"] = job["n_predict"] + 1
                        if fault == "boolean": update["generated_tokens"] = True
                        if fault == "prompt": update["prompt_tokens"] += 1
                        callback(update)
                        if fault == "duplicate": callback(update)
                    if fault != "missing_terminal":
                        callback(dict(type="terminal", status="completed", jobs=len(manifest["jobs"])))

            with self.subTest(fault=fault), tempfile.TemporaryDirectory() as folder:
                root, events = Path(folder), io.StringIO()
                with contextlib.redirect_stdout(events):
                    control = Streaming()
                    if fault is None:
                        result = summarize(self.engine(root, control), self.transcript(6), {})
                        self.assertEqual(len(result["overview"]), 6)
                    else:
                        with self.assertRaises(WorkerError) as failure:
                            summarize(self.engine(root, control), self.transcript(6), {})
                        self.assertEqual(failure.exception.code, "native_protocol")
                        self.assertEqual(list(root.glob("extraction-*.json")), [])
                if fault is None:
                    updates = [json.loads(line) for line in events.getvalue().splitlines() if json.loads(line)["type"] == "stage_progress"]
                    self.assertEqual([value["completed"] for value in updates if value["progress_unit"] == "note_groups"], [0, 1, 2, 3])
                    self.assertTrue(any(value["progress_unit"] == "reduction_groups" for value in updates))

    def test_finite_serial_cohorts_keep_chronological_order_with_reordered_receipt(self):
        with tempfile.TemporaryDirectory() as folder:
            root, control = Path(folder), NativeBoundary()
            transcript = self.transcript(36)
            result = summarize(self.engine(root, control), transcript, {})
            self.assertEqual(control.batch_counts, [16, 2])
            self.assertEqual([note["segment_ids"][0] for note in result["overview"]], [segment["id"] for segment in transcript["segments"]])
            self.assertTrue(all(payload(prompt)["task"] == "reduce_chronological_notes" for prompt in control.completion_prompts))

    def test_only_budget_limited_and_invalid_json_jobs_get_one_cli_repair(self):
        class Incomplete(NativeBoundary):
            def mutate(self, manifest, receipt):
                indexed = {job["id"]: job for job in receipt["jobs"]}
                first, second = manifest["jobs"][:2]
                entry = indexed[first["id"]]
                entry.update(stop_reason="predict_limit", generated_tokens=first["n_predict"])
                tokens_path = Path(first["output_path"] + ".tokens.json")
                tokens = json.loads(tokens_path.read_text())
                tokens["generated"] = [9999] * first["n_predict"]
                tokens_path.write_text(json.dumps(tokens))
                Path(second["output_path"]).write_text("{")
                indexed[second["id"]]["output_bytes"] = 1
                receipt["status"] = "incomplete"
        with tempfile.TemporaryDirectory() as folder:
            root, control = Path(folder), Incomplete()
            result = summarize(self.engine(root, control), self.transcript(6), {})
            repairs = [prompt for prompt in control.completion_prompts if payload(prompt)["task"] == "extract_meeting_notes"]
            self.assertEqual(len(repairs), 2)
            self.assertTrue(all("Validation failed." in prompt for prompt in repairs))
            self.assertEqual([note["segment_ids"][0] for note in result["overview"]], [f"seg-{i:03d}" for i in range(6)])
            self.assertEqual(len(list(root.glob("extraction-*.json"))), 3)

    def test_receipt_binding_scope_and_swapped_outputs_fail_without_repair(self):
        for mode in ("version", "job_id", "prompt_swap", "raw_swap", "missing_output", "parallel_bool"):
            class Corrupt(NativeBoundary):
                def mutate(self, manifest, receipt):
                    first, second = manifest["jobs"][:2]
                    if mode == "version": receipt["schema_version"] = 2
                    elif mode == "job_id": receipt["jobs"][0]["id"] = "another-job"
                    elif mode == "parallel_bool": receipt["parallel"] = True
                    elif mode == "prompt_swap":
                        left = Path(first["output_path"] + ".tokens.json")
                        right = Path(second["output_path"] + ".tokens.json")
                        left_data, right_data = left.read_bytes(), right.read_bytes()
                        left.write_bytes(right_data)
                        right.write_bytes(left_data)
                    elif mode == "raw_swap":
                        left, right = Path(first["output_path"]), Path(second["output_path"])
                        left_data, right_data = left.read_bytes(), right.read_bytes()
                        left.write_bytes(right_data)
                        right.write_bytes(left_data)
                        for entry in receipt["jobs"]:
                            path = Path(next(job["output_path"] for job in manifest["jobs"] if job["id"] == entry["id"]))
                            entry["output_bytes"] = path.stat().st_size
                    elif mode == "missing_output": Path(first["output_path"]).unlink()
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as folder:
                root, control = Path(folder), Corrupt()
                with self.assertRaises(WorkerError) as failure:
                    summarize(self.engine(root, control), self.transcript(4), {})
                self.assertEqual(failure.exception.code, "native_protocol")
                self.assertEqual(control.completion_prompts, [])
                self.assertFalse(list(root.glob("extraction-*.json")))

    def test_native_execution_identity_changes_checkpoint_and_legacy_opt_in_is_exact(self):
        with tempfile.TemporaryDirectory() as folder:
            transcript, identities = self.transcript(2), []
            for index, enabled in enumerate((False, 1, True, True)):
                root = Path(folder) / str(index)
                root.mkdir()
                control = NativeBoundary()
                engine = self.engine(root, control, enabled=enabled)
                if index == 3: engine.runtime["native"]["summary_batch"]["source_tree"] = "different"
                models = {"summary_model": "hash", "llama_summary_batch": "helper-hash"}
                summarize(engine, transcript, {}, model_fingerprints=models)
                identities.append(json.loads((root / "summary-extraction.json").read_text())["identity"])
                self.assertEqual(bool(control.batch_counts), enabled is True)
            self.assertEqual(identities[0], extraction_identity(transcript, {}, models, 8192, 2048))
            self.assertEqual(identities[0], identities[1])
            self.assertNotEqual(identities[1], identities[2])
            self.assertNotEqual(identities[2], identities[3])

    def test_failed_repair_retains_good_siblings_without_second_repair_or_checkpoint(self):
        class FailedRepair(NativeBoundary):
            def mutate(self, manifest, receipt):
                first = manifest["jobs"][0]
                Path(first["output_path"]).write_text("{")
                next(entry for entry in receipt["jobs"] if entry["id"] == first["id"])["output_bytes"] = 1
            def run(self, arguments, output, **kwargs):
                if arguments[0] == "/completion":
                    self.completion_prompts.append(Path(arguments[arguments.index("--binary-file") + 1]).read_text())
                    output.write_text("{")
                else: super().run(arguments, output, **kwargs)
        with tempfile.TemporaryDirectory() as folder:
            root, control = Path(folder), FailedRepair()
            with self.assertRaises(WorkerError):
                summarize(self.engine(root, control), self.transcript(4), {}, model_fingerprints={"summary_model": "hash"})
            self.assertEqual(len(control.completion_prompts), 1)
            saved = [json.loads(path.read_text()) for path in root.glob("extraction-*.json")]
            self.assertEqual([item["covered_segment_ids"] for item in saved], [["seg-002", "seg-003"]])
            self.assertFalse((root / "summary-extraction.json").exists())

    def test_genuine_native_failure_never_falls_back_to_cli(self):
        class NativeFailure(NativeBoundary):
            def run(self, arguments, output, **kwargs):
                if arguments[0] == "/batch": raise WorkerError("native_exit", "Fixture native failure")
                super().run(arguments, output, **kwargs)
        with tempfile.TemporaryDirectory() as folder:
            root, control = Path(folder), NativeFailure()
            with self.assertRaises(WorkerError) as failure:
                summarize(self.engine(root, control), self.transcript(4), {})
            self.assertEqual(failure.exception.code, "native_exit")
            self.assertEqual(control.completion_prompts, [])
            self.assertFalse(list(root.glob("extraction-*.json")))

    def test_cancellation_stops_a_real_owned_cohort_process_without_repair(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            executable = root / "fixture-native"
            executable.write_text(f"#!{sys.executable}\nimport time\ntime.sleep(60)\n")
            executable.chmod(0o700)
            actual = Control("cancel-cohort", watch_stdin=False)
            class Boundary(NativeBoundary):
                def check(self): actual.check()
                def run(self, arguments, output, **kwargs):
                    if arguments[0] == str(executable): return actual.run(arguments, output, **kwargs)
                    return super().run(arguments, output, **kwargs)
            control = Boundary()
            engine = self.engine(root, control)
            engine.runtime["llama_summary_batch"] = str(executable)
            timer = threading.Timer(0.2, actual.cancelled.set)
            output, started = io.StringIO(), time.monotonic()
            timer.start()
            try:
                with contextlib.redirect_stdout(output), self.assertRaises(Cancelled):
                    summarize(engine, self.transcript(2), {})
            finally: timer.cancel()
            self.assertLess(time.monotonic() - started, 5)
            self.assertTrue(any(json.loads(line).get("process_group_finished") is True for line in output.getvalue().splitlines()))
            self.assertEqual(control.completion_prompts, [])
            self.assertFalse(list(root.glob("extraction-*.json")))

    def test_legacy_runtime_without_feature_keeps_existing_context_support(self):
        with tempfile.TemporaryDirectory() as folder:
            root, control = Path(folder), NativeBoundary()
            runtime = {"llama_tokenize": "/tokenize", "llama_completion": "/completion", "summary_model": "/model", "summary_context": 16384}
            engine = SummaryEngine(control, root, runtime)
            result = summarize(engine, self.transcript(2), {})
            self.assertEqual(control.batch_counts, [])
            self.assertEqual(len(result["overview"]), 2)
            runtime.update(llama_summary_batch="/batch", native={"summary_batch": {"enabled": True}})
            with self.assertRaisesRegex(WorkerError, "8192"):
                SummaryEngine(control, root, runtime)
