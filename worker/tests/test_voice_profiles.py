import json
from pathlib import Path
import tempfile
import unittest

from afterword_worker.voice_profiles import assign_profiles, load_prior_profiles, save_profiles, voice_label


class VoiceProfileTests(unittest.TestCase):
    def test_matches_prior_voice_and_keeps_distinct_current_speakers(self):
        prior_id = "a" * 32
        prior = [{"voice_id": prior_id, "vector": [1.0, 0.0, 0.0]}]
        ids = iter(["b" * 32, "c" * 32])
        result = assign_profiles("meeting", "revision", "run", "f" * 64,
                                 {"remote-001": [0.9, 0.1, 0.0], "remote-002": [0.0, 1.0, 0.0]},
                                 prior, make_id=lambda: next(ids))
        self.assertEqual([profile["voice_id"] for profile in result["profiles"]], [prior_id, "b" * 32])
        self.assertEqual(voice_label(prior_id), "Voice AAAAAAAA")
        self.assertAlmostEqual(sum(value * value for value in result["profiles"][0]["vector"]), 1.0)

    def test_ambiguous_match_gets_new_voice_id(self):
        prior = [{"voice_id": "a" * 32, "vector": [1.0, 0.0]},
                 {"voice_id": "b" * 32, "vector": [0.9, 0.1]}]
        result = assign_profiles("meeting", "revision", "run", "f" * 64,
                                 {"remote-001": [1.0, 0.0]}, prior, make_id=lambda: "c" * 32)
        self.assertEqual(result["profiles"][0]["voice_id"], "c" * 32)

    def test_prior_profiles_are_local_model_bound_and_skip_invalid_files(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            current = root / "00000000-0000-0000-0000-000000000001"
            valid = root / "00000000-0000-0000-0000-000000000002"
            invalid = root / "00000000-0000-0000-0000-000000000003"
            for path in (current, valid, invalid):
                path.mkdir()
            payload = {"schema_version": 1, "meeting_id": valid.name, "revision_id": "revision", "run_id": "run",
                       "model_fingerprint": "f" * 64,
                       "profiles": [{"speaker_id": "remote-001", "voice_id": "a" * 32,
                                     "vector": [1.0, 0.0]}]}
            (valid / "voice_profiles.json").write_text(json.dumps(payload))
            payload["meeting_id"] = invalid.name
            payload["profiles"][0]["vector"] = [0.0, 0.0]
            (invalid / "voice_profiles.json").write_text(json.dumps(payload))
            profiles = load_prior_profiles(current, "f" * 64, dimension=2)
            self.assertEqual(profiles, [{"voice_id": "a" * 32, "vector": [1.0, 0.0]}])

    def test_profile_replacement_is_atomic_and_rejects_symlink(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            payload = {"schema_version": 1, "profiles": []}
            save_profiles(root, payload)
            self.assertEqual(json.loads((root / "voice_profiles.json").read_text()), payload)
            save_profiles(root, {**payload, "revision_id": "new"})
            self.assertEqual(json.loads((root / "voice_profiles.json").read_text())["revision_id"], "new")
            (root / "voice_profiles.json").unlink()
            (root / "voice_profiles.json").symlink_to(root / "outside")
            with self.assertRaises(ValueError):
                save_profiles(root, payload)

    def test_reprocessing_retains_prior_voice_vector(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            base = {"schema_version": 1, "meeting_id": "meeting", "model_fingerprint": "f" * 64}
            old = {**base, "revision_id": "old", "profiles": [
                {"speaker_id": "remote-001", "voice_id": "a" * 32, "vector": [1.0, 0.0]}]}
            new = {**base, "revision_id": "new", "profiles": [
                {"speaker_id": "remote-001", "voice_id": "b" * 32, "vector": [0.0, 1.0]}]}
            save_profiles(root, old)
            save_profiles(root, new)
            saved = json.loads((root / "voice_profiles.json").read_text())
            self.assertEqual(saved["profiles"], new["profiles"])
            self.assertEqual(saved["retained"], [{"voice_id": "a" * 32, "vector": [1.0, 0.0]}])
