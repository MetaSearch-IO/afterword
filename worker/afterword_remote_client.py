#!/usr/bin/env python3
"""Run an Afterword processing job on hyperion, behaving like the local worker.

Adapted from GAIP tools/afterword/client.py at 0c9f90a8d2c2417243f2e67dadc9b3049ce8c33b.

    AFTERWORD_REMOTE=http://100.92.212.58:8790 \\
      python3 worker/afterword_remote_client.py process --meeting /abs/meeting --runtime ignored.json \\
        --run-id R --revision-id V --summary-id S --prepared work/R/prepared.json --progress-events

Same command line, stdout event schema, stdin cancel and exit codes (0 completed,
1 failed, 2 cancelled) as `python -m afterword_worker process`, so the app can launch this
instead of the worker. --runtime is accepted and ignored (hyperion has its own).
Standard library only; Python 3.12+ (the worker venv's interpreter is fine).

What it does:
  1. takes the meeting's .processing.lock, as the worker would;
  2. uploads only the current run's inputs, including prepared 16 kHz WAVs for
     full processing or the selected transcript for notes;
  3. relays the remote worker's events; before passing on a stage_completed or the
     terminal event it pulls the files the worker has written so far into the local
     meeting, so whatever the event points at already exists locally;
  4. confirms deletion on hyperion before reporting a terminal result.
If hyperion is unreachable it fails like the worker does (a `failed` event, code
"remote"), so the caller can fall back to local processing.
"""
from __future__ import annotations

import argparse
import contextlib
import fcntl
import http.client
import io
import json
import os
from pathlib import Path
import re
import select
import shutil
import sys
import tarfile
import tempfile
import threading
import time
import urllib.parse

try:
    from afterword_worker.voice_profiles import assign_profiles, load_prior_profiles, save_profiles, unit_vector
except ModuleNotFoundError:
    from afterword_voice_profiles import assign_profiles, load_prior_profiles, save_profiles, unit_vector

RETRY_SECONDS = 300
TIMEOUT = 60
WORKER_PROTOCOL = "afterword-alignment-v4"


def safe_relative(value) -> bool:
    return (isinstance(value, str) and 0 < len(value) < 1024 and not value.startswith("/")
            and "\\" not in value and "\0" not in value
            and all(part not in {"", ".", ".."} for part in value.split("/")))


def extract(stream, root: Path, limit: int) -> int:
    total = 0
    with tarfile.open(fileobj=stream, mode="r|") as archive:
        for member in archive:
            if not safe_relative(member.name.rstrip("/")):
                raise ValueError("Unsafe path in remote archive.")
            target = root / member.name.rstrip("/")
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            if not member.isfile():
                raise ValueError("Remote archive contains a non-file entry.")
            total += member.size
            if total > limit:
                raise ValueError("Remote archive exceeds its size limit.")
            target.parent.mkdir(parents=True, exist_ok=True)
            if target.is_symlink() or not target.resolve().is_relative_to(root.resolve()):
                raise ValueError("Remote archive path escapes the meeting.")
            source = archive.extractfile(member)
            with target.open("wb") as output:
                shutil.copyfileobj(source, output, 1 << 20)


class Remote:
    def __init__(self, base: str):
        url = urllib.parse.urlsplit(base)
        if url.scheme != "http" or not url.hostname:
            raise ValueError("AFTERWORD_REMOTE must look like http://host:port")
        self.host, self.port = url.hostname, url.port or 80

    def connect(self, timeout=TIMEOUT) -> http.client.HTTPConnection:
        return http.client.HTTPConnection(self.host, self.port, timeout=timeout)

    def call(self, method: str, path: str, body=None, headers=None, timeout=TIMEOUT, output=None):
        conn = self.connect(timeout)
        try:
            conn.request(method, path, body=body, headers=headers or {})
            response = conn.getresponse()
            if response.status >= 300 or output is None:
                data = response.read()
            else:
                for block in iter(lambda: response.read(1 << 20), b""):
                    output.write(block)
                data = b""
        finally:
            conn.close()
        if response.status >= 300:
            try:
                message = json.loads(data)["error"]
            except (ValueError, KeyError, TypeError):
                message = data[:200].decode(errors="replace")
            raise RemoteError(response.status, message)
        return data


