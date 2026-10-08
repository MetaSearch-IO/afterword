from __future__ import annotations

import contextlib
import fcntl
import json
import os
from pathlib import Path
import queue
import re
import signal
import select
import subprocess
import sys
import threading
import time


class WorkerError(Exception):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code


class Cancelled(Exception):
    pass


class Control:
    def __init__(self, run_id: str, watch_stdin: bool = True, progress_events: bool = False):
        self.run_id = run_id
        self.cancelled = threading.Event()
        self.stage = "preflight"
        self.terminal = False
        self.lock_fd: int | None = None
        self.progress_enabled = progress_events
        self.progress_counts = {}
        self.stage_active = False
        if watch_stdin:
            threading.Thread(target=self._input, daemon=True).start()
            signal.signal(signal.SIGTERM, lambda *_: self.cancelled.set())
            signal.signal(signal.SIGINT, lambda *_: self.cancelled.set())

    def _input(self):
        buffered = bytearray()
        while not self.cancelled.is_set():
            if not select.select([sys.stdin.fileno()], [], [], 0.1)[0]:
                continue
            block = os.read(sys.stdin.fileno(), 4096)
            buffered.extend(block)
            if not block or len(buffered) > 65_536:
                self.cancelled.set()
                return
            while b"\n" in buffered:
                line, _, remainder = buffered.partition(b"\n")
                buffered[:] = remainder
                try:
                    event = json.loads(line)
                    if event.get("protocol_version") != 1 or event.get("run_id") != self.run_id or event.get("type") == "cancel":
                        self.cancelled.set()
                        return
                except (ValueError, AttributeError):
                    self.cancelled.set()
                    return

    def check(self):
        if self.cancelled.is_set():
            raise Cancelled()

    def emit(self, kind: str, **fields):
        if self.terminal:
            raise WorkerError("protocol", "A terminal event was already emitted.")
        event = {"protocol_version": 1, "run_id": self.run_id, "type": kind, **fields}
        data = json.dumps(event, ensure_ascii=False, allow_nan=False, separators=(",", ":")) + "\n"
        if len(data.encode()) > 65_536:
            raise WorkerError("protocol", "Worker event exceeds the protocol limit.")
        sys.stdout.write(data)
        sys.stdout.flush()
        self.terminal = kind in {"completed", "failed", "cancelled"}
        if kind == "stage_completed" and fields.get("process_group_id") is None:
            self.stage_active = False

    def begin(self, stage: str):
        self.check()
        self.stage = stage
        self.stage_active = True
        self.progress_counts.clear()
        self.emit("stage_started", stage=stage)

    def progress(self, completed: int, total: int, unit: str, phase: str):
        if not self.progress_enabled:
            return
        self.check()
        units = {"asr": {"audio_windows", "speech_clips"},
                 "diarization": {"segmentation_chunks", "embedding_batches"},
                 "summary": {"note_groups", "reduction_groups"}}
        valid = (self.stage_active and not self.terminal and isinstance(unit, str) and unit in units.get(self.stage, set())
                 and type(completed) is int and type(total) is int and 0 <= completed <= total <= 1_000_000_000
                 and total > 0 and isinstance(phase, str) and re.fullmatch(r"[A-Za-z0-9_-]{1,96}", phase))
        if not valid:
            raise WorkerError("protocol", "Invalid or regressing stage progress.")
        key = (unit, phase)
        previous = self.progress_counts.get(key)
        if previous is not None and (previous[1] != total or previous[0] > completed):
            raise WorkerError("protocol", "Invalid or regressing stage progress.")
        if previous == (completed, total):
            return
        if previous is None and len(self.progress_counts) >= 4096:
            raise WorkerError("protocol", "Too many progress phases.")
        self.progress_counts[key] = (completed, total)
        self.emit("stage_progress", stage=self.stage, completed=completed, total=total,
                  progress_unit=unit, progress_phase=phase)

    def run(self, arguments: list[str], output: Path, cwd: Path | None = None,
            environment: dict | None = None, limit: int = 64 * 1024 * 1024, line_callback=None):
        self.check()
        if not Path(arguments[0]).is_absolute():
            raise WorkerError("setup", "Native executable paths must be absolute.")
        command = [sys.executable, "-m", "afterword_worker.child", "--parent", str(os.getpid()), "--", *arguments]
        env = {**os.environ, "HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1",
               "PYANNOTE_METRICS_ENABLED": "0", "HF_HUB_DISABLE_TELEMETRY": "1",
               "TOKENIZERS_PARALLELISM": "false", **(environment or {})}
        env["PYTHONPATH"] = str(Path(__file__).resolve().parents[1])
        retained = bytearray()
        too_large = threading.Event()
        output_failed = threading.Event()
        read_failed = threading.Event()
        updates = queue.Queue(maxsize=128)
        invalid_lines = threading.Event()

        def dispatch_updates():
            if read_failed.is_set():
                raise WorkerError("native_output", "Unable to read native output.")
            if invalid_lines.is_set():
                raise WorkerError("native_protocol", "Native progress is malformed or exceeds its bounds.")
            for _ in range(128):
                try:
                    value = updates.get_nowait()
                except queue.Empty:
                    break
                self.check()
                line_callback(value)

        with output.open("wb") as destination:
            # Keep the meeting locked while the guardian cleans up a killed worker's child.
            process = subprocess.Popen(command, cwd=cwd, env=env, stdin=subprocess.DEVNULL,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True,
                                       pass_fds=() if self.lock_fd is None else (self.lock_fd,))

            def drain_output():
                size = 0
                pending = bytearray()
                read = process.stdout.read1 if line_callback is not None else process.stdout.read
                try:
                    for block in iter(lambda: read(8192), b""):
                        size += len(block)
                        if size <= limit and not output_failed.is_set():
                            try:
                                destination.write(block)
                            except OSError:
                                output_failed.set()
                        elif size > limit:
                            too_large.set()
                        if line_callback is not None and not invalid_lines.is_set():
                            pending.extend(block)
                            while b"\n" in pending:
                                line, _, remainder = pending.partition(b"\n")
                                pending[:] = remainder
                                try:
                                    if len(line) > 8192:
                                        raise ValueError()
                                    value = json.loads(line)
                                    if not isinstance(value, dict):
                                        raise ValueError()
                                    updates.put_nowait(value)
                                except (ValueError, UnicodeError, RecursionError, queue.Full):
                                    invalid_lines.set()
                                    break
                            if len(pending) > 8192:
                                invalid_lines.set()
                except (OSError, ValueError):
                    read_failed.set()
                if line_callback is not None and pending:
                    invalid_lines.set()

            def drain_error():
                try:
                    for block in iter(lambda: process.stderr.read(8192), b""):
                        retained.extend(block)
                        if len(retained) > 262_144:
                            del retained[:-262_144]
                except (OSError, ValueError):
                    read_failed.set()

            readers = [threading.Thread(target=drain_output, daemon=True), threading.Thread(target=drain_error, daemon=True)]
            for reader in readers:
                reader.start()
            try:
                self.emit("stage_started", stage=self.stage, process_group_id=process.pid)
                while process.poll() is None:
                    self.check()
                    dispatch_updates()
                    if output_failed.is_set():
                        raise WorkerError("storage", "Unable to save native output.")
                    if too_large.is_set():
                        raise WorkerError("native_output", "Native output exceeds the configured limit.")
                    self.cancelled.wait(0.05)
                self.check()
                if process.returncode:
                    raise WorkerError("native_exit", f"The {self.stage} executable failed (exit {process.returncode}).")
            finally:
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=0.5)
                except subprocess.TimeoutExpired:
                    pass
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(process.pid, signal.SIGKILL)
                process.wait()
                for reader in readers:
                    reader.join(timeout=2)
                process.stdout.close()
                process.stderr.close()
                deadline = time.monotonic() + 1
                while True:
                    try:
                        os.killpg(process.pid, 0)
                    except ProcessLookupError:
                        self.emit("stage_completed", stage=self.stage, process_group_id=process.pid, process_group_finished=True)
                        break
                    if time.monotonic() >= deadline:
                        raise WorkerError("cleanup", "The native process group has not exited yet.")
                    time.sleep(0.02)
            if read_failed.is_set():
                raise WorkerError("native_output", "Unable to read native output.")
            if line_callback is not None:
                if any(reader.is_alive() for reader in readers):
                    raise WorkerError("native_protocol", "Native progress readers did not finish.")
                dispatch_updates()
            if too_large.is_set():
                raise WorkerError("native_output", "Native output exceeds the configured limit.")
            if output_failed.is_set():
                raise WorkerError("storage", "Unable to save native output.")


@contextlib.contextmanager
def meeting_lock(meeting: Path):
    path = meeting / ".processing.lock"
    if path.is_symlink():
        raise WorkerError("path", "The processing lock cannot be a symbolic link.")
    with path.open("a+b") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise WorkerError("busy", "Another worker is processing this meeting.") from None
        try:
            yield lock.fileno()
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)
