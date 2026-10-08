import contextlib
import io
import json
import subprocess
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
import wave

from afterword_worker.diarize import progress_hook
from afterword_worker.inference import transcribe
from afterword_worker.protocol import Cancelled, Control, WorkerError


class ProgressTests(unittest.TestCase):
    def test_legacy_control_emits_no_progress_without_opt_in(self):
        control = Control("run", watch_stdin=False)
        events = io.StringIO()
        with contextlib.redirect_stdout(events):
            control.begin("asr")
            control.progress(1, 2, "audio_windows", "windows")
        self.assertEqual([json.loads(line)["type"] for line in events.getvalue().splitlines()], ["stage_started"])

    def test_counts_keep_independent_phases_and_suppress_duplicates(self):
        control = Control("run", watch_stdin=False, progress_events=True)
        events = io.StringIO()
        with contextlib.redirect_stdout(events):
            control.begin("asr")
            control.progress(0, 2, "audio_windows", "windows")
            control.progress(0, 3, "speech_clips", "window_1")
            control.progress(3, 3, "speech_clips", "window_1")
            control.progress(1, 2, "audio_windows", "windows")
            control.progress(1, 2, "audio_windows", "windows")
        progress = [json.loads(line) for line in events.getvalue().splitlines() if json.loads(line)["type"] == "stage_progress"]
        self.assertEqual([item["completed"] for item in progress], [0, 0, 3, 1])

    def test_invalid_counts_units_phases_regression_and_late_updates_fail(self):
        values = [(True, 2, "audio_windows", "windows"), (0, False, "audio_windows", "windows"),
                  (0, 0, "audio_windows", "windows"), (-1, 2, "audio_windows", "windows"),
                  (3, 2, "audio_windows", "windows"), (1, 1_000_000_001, "audio_windows", "windows"),
                  (1, 2, "note_groups", "windows"), (1, 2, [], "windows"), (1, 2, "audio_windows", []),
                  (1, 2, "audio_windows", "bad phase"), (0, 2, "audio_windows", "windows"),
                  (2, 3, "audio_windows", "windows")]
        for value in values:
            with self.subTest(value=value), contextlib.redirect_stdout(io.StringIO()):
                control = Control("run", watch_stdin=False, progress_events=True)
                control.begin("asr")
                control.progress(1, 2, "audio_windows", "windows")
                with self.assertRaises(WorkerError):
                    control.progress(*value)
        for event in ("stage_completed", "completed"):
            with contextlib.redirect_stdout(io.StringIO()):
                control = Control("run", watch_stdin=False, progress_events=True)
                control.begin("asr")
                control.emit(event, stage="asr")
                with self.assertRaises(WorkerError):
                    control.progress(1, 2, "audio_windows", "windows")

    def test_native_fragmented_lines_and_final_buffer_are_forwarded_without_text(self):
        with tempfile.TemporaryDirectory() as folder, contextlib.redirect_stdout(io.StringIO()):
            received = []
            control = Control("run", watch_stdin=False)
            script = "import os,time; os.write(1,b'{\\\"n\\\":'); time.sleep(.05); os.write(1,b'1}\\n{\\\"n\\\":2}\\n')"
            output = Path(folder) / "native.stdout"
            control.run([sys.executable, "-c", script], output, line_callback=received.append)
            self.assertEqual(received, [{"n": 1}, {"n": 2}])
            self.assertEqual(output.read_text(), '{"n":1}\n{"n":2}\n')

    def test_malformed_oversized_unterminated_and_flooded_native_lines_fail_with_cleanup(self):
        scripts = ["print('not JSON')", "print('['+' '*9000+']')", "print('{}',end='')",
                   "import time; print('['*2000+']'*2000,flush=True); time.sleep(30)",
                   "import sys; sys.stdout.write('{}\\n'*10000); sys.stdout.flush()"]
        for script in scripts:
            with self.subTest(script=script), tempfile.TemporaryDirectory() as folder:
                control = Control("run", watch_stdin=False)
                events = io.StringIO()
                with contextlib.redirect_stdout(events), self.assertRaises(WorkerError):
                    control.run([sys.executable, "-c", script], Path(folder) / "native.stdout", line_callback=lambda _: None)
                values = [json.loads(line) for line in events.getvalue().splitlines()]
                self.assertTrue(values[-1]["process_group_finished"])

    def test_stdout_reader_failure_stops_and_cleans_up_native_process(self):
        original = subprocess.Popen
        class BrokenReader:
            def __init__(self, stream):
                self.stream = stream
            def read1(self, _):
                raise OSError("Fixture pipe failure")
            def close(self):
                self.stream.close()
        def start(*args, **kwargs):
            process = original(*args, **kwargs)
            process.stdout = BrokenReader(process.stdout)
            return process
        with tempfile.TemporaryDirectory() as folder:
            events = io.StringIO()
            with contextlib.redirect_stdout(events), patch("afterword_worker.protocol.subprocess.Popen", side_effect=start), self.assertRaisesRegex(WorkerError, "read native output"):
                Control("run", watch_stdin=False).run([sys.executable, "-c", "import time; time.sleep(30)"],
                    Path(folder) / "native.stdout", line_callback=lambda _: None)
            self.assertTrue(json.loads(events.getvalue().splitlines()[-1])["process_group_finished"])

    def test_native_callback_failure_and_cancellation_still_reap_child(self):
        for cancel in (False, True):
            with self.subTest(cancel=cancel), tempfile.TemporaryDirectory() as folder:
                control = Control("run", watch_stdin=False)
                def callback(_):
                    if cancel:
                        control.cancelled.set()
                    else:
                        raise WorkerError("native_protocol", "Unexpected fixture identity")
                events = io.StringIO()
                with contextlib.redirect_stdout(events), self.assertRaises(Cancelled if cancel else WorkerError):
                    control.run([sys.executable, "-c", "import time; print('{}',flush=True); time.sleep(30)"],
                                Path(folder) / "native.stdout", line_callback=callback)
                values = [json.loads(line) for line in events.getvalue().splitlines()]
                self.assertTrue(values[-1]["process_group_finished"])

    def test_segmentation_overshoot_waits_for_final_artifact_and_never_serializes_payload(self):
        class PrivateArtifact:
            def __str__(self):
                raise AssertionError("Artifact must never be inspected")
        events = io.StringIO()
        with contextlib.redirect_stdout(events):
            hook = progress_hook()
            hook("segmentation", PrivateArtifact(), completed=0, total=34)
            hook("segmentation", PrivateArtifact(), completed=32, total=34)
            hook("segmentation", PrivateArtifact(), completed=64, total=34)
            self.assertEqual(len(events.getvalue().splitlines()), 2)
            hook("segmentation", PrivateArtifact())
            hook("speaker_counting", PrivateArtifact())
            hook("embeddings", PrivateArtifact(), completed=0, total=2)
            hook("embeddings", PrivateArtifact(), completed=1, total=2)
            hook("embeddings", PrivateArtifact(), completed=2, total=2)
            hook("embeddings", PrivateArtifact())
        values = [json.loads(line) for line in events.getvalue().splitlines()]
        self.assertEqual([value["completed"] for value in values], [0, 32, 34, 0, 1, 2])
        self.assertEqual(values[-1]["progress_unit"], "embedding_batches")

    def test_asr_reports_known_windows_and_validated_clips_without_changing_output(self):
        class NativeFixture(Control):
            def run(self, arguments, output, **_):
                if "--vad-model" in arguments:
                    output.write_text("Detected 1 speech segments:\nSpeech segment 0: start = 0.00, end = 10.00\n")
                else:
                    for index, argument in enumerate(arguments):
                        if argument == "--output-file":
                            Path(arguments[index + 1]).with_suffix(".json").write_text(json.dumps({
                                "model": {"multilingual": True}, "transcription": [{"text": "Chinese 中文", "offsets": {"from": 0, "to": 100}}]}))
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            with wave.open(str(root / "audio.wav"), "wb") as audio:
                audio.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
                audio.writeframes(b"\1\0" * 40000)
            prepared = {"sources": [{"source": "system", "relative_path": "audio.wav",
                                     "pieces": [{"sample_start": 0, "sample_end": 40000}]}]}
            runtime = {"vad_cli": "/vad", "vad_model": "/vad-model", "whisper_cli": "/whisper", "asr_model": "/asr-model"}
            events = io.StringIO()
            outputs = []
            with patch("afterword_worker.inference.WINDOW", 16000), patch("afterword_worker.inference.OVERLAP", 1600):
                for enabled in (False, True):
                    control = NativeFixture("run", watch_stdin=False, progress_events=enabled)
                    with contextlib.redirect_stdout(events):
                        control.begin("asr")
                        outputs.append(transcribe(control, root, root, prepared, runtime))
            self.assertEqual(outputs[0], outputs[1])
            values = [json.loads(line) for line in events.getvalue().splitlines() if json.loads(line)["type"] == "stage_progress"]
            windows = [value for value in values if value["progress_unit"] == "audio_windows"]
            self.assertEqual([(value["completed"], value["total"]) for value in windows], [(0, 3), (1, 3), (2, 3), (3, 3)])
            self.assertEqual({value["progress_phase"] for value in values if value["progress_unit"] == "speech_clips"},
                             {"window_1", "window_2", "window_3"})


if __name__ == "__main__":
    unittest.main()