class RemoteError(Exception):
    def __init__(self, status: int, message: str):
        super().__init__(f"{status}: {message}")
        self.status = status


class UploadCancelled(Exception):
    pass


class ArtifactRejected(Exception):
    pass


class CancellableBody:
    def __init__(self, source, cancelled):
        self.source, self.cancelled = source, cancelled

    def read(self, size=-1):
        if self.cancelled.is_set():
            raise UploadCancelled()
        return self.source.read(size)


def meeting_archive(root: Path, out, args) -> None:
    """Tar only the inputs required by this processing run."""
    manifest_path = root / "meeting.json"
    if manifest_path.is_symlink() or not manifest_path.is_file():
        raise ValueError("Meeting metadata is unavailable.")
    meeting = json.loads(manifest_path.read_text())
    if not isinstance(meeting, dict) or any(key not in meeting for key in ("schema_version", "id", "capture_state", "chunks")) \
            or not isinstance(meeting["chunks"], list):
        raise ValueError("Invalid meeting metadata.")
    metadata = {key: meeting[key] for key in ("schema_version", "id", "capture_state", "chunks")}
    raw = {chunk.get("relative_path") for chunk in meeting["chunks"] if isinstance(chunk, dict)}
    names = {"meeting.json"}
    if args.names:
        names.add(args.names)
    if args.summary_only:
        names.update({f"revisions/{args.revision_id}/transcript.json",
                      f"revisions/{args.revision_id}/provenance.json"})
        if args.summary_checkpoint:
            names.add(args.summary_checkpoint)
    else:
        if not args.prepared or not safe_relative(args.prepared):
            raise ValueError("Prepared audio is required for remote processing.")
        names.add(args.prepared)
        prepared_path = root / args.prepared
        if prepared_path.is_symlink() or not prepared_path.is_file() \
                or not prepared_path.resolve().is_relative_to(root.resolve()):
            raise ValueError("Prepared audio inventory is unavailable.")
        prepared = json.loads(prepared_path.read_text())
        if not isinstance(prepared, dict) or not isinstance(prepared.get("sources"), list):
            raise ValueError("Prepared audio inventory is invalid.")
        for source in prepared.get("sources", []):
            if not isinstance(source, dict):
                raise ValueError("Prepared audio source is invalid.")
            name = source.get("relative_path")
            if not safe_relative(name) or not name.startswith(f"work/{args.run_id}/") or name in raw:
                raise ValueError("Prepared audio path does not belong to this run.")
            names.add(name)
    with tarfile.open(fileobj=out, mode="w") as archive:
        for name in sorted(names):
            if not safe_relative(name):
                raise ValueError("Invalid remote input path.")
            if name == "meeting.json":
                data = json.dumps(metadata, ensure_ascii=False, separators=(",", ":")).encode()
                info = tarfile.TarInfo(name)
                info.size = len(data)
                archive.addfile(info, io.BytesIO(data))
                continue
            path = root / name
            if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(root.resolve()) \
                    or name in raw:
                raise ValueError("Remote input is missing or escapes the meeting.")
            archive.add(path, arcname=name, recursive=False)


def apply_changes(root: Path, data, args=None) -> list[str]:
    """Unpack hyperion's changed files beside the meeting, then move each into place."""
    with tempfile.TemporaryDirectory(dir=root, prefix=".remote-") as staging:
        staging = Path(staging)
        extract(io.BytesIO(data) if isinstance(data, bytes) else data, staging, 1 << 34)
        changes = []
        for path in sorted(staging.rglob("*")):
            if path.is_file():
                name = path.relative_to(staging).as_posix()
                if args is not None:
                    allowed = name.startswith(f"work/{args.run_id}/")
                    if args.summary_only:
                        allowed = allowed or name == f"revisions/{args.revision_id}/summaries/{args.summary_id}.json"
                    else:
                        allowed = allowed or name.startswith(f"revisions/{args.revision_id}/") \
                            or (args.transcript_first and name.startswith(f"revisions/{args.run_id}/")) \
                            or name == "voice_profiles.json"
                    if not allowed:
                        raise ValueError("Remote output is outside this processing run.")
                target_name = f"work/{args.run_id}/remote_voice_profiles.json" \
                    if args is not None and name == "voice_profiles.json" else name
                target = root / target_name
                if target.is_symlink() or not target.parent.resolve().is_relative_to(root.resolve()):
                    raise ValueError("Remote output path escapes the meeting.")
                changes.append((path, target, target_name))
        for path, target, name in changes:
            target.parent.mkdir(parents=True, exist_ok=True)
            os.replace(path, target)
        return [name for _, _, name in changes]


