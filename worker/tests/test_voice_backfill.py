import json
from pathlib import Path
import tempfile
import unittest
import wave

from afterword_worker.voice_backfill import backfill_meeting


class VoiceBackfillTests(unittest.TestCase):
    def test_backfills_two_clean_turns_without_running_diarization(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder) / "00000000-0000-0000-0000-000000000001"
            work = root / "work/run"
            revision = root / "revisions/revision"
            work.mkdir(parents=True)
            revision.mkdir(parents=True)
            (root / "meeting.json").write_text(json.dumps({"schema_version": 1, "id": root.name,
                                                            "active_revision_id": "revision"}))
            (revision / "transcript.json").write_text(json.dumps({"schema_version": 1, "run_id": "run",
                                                                  "meeting_id": root.name}))
            (revision / "provenance.json").write_text(json.dumps({"schema_version": 1}))
            prepared = {"schema_version": 1, "run_id": "run", "meeting_id": root.name, "sample_rate": 16000,
                        "sources": [{"source": "system", "relative_path": "work/run/system.wav",
                                     "pieces": [{"sample_start": 0, "sample_end": 96000, "meeting_start_us": 0}]}]}
            (work / "prepared.json").write_text(json.dumps(prepared))
            turns = [{"sample_start": 0, "sample_end": 48000, "speaker": "A"},
                     {"sample_start": 48000, "sample_end": 96000, "speaker": "A"}]
            (work / "diarization.json").write_text(json.dumps({"schema_version": 1, "regular": turns,
                                                                 "exclusive": turns}))
            with wave.open(str(work / "system.wav"), "wb") as audio:
                audio.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
                audio.writeframes(b"\1\0" * 96000)
            runtime = {"models": {"diarization": {"files": [{"path": "/model/embedding/pytorch_model.bin",
                                                               "sha256": "f" * 64}]}}}
            calls = []
            def embed(raw):
                calls.append(len(raw))
                return [1.0, 0.0]
            result = backfill_meeting(root, runtime, embed, make_id=lambda: "a" * 32)
            self.assertEqual(calls, [96000, 96000])
            self.assertEqual(result["profiles"], [{"speaker_id": "remote-001", "voice_id": "a" * 32,
                                                   "vector": [1.0, 0.0]}])
            self.assertFalse((root / "voice_profiles.json").exists())
            corrected = root / "revisions/corrected"
            corrected.mkdir()
            (corrected / "transcript.json").write_text(json.dumps({"schema_version": 1, "run_id": "edit",
                                                                   "meeting_id": root.name}))
            (corrected / "provenance.json").write_text(json.dumps({"schema_version": 1,
                "speaker_corrections": [{"parent_revision_id": "revision"}]}))
            (root / "meeting.json").write_text(json.dumps({"schema_version": 1, "id": root.name,
                                                            "active_revision_id": "corrected"}))
            corrected_result = backfill_meeting(root, runtime, embed, make_id=lambda: "a" * 32)
            self.assertEqual(corrected_result["revision_id"], "revision")
            self.assertEqual(corrected_result["run_id"], "run")
