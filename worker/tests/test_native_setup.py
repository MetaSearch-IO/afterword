import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("setup_models", ROOT / "scripts/setup-models.py")
setup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(setup)


class NativeSetupTests(unittest.TestCase):
    def fixture(self, root):
        seed = root / "seed"
        seed.mkdir()
        subprocess.run(["git", "init", "-q", str(seed)], check=True)
        (seed / "source.cpp").write_text("before\n")
        (seed / ".gitignore").write_text("/bindings/javascript/package.json\n")
        subprocess.run(["git", "-C", str(seed), "add", "source.cpp", ".gitignore"], check=True)
        subprocess.run(["git", "-C", str(seed), "-c", "user.name=Fixture", "-c", "user.email=fixture@invalid",
                        "commit", "-qm", "Temporary test fixture"], check=True)
        commit = subprocess.check_output(["git", "-C", str(seed), "rev-parse", "HEAD"], text=True).strip()
        subprocess.run(["git", "-C", str(seed), "tag", "v-test"], check=True)
        original = root / ".cache/native/whisper" / commit / "source"
        original.parent.mkdir(parents=True)
        seed.rename(original)
        declared = root / "change.patch"
        declared.write_text("--- a/source.cpp\n+++ b/source.cpp\n@@ -1 +1 @@\n-before\n+after\n")
        return original, {"commit": commit, "tag": "v-test", "repository": "https://invalid.invalid/not-used",
                          "experimental_encoder_reuse": {"enabled": True, "base_commit": commit,
                                                         "path": "change.patch", "sha256": setup.sha256(declared)}}

    def test_exact_patch_repeat_setup_and_original_source_unchanged(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            original, entry = self.fixture(root)
            with patch.object(setup, "ROOT", root):
                source, build, first = setup.prepare_native_source("whisper", entry)
                again, same_build, second = setup.prepare_native_source("whisper", entry)
            self.assertEqual((source, build, first), (again, same_build, second))
            self.assertNotEqual(source, original)
            self.assertEqual(source.parent.name, first["variant"])
            self.assertEqual((source / "source.cpp").read_text(), "after\n")
            self.assertEqual((original / "source.cpp").read_text(), "before\n")
            self.assertEqual(subprocess.check_output(["git", "-C", str(original), "status", "--porcelain"]), b"")
            self.assertTrue(first["encoder_reuse"])
            self.assertEqual(first["patches"][0]["sha256"], entry["experimental_encoder_reuse"]["sha256"])

    def test_repeat_setup_allows_pinned_ignored_build_output(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            original, entry = self.fixture(root)
            with patch.object(setup, "ROOT", root):
                for enabled in (False, True):
                    selected = {**entry, "experimental_encoder_reuse": {
                        **entry["experimental_encoder_reuse"], "enabled": enabled}}
                    source, _, first = setup.prepare_native_source("whisper", selected)
                    generated = source / "bindings/javascript/package.json"
                    generated.parent.mkdir(parents=True)
                    generated.write_text('{"generated_by": "cmake"}')
                    _, _, second = setup.prepare_native_source("whisper", selected)
                    self.assertEqual(first, second)
                    self.assertTrue(generated.is_file())
                    if not enabled:
                        self.assertEqual(source, original)

    def test_language_policy_layers_pinned_patch_without_changing_encoder_variant(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            original, entry = self.fixture(root)
            policy = root / "language.patch"
            policy.write_text("--- a/source.cpp\n+++ b/source.cpp\n@@ -1 +1 @@\n-after\n+language-policy\n"
                              "--- /dev/null\n+++ b/language.h\n@@ -0,0 +1 @@\n+declared header\n")
            entry["automatic_language_policy"] = {"enabled": True, "base_commit": entry["commit"],
                                                   "path": "language.patch", "sha256": setup.sha256(policy)}
            with patch.object(setup, "ROOT", root):
                baseline, _, before = setup.prepare_native_source("whisper", {**entry, "automatic_language_policy": {"enabled": False}})
                source, build, metadata = setup.prepare_native_source("whisper", entry)
                self.assertEqual(setup.prepare_native_source("whisper", entry), (source, build, metadata))
            self.assertEqual((original / "source.cpp").read_text(), "before\n")
            self.assertEqual((baseline / "source.cpp").read_text(), "after\n")
            self.assertEqual((source / "source.cpp").read_text(), "language-policy\n")
            self.assertEqual((source / "language.h").read_text(), "declared header\n")
            self.assertNotEqual(before["variant"], metadata["variant"])
            self.assertTrue(metadata["auto_language_en_zh"])
            self.assertEqual([item["sha256"] for item in metadata["patches"]],
                             [entry["experimental_encoder_reuse"]["sha256"], entry["automatic_language_policy"]["sha256"]])

    def test_language_policy_rejects_bad_pin_type_and_missing_encoder_base(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            _, entry = self.fixture(root)
            policy = {"enabled": True, "base_commit": entry["commit"], "path": "change.patch", "sha256": "0" * 64}
            with patch.object(setup, "ROOT", root):
                for change in ({}, {"enabled": "true"}, {"base_commit": "0" * 40}):
                    with self.subTest(change=change), self.assertRaises(RuntimeError):
                        setup.prepare_native_source("whisper", {**entry, "automatic_language_policy": {**policy, **change}})
                with self.assertRaises(RuntimeError):
                    setup.prepare_native_source("whisper", {**entry, "experimental_encoder_reuse": {"enabled": False},
                                                             "automatic_language_policy": policy})

    def test_source_changes_outside_declared_patch_are_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            _, entry = self.fixture(root)
            with patch.object(setup, "ROOT", root):
                source, _, _ = setup.prepare_native_source("whisper", entry)
                extra = source / "extra.cpp"
                extra.write_text("unexpected")
                with self.assertRaisesRegex(RuntimeError, "differs"):
                    setup.prepare_native_source("whisper", entry)
                extra.unlink()
                (source / "source.cpp").write_text("after\nextra\n")
                with self.assertRaisesRegex(RuntimeError, "differs"):
                    setup.prepare_native_source("whisper", entry)

    def test_patch_integrity_base_and_enabled_type_are_checked(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            _, entry = self.fixture(root)
            with patch.object(setup, "ROOT", root):
                for key, value in [("sha256", "0" * 64), ("base_commit", "0" * 40), ("enabled", "true")]:
                    changed = {**entry, "experimental_encoder_reuse": {**entry["experimental_encoder_reuse"], key: value}}
                    with self.subTest(key=key), self.assertRaises(RuntimeError):
                        setup.prepare_native_source("whisper", changed)

    def test_manifest_patch_is_pinned_and_enabled(self):
        entry = json.loads((ROOT / "config/runtime-manifest.json").read_text())["native"]["whisper"]
        declared = entry["experimental_encoder_reuse"]
        self.assertIs(declared["enabled"], True)
        self.assertEqual(declared["base_commit"], entry["commit"])
        self.assertEqual(hashlib.sha256((ROOT / declared["path"]).read_bytes()).hexdigest(), declared["sha256"])

    def test_manifest_language_policy_patch_is_pinned(self):
        entry = json.loads((ROOT / "config/runtime-manifest.json").read_text())["native"]["whisper"]
        declared = entry["automatic_language_policy"]
        self.assertIs(type(declared["enabled"]), bool)
        self.assertEqual(declared["base_commit"], entry["commit"])
        self.assertEqual(setup.sha256(ROOT / declared["path"]), declared["sha256"])


    def test_summary_helper_source_is_pinned_and_enabled(self):
        entry = json.loads((ROOT / "config/runtime-manifest.json").read_text())["native"]["llama"]
        helper = entry["summary_batch"]
        self.assertIs(helper["enabled"], True)
        self.assertEqual(helper["base_commit"], entry["commit"])
        self.assertEqual(setup.sha256(ROOT / helper["source"]), helper["sha256"])

    def test_summary_helper_rejects_bad_pin_before_build(self):
        entry = json.loads((ROOT / "config/runtime-manifest.json").read_text())["native"]["llama"]
        helper = {**entry["summary_batch"], "enabled": True}
        with tempfile.TemporaryDirectory() as folder:
            for key, value in (("sha256", "0" * 64), ("base_commit", "0" * 40), ("enabled", "true")):
                with self.subTest(key=key), patch.object(setup, "run") as run, self.assertRaisesRegex(RuntimeError, "integrity"):
                    setup.build_summary_batch({**entry, "summary_batch": {**helper, key: value}}, Path(folder))
                run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