def localize_profiles(root: Path, candidate: Path):
    if candidate.is_symlink() or candidate.stat().st_size > 1_048_576:
        raise ValueError("Remote voice profile file is invalid.")
    value = json.loads(candidate.read_text())
    if not isinstance(value, dict) or value.get("schema_version") != 1 or value.get("meeting_id") != root.name \
            or not isinstance(value.get("revision_id"), str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,128}", value["revision_id"]) \
            or not isinstance(value.get("run_id"), str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,128}", value["run_id"]) \
            or not isinstance(value.get("model_fingerprint"), str) \
            or not re.fullmatch(r"[0-9a-f]{64}", value["model_fingerprint"]) \
            or not isinstance(value.get("profiles"), list) or len(value["profiles"]) > 64:
        raise ValueError("Remote voice profiles do not match this meeting.")
    transcript_path = root / "revisions" / value["revision_id"] / "transcript.json"
    if transcript_path.is_symlink() or transcript_path.stat().st_size > 16 * 1024 * 1024:
        raise ValueError("Remote transcript is invalid.")
    transcript = json.loads(transcript_path.read_text())
    if not isinstance(transcript, dict) or transcript.get("meeting_id") != root.name \
            or transcript.get("revision_id") != value["revision_id"] \
            or transcript.get("run_id") != value["run_id"]:
        raise ValueError("Remote voice profiles do not match the transcript.")
    current_path = root / "voice_profiles.json"
    if current_path.is_symlink():
        raise ValueError("Local voice profile file is invalid.")
    if current_path.is_file():
        current = json.loads(current_path.read_text())
        if current.get("revision_id") == value["revision_id"] and current.get("run_id") == value["run_id"]:
            return
    speakers = {item.get("id") for item in transcript.get("speakers", [])
                if isinstance(item, dict) and item.get("source") == "system"}
    vectors = {}
    dimension = None
    for profile in value["profiles"]:
        if not isinstance(profile, dict) or profile.get("speaker_id") not in speakers \
                or profile["speaker_id"] in vectors:
            raise ValueError("Remote voice profile speaker is invalid.")
        vector = unit_vector(profile.get("vector"), dimension)
        if vector is None:
            raise ValueError("Remote voice profile vector is invalid.")
        dimension = len(vector)
        vectors[profile["speaker_id"]] = vector
    if vectors:
        prior = load_prior_profiles(root, value["model_fingerprint"], len(next(iter(vectors.values()))))
        mapped = assign_profiles(root.name, value["revision_id"], value["run_id"],
                                 value["model_fingerprint"], vectors, prior)
        save_profiles(root, mapped)


