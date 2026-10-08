#!/usr/bin/env python3
"""Explicit development provisioning; inspect never downloads or installs."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "config/runtime-manifest.json"
DEFAULT_HOME = Path.home() / "Library/Application Support/Afterword"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(8 * 1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def run(arguments: list[str], **kwargs) -> None:
    subprocess.run(arguments, check=True, **kwargs)


def atomic_json(path: Path, value: dict) -> None:
    temporary = path.with_suffix(".json.tmp")
    with temporary.open("w") as stream:
        os.chmod(temporary, 0o600)
        json.dump(value, stream, indent=2)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    temporary.replace(path)


def verify_file(path: Path, entry: dict) -> bool:
    return (path.is_file() and path.stat().st_size == entry["size"]
            and sha256(path) == entry["sha256"])


def download(model: dict, entry: dict, directory: Path) -> Path:
    directory.mkdir(parents=True, exist_ok=True)
    destination = directory / entry["name"]
    if destination.exists():
        if not verify_file(destination, entry):
            raise RuntimeError(f"Existing model failed integrity check: {destination}")
        return destination
    staging = destination.with_suffix(destination.suffix + ".part")
    if verify_file(staging, entry):
        staging.replace(destination)
        return destination
    url = (f"https://huggingface.co/{model['repository']}/resolve/"
           f"{model['revision']}/{entry['name']}")
    print(f"Downloading {entry['name']} ({entry['size']} bytes)", flush=True)
    run(["curl", "--fail", "--silent", "--show-error", "--location", "--retry", "5", "--retry-delay", "2",
         "--connect-timeout", "30", "--speed-limit", "1024", "--speed-time", "120",
         "--continue-at", "-", "--output", str(staging), url])
    if not verify_file(staging, entry):
        raise RuntimeError(f"Staged model failed integrity check: {staging}")
    staging.replace(destination)
    return destination


def prepare_native_source(name: str, entry: dict) -> tuple[Path, Path, dict]:
    reuse = entry.get("experimental_encoder_reuse", {})
    enabled = reuse.get("enabled", False)
    if type(enabled) is not bool or enabled and name != "whisper":
        raise RuntimeError("Invalid encoder reuse configuration")
    policy = entry.get("automatic_language_policy", {})
    policy_enabled = policy.get("enabled", False)
    if type(policy_enabled) is not bool or policy_enabled and (name != "whisper" or not enabled):
        raise RuntimeError("Automatic language policy requires the pinned encoder reuse base")
    patches = []
    variant = entry["commit"]
    for feature, selected, active in (("encoder-reuse", reuse, enabled), ("auto-en-zh", policy, policy_enabled)):
        if not active:
            continue
        patch = (ROOT / selected["path"]).resolve()
        if (not patch.is_relative_to(ROOT.resolve()) or selected.get("base_commit") != entry["commit"]
                or not patch.is_file() or sha256(patch) != selected.get("sha256")):
            raise RuntimeError(f"{feature} patch failed its pinned integrity check")
        patches.append((patch, selected))
        variant += "-" + feature + "-" + selected["sha256"]
    cache = ROOT / ".cache/native" / name / variant
    source = cache / "source"
    build = cache / "build"
    if not (source / ".git").exists():
        source.mkdir(parents=True, exist_ok=True)
        run(["git", "init", str(source)])
    remotes = subprocess.check_output(["git", "-C", str(source), "remote"], text=True).splitlines()
    if "origin" not in remotes:
        run(["git", "-C", str(source), "remote", "add", "origin", entry["repository"]])
    tag_present = subprocess.run(["git", "-C", str(source), "rev-parse", "--verify",
                                  f"refs/tags/{entry['tag']}"],
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
    if not tag_present:
        upstream = ROOT / ".cache/native" / name / entry["commit"] / "source"
        remote = str(upstream) if enabled and (upstream / ".git").exists() else "origin"
        run(["git", "-C", str(source), "fetch", "--depth", "1", remote,
             f"refs/tags/{entry['tag']}:refs/tags/{entry['tag']}"])
    commit = subprocess.check_output(
        ["git", "-C", str(source), "rev-parse", f"{entry['tag']}^{{commit}}"],
        text=True).strip()
    if commit != entry["commit"]:
        raise RuntimeError(f"{name} tag does not match pinned source commit")
    head = subprocess.run(["git", "-C", str(source), "rev-parse", "--verify", "HEAD"],
                          text=True, capture_output=True)
    if head.stdout.strip() != commit:
        if subprocess.check_output(["git", "-C", str(source), "status", "--porcelain"], text=True).strip():
            raise RuntimeError(f"Cached {name} source has changes; use a clean source checkout")
        run(["git", "-C", str(source), "checkout", "--detach", commit])
    with tempfile.TemporaryDirectory(dir=cache) as folder:
        environment = {**os.environ, "GIT_INDEX_FILE": str(Path(folder) / "expected-index")}
        run(["git", "-C", str(source), "read-tree", commit], env=environment)
        clean = subprocess.run(["git", "-C", str(source), "diff", "--quiet", commit], check=False).returncode == 0
        for patch, _ in patches:
            run(["git", "-C", str(source), "apply", "--cached", "--check", str(patch)], env=environment)
            run(["git", "-C", str(source), "apply", "--cached", str(patch)], env=environment)
            if clean:
                run(["git", "-C", str(source), "apply", str(patch)])
        modified = subprocess.run(["git", "-C", str(source), "diff", "--quiet"], env=environment).returncode
        untracked = subprocess.check_output(["git", "-C", str(source), "ls-files", "--others", "--exclude-standard"], env=environment, text=True).strip()
        if modified or untracked:
            raise RuntimeError(f"Cached {name} source differs from the pinned base and declared patch")
        tree = subprocess.check_output(["git", "-C", str(source), "write-tree"], env=environment, text=True).strip()
    metadata = {"commit": commit, "tag": entry["tag"], "variant": variant, "source_tree": tree,
                "patches": [{key: selected[key] for key in ("path", "sha256", "base_commit")} for _, selected in patches]}
    if name == "whisper":
        metadata["encoder_reuse"] = enabled
        metadata["auto_language_en_zh"] = policy_enabled
    return source, build, metadata


def build_native(name: str, entry: dict, home: Path) -> dict:
    source, build, metadata = prepare_native_source(name, entry)
    options = ["-DCMAKE_BUILD_TYPE=Release", "-DCMAKE_OSX_DEPLOYMENT_TARGET=15.0",
               "-DBUILD_SHARED_LIBS=OFF", "-DGGML_METAL=ON",
               "-DGGML_METAL_EMBED_LIBRARY=ON", "-DGGML_NATIVE=OFF"]
    if name == "llama":
        options += ["-DLLAMA_CURL=OFF", "-DLLAMA_BUILD_TESTS=OFF",
                    "-DLLAMA_BUILD_SERVER=OFF", "-DLLAMA_OPENSSL=OFF"]
    else:
        options += ["-DWHISPER_BUILD_TESTS=OFF", "-DWHISPER_CURL=OFF"]
    run(["cmake", "-S", str(source), "-B", str(build), *options])
    run(["cmake", "--build", str(build), "--config", "Release", "--parallel", "4",
         "--target", *entry["targets"]])
    destination = home / "runtime" / name / metadata["variant"]
    destination.mkdir(parents=True, exist_ok=True)
    executables = {}
    for target in entry["targets"]:
        binary = destination / target
        staging = destination / (target + ".tmp")
        shutil.copy2(build / "bin" / target, staging)
        run([str(staging), "--help"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        staging.replace(binary)
        executables[target] = {"path": str(binary), "sha256": sha256(binary)}
    return {**metadata, "cmake_options": options, "executables": executables}


def build_summary_batch(entry: dict, home: Path) -> dict:
    helper = entry["summary_batch"]
    source = (ROOT / helper["source"]).resolve()
    if (helper.get("enabled") is not True or helper.get("base_commit") != entry["commit"]
            or not source.is_relative_to(ROOT.resolve()) or not source.is_file()
            or sha256(source) != helper.get("sha256")):
        raise RuntimeError("Summary helper source failed its pinned integrity check")
    native = ROOT / ".cache/native/llama" / entry["commit"]
    upstream = native / "source"
    actual = subprocess.check_output(["git", "-C", str(upstream), "rev-parse", "HEAD"], text=True).strip()
    if (actual != entry["commit"] or subprocess.check_output(
            ["git", "-C", str(upstream), "status", "--porcelain"], text=True).strip()):
        raise RuntimeError("Summary helper requires a clean pinned llama source")
    libraries = ["common/libllama-common.a", "common/libllama-common-base.a", "vendor/cpp-httplib/libcpp-httplib.a",
                 "src/libllama.a", "ggml/src/libggml.a", "ggml/src/libggml-cpu.a", "ggml/src/ggml-blas/libggml-blas.a",
                 "ggml/src/ggml-metal/libggml-metal.a", "ggml/src/libggml-base.a"]
    linked = {name: sha256(native / "build" / name) for name in libraries}
    variant = entry["commit"] + "-" + helper["sha256"]
    cache = ROOT / ".cache/native/summary-batch" / variant
    cached_source = cache / "source/summary-batch.cpp"
    cached_source.parent.mkdir(parents=True, exist_ok=True)
    if cached_source.exists() and sha256(cached_source) != helper["sha256"]:
        raise RuntimeError("Cached summary helper source has unexpected changes")
    if not cached_source.exists():
        shutil.copy2(source, cached_source)
    binary = cache / "build/afterword-summary-batch"
    binary.parent.mkdir(parents=True, exist_ok=True)
    staging = binary.with_suffix(".tmp")
    command = ["c++", "-O3", "-DNDEBUG", "-std=c++17", "-mmacosx-version-min=15.0",
               *["-I" + str(upstream / path) for path in ("include", "common", "ggml/include", "vendor/nlohmann")],
               str(cached_source), *[str(native / "build" / name) for name in libraries], "-lm",
               "-framework", "Accelerate", "-framework", "Foundation", "-framework", "Metal", "-framework", "MetalKit",
               "-o", str(staging)]
    run(command)
    run([str(staging), "--help"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    staging.replace(binary)
    destination = home / "runtime/summary-batch" / variant / binary.name
    destination.parent.mkdir(parents=True, exist_ok=True)
    installed = destination.with_suffix(".tmp")
    shutil.copy2(binary, installed)
    installed.replace(destination)
    metadata = {"enabled": True, "helper_version": 1, "mode": "serial", "context_per_sequence": 8192,
                "base_commit": entry["commit"], "source": helper["source"], "source_sha256": helper["sha256"],
                "variant": variant, "libraries_sha256": linked, "build_command": command,
                "compiler": subprocess.check_output(["c++", "--version"], text=True).strip(),
                "executables": {binary.name: {"path": str(destination), "sha256": sha256(destination)}}}
    atomic_json(cache / "build-receipt.json", metadata)
    return metadata


def provision_public(home: Path, manifest: dict) -> None:
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise RuntimeError("This development runtime requires Apple Silicon macOS")
    for command in ["uv", "git", "cmake", "curl", "clang"]:
        if not shutil.which(command):
            raise RuntimeError(f"Install the required development tool: {command}")
    environment = {**os.environ, "UV_CACHE_DIR": str(ROOT / ".cache/uv")}
    run(["uv", "sync", "--locked", "--group", "inference"],
        cwd=ROOT / "worker", env=environment)
    python = ROOT / "worker/.venv/bin/python"
    run([str(python), "-c",
         "import torch, torchaudio; from pyannote.audio.core.io import Audio; "
         "waveform, rate = Audio(sample_rate=8000)"
         "({'waveform': torch.zeros(1, 1600), 'sample_rate': 16000}); "
         "assert tuple(waveform.shape) == (1, 800) and rate == 8000"],
        env={**environment, "PYANNOTE_METRICS_ENABLED": "0",
             "HF_HUB_OFFLINE": "1", "MPLCONFIGDIR": str(ROOT / ".cache/matplotlib")})
    home.mkdir(parents=True, exist_ok=True)
    runtime_path = home / "runtime.json"
    runtime = json.loads(runtime_path.read_text()) if runtime_path.exists() else {}
    runtime.update({"schema_version": 1, "python": str(python),
                    "worker_root": str(ROOT / "worker"),
                    "afconvert": "/usr/bin/afconvert",
                    "manifest_sha256": sha256(MANIFEST),
                    "python_lock_sha256": sha256(ROOT / "worker/uv.lock")})
    runtime["native"] = {}
    for name, entry in manifest["native"].items():
        runtime["native"][name] = build_native(name, entry, home)
    summary_entry = manifest["native"]["llama"].get("summary_batch", {})
    if type(summary_entry.get("enabled", False)) is not bool:
        raise RuntimeError("Invalid summary helper configuration")
    if summary_entry.get("enabled", False):
        helper = build_summary_batch(manifest["native"]["llama"], home)
        runtime["native"]["summary_batch"] = helper
        runtime["llama_summary_batch"] = helper["executables"]["afterword-summary-batch"]["path"]
    else:
        runtime.pop("llama_summary_batch", None)
    for key, component, target in [
        ("whisper_cli", "whisper", "whisper-cli"),
        ("vad_cli", "whisper", "whisper-vad-speech-segments"),
        ("llama_completion", "llama", "llama-completion"),
        ("llama_tokenize", "llama", "llama-tokenize")
    ]:
        runtime[key] = runtime["native"][component]["executables"][target]["path"]
    runtime.setdefault("models", {})
    for name in ["vad", "asr", "summary"]:
        model = manifest["models"][name]
        directory = home / "models" / name / model["revision"]
        paths = [download(model, entry, directory) for entry in model["files"]]
        runtime[name + "_model"] = str(paths[0])
        runtime["models"][name] = {
            **model, "files": [{**entry, "path": str(path)}
                              for entry, path in zip(model["files"], paths)]}
    atomic_json(runtime_path, runtime)
    print(f"Public runtime ready: {runtime_path}")
    print("Diarization still requires separate setup after model terms acceptance.")


def provision_gated(home: Path, manifest: dict, accepted: bool) -> None:
    if not accepted:
        raise RuntimeError("Accept the Community-1 model terms yourself, configure HF credentials, "
                           "then pass --terms-already-accepted")
    from huggingface_hub import get_token, snapshot_download

    if not get_token():
        raise RuntimeError("Configure existing Hugging Face credentials before gated setup")
    runtime_path = home / "runtime.json"
    runtime = json.loads(runtime_path.read_text())
    model = manifest["models"]["diarization"]
    directory = home / "models/diarization" / model["revision"]
    try:
        snapshot_download(repo_id=model["repository"], revision=model["revision"],
                          local_dir=directory, token=True)
    except Exception:
        raise RuntimeError("Community-1 download failed; check accepted terms and local HF access") from None
    files = [{"path": str(path), "size": path.stat().st_size, "sha256": sha256(path)}
             for path in sorted(directory.rglob("*"))
             if path.is_file() and ".cache" not in path.relative_to(directory).parts]
    if not (directory / "config.yaml").is_file() or not files:
        raise RuntimeError("Downloaded Community-1 snapshot lacks its pipeline configuration")
    run([runtime["python"], "-c",
         "import sys; from pyannote.audio import Pipeline; "
         "assert Pipeline.from_pretrained(sys.argv[1]) is not None", str(directory)],
        env={**os.environ, "HF_HUB_OFFLINE": "1", "HF_HUB_DISABLE_TELEMETRY": "1",
             "PYANNOTE_METRICS_ENABLED": "0", "MPLCONFIGDIR": str(ROOT / ".cache/matplotlib")})
    runtime["diarization_model"] = str(directory)
    runtime.setdefault("models", {})["diarization"] = {**model, "files": files}
    atomic_json(runtime_path, runtime)
    print(f"Pinned local Community-1 snapshot ready: {directory}")


def inspect(home: Path, verify_hashes: bool) -> int:
    runtime_path = home / "runtime.json"
    if not runtime_path.is_file():
        print(json.dumps({"ready": False, "missing": [str(runtime_path)]}, indent=2))
        return 1
    runtime = json.loads(runtime_path.read_text())
    missing = [key for key in ["python", "worker_root", "whisper_cli", "llama_completion",
                               "llama_tokenize", "vad_cli", "vad_model", "asr_model", "summary_model", "diarization_model"]
               if not runtime.get(key) or not Path(runtime[key]).exists()]
    if runtime.get("native", {}).get("summary_batch", {}).get("enabled") is True:
        helper = runtime.get("llama_summary_batch")
        if not isinstance(helper, str) or not Path(helper).is_absolute() or not Path(helper).is_file():
            missing.append("llama_summary_batch")
    corrupt = []
    if verify_hashes:
        for component in runtime.get("native", {}).values():
            for entry in component["executables"].values():
                path = Path(entry["path"])
                if not path.is_file() or sha256(path) != entry["sha256"]:
                    corrupt.append(str(path))
        for model in runtime.get("models", {}).values():
            for entry in model.get("files", []):
                if not verify_file(Path(entry["path"]), entry):
                    corrupt.append(entry["path"])
    print(json.dumps({"ready": not missing and not corrupt,
                      "runtime": str(runtime_path), "missing": missing,
                      "integrity_failures": corrupt}, indent=2))
    return int(bool(missing or corrupt))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["inspect", "public", "gated"])
    parser.add_argument("--home", type=Path, default=DEFAULT_HOME)
    parser.add_argument("--verify-hashes", action="store_true")
    parser.add_argument("--terms-already-accepted", action="store_true")
    args = parser.parse_args()
    home = args.home.expanduser().resolve()
    manifest = json.loads(MANIFEST.read_text())
    if args.command == "inspect":
        return inspect(home, args.verify_hashes)
    if args.command == "public":
        provision_public(home, manifest)
    else:
        provision_gated(home, manifest, args.terms_already_accepted)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (RuntimeError, OSError, subprocess.CalledProcessError) as error:
        print(f"Setup failed: {error}", file=sys.stderr)
        sys.exit(1)
