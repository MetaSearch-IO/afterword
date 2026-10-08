import json
from pathlib import Path
import tempfile
import unittest
import wave

from afterword_worker.artifacts import atomic_json, map_interval, relative, validate_prepared, validate_summary, validate_transcript
from afterword_worker.protocol import WorkerError


def transcript():
    return {"schema_version": 1, "run_id": "run", "meeting_id": "meeting", "revision_id": "revision",
            "speakers": [{"id": "local", "source": "microphone", "label": "You"}],
            "segments": [{"id": "seg-1", "source": "microphone", "start_us": 0, "end_us": 1000000,
                          "text": "I will send it tomorrow", "speaker_id": "local", "attribution_reason": "microphone", "overlap": False}],
            "coverage": [{"source": "microphone", "start_us": 0, "end_us": 1000000}], "warnings": []}


def summary():
    return {"schema_version": 1, "run_id": "run", "meeting_id": "meeting", "revision_id": "revision", "summary_id": "summary",
            "name_map_revision": "names", "covered_segment_ids": ["seg-1"], "overview": [], "discussion_points": [],
            "decisions": [], "open_questions": [], "action_items": [{"text": "I will send it tomorrow", "segment_ids": ["seg-1"],
              "owner_speaker_id": "local", "owner_evidence_segment_ids": ["seg-1"], "due_date": "tomorrow", "due_date_evidence_segment_ids": ["seg-1"]}]}


class ArtifactTests(unittest.TestCase):
    def test_mapping_splits_pause_and_preserves_asymmetric_start(self):
        pieces = [{"sample_start": 0, "sample_end": 16000, "meeting_start_us": 500000},
                  {"sample_start": 16000, "sample_end": 32000, "meeting_start_us": 3000000}]
        self.assertEqual(map_interval(8000, 24000, pieces), [(1000000, 1500000), (3000000, 3500000)])

    def test_immutable_publication_and_paths(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            atomic_json(root / "artifact.json", {"schema_version": 1})
            with self.assertRaises(WorkerError):
                atomic_json(root / "artifact.json", {})
            with self.assertRaises(WorkerError):
                relative(root, "../outside")
            (root / "link").symlink_to(root.parent)
            with self.assertRaises(WorkerError):
                relative(root, "link/outside")

    def test_prepared_exact_coverage(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            with wave.open(str(root / "audio.wav"), "wb") as audio:
                audio.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
                audio.writeframes(b"\0\0" * 160)
            value = {"schema_version": 1, "run_id": "run", "meeting_id": "meeting", "sample_rate": 16000,
                     "sources": [{"source": "microphone", "relative_path": "audio.wav", "pieces": [
                         {"sample_start": 0, "sample_end": 160, "meeting_start_us": 1000}]}]}
            validate_prepared(root, value, "run", "meeting")
            value["sources"][0]["pieces"][0]["sample_end"] = 161
            with self.assertRaises(WorkerError):
                validate_prepared(root, value, "run", "meeting")

    def test_invalid_revision_references_and_invented_date_fail(self):
        validate_transcript(transcript(), "meeting", "revision")
        validate_summary(summary(), transcript(), "summary")
        for mutation in (lambda s: s.update(revision_id="other"),
                         lambda s: s["action_items"][0].update(segment_ids=["missing"]),
                         lambda s: s["action_items"][0].update(due_date="2026-10-01"),
                         lambda s: s.update(covered_segment_ids=[])):
            value = summary()
            mutation(value)
            with self.assertRaises(WorkerError):
                validate_summary(value, transcript(), "summary")

    def test_transcript_cannot_cross_pause(self):
        value = transcript()
        value["coverage"][0]["end_us"] = 500000
        with self.assertRaises(WorkerError):
            validate_transcript(value, "meeting", "revision")

    def test_third_person_assignment_cannot_be_owned_by_its_speaker(self):
        source = transcript()
        source["segments"][0]["text"] = "小王负责测试麦克风录音。"
        value = summary()
        value["action_items"][0].update(text=source["segments"][0]["text"], due_date=None, due_date_evidence_segment_ids=[])
        with self.assertRaises(WorkerError):
            validate_summary(value, source, "summary")
        value["action_items"][0].update(owner_speaker_id=None, owner_evidence_segment_ids=[])
        validate_summary(value, source, "summary")


if __name__ == "__main__":
    unittest.main()
