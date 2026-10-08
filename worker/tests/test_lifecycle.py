import contextlib
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest

from afterword_worker.protocol import Cancelled, Control, WorkerError, meeting_lock


class LifecycleTests(unittest.TestCase):
    def test_stdout_is_separate_and_stderr_does_not_block(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "output"
            control = Control("run", watch_stdin=False)
            events = io.StringIO()
            with contextlib.redirect_stdout(events):
                control.run([sys.executable, "-c", "import sys; sys.stderr.write('x'*500000); print('model output')"], path)
            self.assertEqual(path.read_text(), "model output\n")
            self.assertEqual(json.loads(events.getvalue().splitlines()[0])["type"], "stage_started")
            self.assertTrue(json.loads(events.getvalue().splitlines()[-1])["process_group_finished"])
            self.assertNotIn("model output", events.getvalue())

    def test_cancel_kills_hung_process_group(self):
        with tempfile.TemporaryDirectory() as folder:
            control = Control("run", watch_stdin=False)
            timer = threading.Timer(0.4, control.cancelled.set)
            timer.start()
            events = io.StringIO()
            started = time.monotonic()
            with contextlib.redirect_stdout(events), self.assertRaises(Cancelled):
                control.run([sys.executable, "-c", "import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); time.sleep(60)"], Path(folder) / "output")
            timer.join()
            self.assertLess(time.monotonic() - started, 3)
            group = json.loads(events.getvalue().splitlines()[0])["process_group_id"]
            with self.assertRaises(ProcessLookupError):
                os.killpg(group, 0)

    def test_oversized_native_output_is_rejected(self):
        with tempfile.TemporaryDirectory() as folder, contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaises(WorkerError):
                Control("run", watch_stdin=False).run([sys.executable, "-c", "print('x'*20000)"], Path(folder) / "output", limit=1024)

    def test_terminal_event_and_line_bound(self):
        control = Control("run", watch_stdin=False)
        with contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaises(WorkerError):
                control.emit("started", message="x" * 65_536)
            control.emit("cancelled", stage="asr")
            with self.assertRaises(WorkerError):
                control.emit("completed")

    def test_meeting_lock_rejects_second_worker(self):
        with tempfile.TemporaryDirectory() as folder:
            with meeting_lock(Path(folder)):
                with self.assertRaises(WorkerError):
                    with meeting_lock(Path(folder)):
                        pass

    def test_stdin_eof_and_signal_cancel(self):
        script = "from afterword_worker.protocol import Control; import time; c=Control('run'); print('ready',flush=True); c.cancelled.wait(5); print(c.cancelled.is_set(),flush=True)"
        for terminate in (False, True):
            process = subprocess.Popen([sys.executable, "-c", script], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
            self.assertEqual(process.stdout.readline().strip(), "ready")
            if terminate:
                process.send_signal(signal.SIGTERM)
            else:
                process.stdin.close()
            self.assertEqual(process.stdout.readline().strip(), "True")
            process.wait(timeout=2)
            if terminate:
                process.stdin.close()
            process.stdout.close()

    def test_output_write_failure_interrupts_and_cleans_up(self):
        class Sink:
            def open(self, *_):
                return self
            def __enter__(self):
                return self
            def __exit__(self, *_):
                pass
            def write(self, _):
                raise OSError("disk full")
        control = Control("run", watch_stdin=False)
        with contextlib.redirect_stdout(io.StringIO()), self.assertRaisesRegex(WorkerError, "save native output"):
            control.run([sys.executable, "-c", "import os,time; os.write(1,b'x'*100000); time.sleep(60)"], Sink())

    def test_worker_kill_guardian_reaps_native_group(self):
        with tempfile.TemporaryDirectory() as folder:
            script = ("from pathlib import Path; from afterword_worker.protocol import Control; import sys; "
                      f"Control('run',watch_stdin=False).run([sys.executable,'-c','import time; time.sleep(60)'],Path({str(Path(folder) / 'output')!r}))")
            worker = subprocess.Popen([sys.executable, "-c", script], stdout=subprocess.PIPE, text=True)
            event = json.loads(worker.stdout.readline())
            group = event["process_group_id"]
            worker.kill()
            worker.wait(timeout=2)
            deadline = time.monotonic() + 3
            while True:
                try:
                    os.killpg(group, 0)
                except ProcessLookupError:
                    break
                self.assertLess(time.monotonic(), deadline, "Guardian failed to clean up after worker death")
                time.sleep(0.05)
            worker.stdout.close()

    def test_guardian_retains_meeting_lock_after_worker_is_killed(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            ready = root / "native-ready"
            native = f"from pathlib import Path; import time; Path({str(ready)!r}).touch(); time.sleep(60)"
            script = ("from pathlib import Path\nfrom afterword_worker.protocol import Control, meeting_lock\nimport sys\n"
                      f"with meeting_lock(Path({folder!r})) as lock_fd:\n"
                      "    control = Control('run', watch_stdin=False)\n"
                      "    control.lock_fd = lock_fd\n"
                      f"    control.run([sys.executable, '-c', {native!r}], Path({str(root / 'output')!r}))\n")
            worker = subprocess.Popen([sys.executable, "-c", script], stdout=subprocess.PIPE, text=True)
            group = json.loads(worker.stdout.readline())["process_group_id"]
            try:
                deadline = time.monotonic() + 3
                while not ready.exists():
                    self.assertLess(time.monotonic(), deadline, "Native fixture did not start")
                    time.sleep(0.01)
                os.kill(group, signal.SIGSTOP)
                time.sleep(0.05)
                worker.kill()
                worker.wait(timeout=2)
                with self.assertRaisesRegex(WorkerError, "Another worker"):
                    with meeting_lock(root):
                        pass
            finally:
                if worker.poll() is None:
                    worker.kill()
                    worker.wait(timeout=2)
                with contextlib.suppress(ProcessLookupError):
                    os.kill(group, signal.SIGCONT)
                deadline = time.monotonic() + 3
                while True:
                    try:
                        os.killpg(group, 0)
                    except ProcessLookupError:
                        break
                    self.assertLess(time.monotonic(), deadline, "Guardian did not clean up its native group")
                    time.sleep(0.05)
                worker.stdout.close()
            with meeting_lock(root):
                pass


if __name__ == "__main__":
    unittest.main()
