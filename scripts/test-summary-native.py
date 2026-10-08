#!/usr/bin/env python3
"""Model-free preflight checks for a built serial summary helper."""

import argparse
import json
from pathlib import Path
import subprocess
import tempfile
import unittest


class NativeSummaryTests(unittest.TestCase):
    binary: Path

    def test_help_has_no_parallel_option(self):
        result = subprocess.run([str(self.binary), "--help"], capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0)
        self.assertIn("--manifest", result.stdout)
        self.assertNotIn("--parallel", result.stdout)

    def test_parallel_option_is_rejected(self):
        result = subprocess.run([str(self.binary), "--model", "/unused", "--manifest", "/unused", "--parallel", "1"],
                                capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(json.loads(result.stdout)["status"], "failed")

    def test_invalid_manifest_exits_before_model_loading_and_preserves_existing_files(self):
        modes = ("empty", "too_many", "duplicate", "budget", "fractional_budget", "existing", "fractional_version")
        for mode in modes:
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as folder:
                root = Path(folder)
                (root / "model").write_bytes(b"Not a model; preflight must not load it")
                (root / "prompt").write_text("Synthetic preflight fixture")
                (root / "schema").write_text('{"type":"object"}')
                job = {"id": "one", "prompt_path": str(root / "prompt"), "schema_path": str(root / "schema"),
                       "output_path": str(root / "output"), "n_predict": 128}
                jobs = [job]
                if mode == "empty":
                    jobs = []
                elif mode == "too_many":
                    jobs = [job] * 17
                elif mode == "duplicate":
                    jobs = [job, {**job, "id": "two"}]
                elif mode == "budget":
                    job["n_predict"] = 9000
                elif mode == "fractional_budget":
                    job["n_predict"] = 1.5
                elif mode == "existing":
                    (root / "output").write_text("Retain me")
                manifest = {"schema_version": 1.0 if mode == "fractional_version" else 1,
                            "jobs": jobs, "receipt_path": str(root / "receipt.json")}
                (root / "manifest.json").write_text(json.dumps(manifest))
                result = subprocess.run([str(self.binary), "--model", str(root / "model"),
                                         "--manifest", str(root / "manifest.json")],
                                        capture_output=True, text=True, timeout=5)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(json.loads(result.stdout)["status"], "failed")
                self.assertNotIn("llama_model_load", result.stderr)
                self.assertFalse((root / "output.tokens.json").exists())
                if mode == "existing":
                    self.assertEqual((root / "output").read_text(), "Retain me")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    args = parser.parse_args()
    NativeSummaryTests.binary = args.binary.resolve(strict=True)
    unittest.main(argv=[__file__], verbosity=2)