class Run:
    def __init__(self, args, remote: Remote):
        self.args, self.remote = args, remote
        self.root = Path(args.meeting)
        self.terminal = False
        self.job: str | None = None
        self.cancelled = threading.Event()

    def emit_failed(self, message: str, code: str = "remote"):
        if not self.terminal:
            print(json.dumps({"protocol_version": 1, "run_id": self.args.run_id, "type": "failed",
                              "stage": "preflight", "code": code, "message": message},
                             ensure_ascii=False, separators=(",", ":")), flush=True)
            self.terminal = True

    def emit_cancelled(self):
        if not self.terminal:
            print(json.dumps({"protocol_version": 1, "run_id": self.args.run_id, "type": "cancelled",
                              "stage": "preflight"}, separators=(",", ":")), flush=True)
            self.terminal = True

    def failed_event(self, message: str, code: str = "remote"):
        return {"protocol_version": 1, "run_id": self.args.run_id, "type": "failed",
                "stage": "preflight", "code": code, "message": message}

    def emit_event(self, event):
        event = {key: value for key, value in event.items()
                 if key not in {"process_group_id", "process_group_finished"}}
        sys.stdout.buffer.write((json.dumps(event, ensure_ascii=False, separators=(",", ":")) + "\n").encode())
        sys.stdout.flush()

    def watch_stdin(self):
        # The worker's rule: EOF, an unparsable line or a cancel line all mean cancel.
        buffered = bytearray()
        while not self.terminal:
            try:
                if not select.select([sys.stdin.fileno()], [], [], 0.2)[0]:
                    continue
                block = os.read(sys.stdin.fileno(), 4096)
            except (OSError, ValueError):
                if self.terminal:
                    return
                return self.cancel()
            buffered.extend(block)
            if not block or len(buffered) > 65_536:
                return self.cancel()
            while b"\n" in buffered:
                line, _, rest = buffered.partition(b"\n")
                buffered[:] = rest
                try:
                    event = json.loads(line)
                    if (event.get("protocol_version") != 1 or event.get("run_id") != self.args.run_id
                            or event.get("type") == "cancel"):
                        return self.cancel()
                except (ValueError, AttributeError):
                    return self.cancel()

    def cancel(self):
        if self.terminal:
            return
        self.cancelled.set()
        if self.job:
            with contextlib.suppress(OSError, http.client.HTTPException, RemoteError):
                self.remote.call("POST", f"/v1/jobs/{self.job}/cancel", timeout=2)

    def worker_args(self) -> dict:
        a = self.args
        value = {"run_id": a.run_id, "revision_id": a.revision_id, "summary_id": a.summary_id,
                 "language": a.language, "summary_only": a.summary_only, "transcript_first": a.transcript_first,
                 "progress_events": a.progress_events, "allow_unknown_speakers": a.allow_unknown_speakers}
        for key in ("prepared", "names", "summary_checkpoint"):
            if getattr(a, key):
                value[key] = getattr(a, key)
        return value

    def pull(self):
        with tempfile.TemporaryFile() as stream:
            self.remote.call("GET", f"/v1/jobs/{self.job}/changes", timeout=600, output=stream)
            stream.seek(0)
            try:
                changes = apply_changes(self.root, stream, self.args)
                if f"work/{self.args.run_id}/remote_voice_profiles.json" in changes:
                    localize_profiles(self.root, self.root / "work" / self.args.run_id / "remote_voice_profiles.json")
            except (OSError, ValueError, KeyError, TypeError, tarfile.TarError) as error:
                raise ArtifactRejected(str(error)) from error

    def preflight(self):
        health = json.loads(self.remote.call("GET", "/v1/health", timeout=6))
        if not isinstance(health, dict) or health.get("ok") is not True \
                or health.get("worker_protocol") != WORKER_PROTOCOL:
            raise ValueError("Hyperion has not confirmed a compatible Afterword worker. Retry locally.")

    def submit(self):
        if self.cancelled.is_set():
            raise UploadCancelled()
        self.preflight()
        if self.cancelled.is_set():
            raise UploadCancelled()
        with tempfile.TemporaryFile() as body:
            meeting_archive(self.root, body, self.args)
            size = body.tell()
            body.seek(0)
            if self.cancelled.is_set():
                raise UploadCancelled()
            query = urllib.parse.urlencode({"args": json.dumps(self.worker_args())})
            data = self.remote.call("POST", f"/v1/jobs?{query}", body=CancellableBody(body, self.cancelled), timeout=600,
                                    headers={"Content-Type": "application/x-tar", "Content-Length": str(size)})
        self.job = json.loads(data)["job"]
        if self.cancelled.is_set():
            self.cancel()

    def relay(self):
        index, last_contact = 0, time.time()
        while True:
            try:
                conn = self.remote.connect(timeout=90)
                try:
                    conn.request("GET", f"/v1/jobs/{self.job}/events?from={index}")
                    response = conn.getresponse()
                    if response.status == 404:
                        return 1, self.failed_event("Remote processing on hyperion was lost; retry.")
                    if response.status != 200:
                        raise RemoteError(response.status, "Remote event stream was refused.")
                    while True:
                        line = response.readline()
                        if not line:
                            break
                        last_contact = time.time()
                        if not line.strip():
                            continue
                        event = json.loads(line)
                        kind = event.get("type")
                        if kind == "stage_completed" or kind in {"completed", "failed", "cancelled"}:
                            self.pull()
                        index += 1
                        if kind in {"completed", "failed", "cancelled"}:
                            return {"completed": 0, "cancelled": 2}.get(kind, 1), event
                        self.emit_event(event)
                finally:
                    conn.close()
                status = json.loads(self.remote.call("GET", f"/v1/jobs/{self.job}"))
                if status["state"] in {"done", "failed", "cancelled"} and status["events"] <= index:
                    return 1, self.failed_event("The remote worker exited without a result.", "processing")
            except ArtifactRejected as error:
                return 1, self.failed_event(f"Remote output was rejected: {error}", "remote_artifact")
            except (OSError, http.client.HTTPException, RemoteError, ValueError, TypeError, KeyError):
                if self.cancelled.is_set():
                    return 2, {"protocol_version": 1, "run_id": self.args.run_id,
                               "type": "cancelled", "stage": "preflight"}
                if time.time() - last_contact > RETRY_SECONDS:
                    return 1, self.failed_event("Lost the connection to hyperion during processing; retry.")
                time.sleep(3)

    def run(self) -> int:
        threading.Thread(target=self.watch_stdin, daemon=True).start()
        try:
            self.submit()
        except UploadCancelled:
            self.emit_cancelled()
            return 2
        except (OSError, http.client.HTTPException, RemoteError, ValueError, TypeError, KeyError) as error:
            if self.cancelled.is_set():
                self.emit_cancelled()
                return 2
            self.emit_failed(f"Could not start processing on hyperion ({error}).")
            return 1
        code, event = self.relay()
        self.terminal = True
        try:
            self.remote.call("DELETE", f"/v1/jobs/{self.job}", timeout=4 if self.cancelled.is_set() else 30)
        except (OSError, http.client.HTTPException, RemoteError, ValueError):
            code = 1
            event = self.failed_event("Remote job cleanup could not be confirmed. Do not retry remotely yet.",
                                      "remote_cleanup")
        self.emit_event(event)
        return code


