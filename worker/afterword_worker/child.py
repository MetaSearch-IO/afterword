from __future__ import annotations

import argparse
import contextlib
import os
import signal
import subprocess
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--parent", type=int, required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    stopping = False

    def stop(*_):
        nonlocal stopping
        stopping = True

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    process = subprocess.Popen(command, stdin=subprocess.DEVNULL, close_fds=True)
    while process.poll() is None:
        if stopping or os.getppid() != args.parent:
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            with contextlib.suppress(ProcessLookupError):
                os.killpg(os.getpgrp(), signal.SIGTERM)
            time.sleep(0.3)
            os.killpg(os.getpgrp(), signal.SIGKILL)
        time.sleep(0.05)
    return process.returncode


if __name__ == "__main__":
    raise SystemExit(main())