@contextlib.contextmanager
def meeting_lock(root: Path):
    path = root / ".processing.lock"
    if path.is_symlink():
        raise RuntimeError("The processing lock cannot be a symbolic link.")
    with path.open("a+b") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise BlockingIOError("Another worker is processing this meeting.") from None
        try:
            yield
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="afterword-remote", description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--server", default=os.environ.get("AFTERWORD_REMOTE"),
                   help="http://host:port of hyperion's afterword-remote (default: $AFTERWORD_REMOTE)")
    sub = p.add_subparsers(dest="command", required=True)
    process = sub.add_parser("process")
    for argument in ("meeting", "runtime", "run-id", "revision-id", "summary-id"):
        process.add_argument("--" + argument, required=True)
    process.add_argument("--prepared")
    process.add_argument("--summary-only", action="store_true")
    process.add_argument("--transcript-first", action="store_true")
    process.add_argument("--progress-events", action="store_true")
    process.add_argument("--names")
    process.add_argument("--language", choices=["auto", "zh", "en"], default="auto")
    process.add_argument("--allow-unknown-speakers", action="store_true")
    process.add_argument("--summary-checkpoint")
    return p


def main(argv=None) -> int:
    args = parser().parse_args(argv)
    run = Run(args, None)
    root = Path(args.meeting)
    for key in ("prepared", "names", "summary_checkpoint"):
        value = getattr(args, key)
        if value is not None and not safe_relative(value):
            run.emit_failed(f"Invalid {key} path.", "path")
            return 1
    if not root.is_absolute() or not (root / "meeting.json").is_file():
        run.emit_failed("Meeting directory must be an existing absolute path.", "path")
        return 1
    try:
        run.remote = Remote(args.server or "")
    except ValueError as error:
        run.emit_failed(str(error), "setup")
        return 1
    try:
        with meeting_lock(root):
            return run.run()
    except BlockingIOError as error:
        run.emit_failed(str(error), "busy")
        return 1


if __name__ == "__main__":
    sys.exit(main())
