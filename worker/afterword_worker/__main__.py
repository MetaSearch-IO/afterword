import argparse
from pathlib import Path
import sys
import tomllib

from .artifacts import identifier
from .protocol import Cancelled, Control, WorkerError


def main() -> int:
    metadata_path = Path(__file__).resolve().parents[1] / "pyproject.toml"
    with metadata_path.open("rb") as metadata_file:
        version = tomllib.load(metadata_file)["project"]["version"]

    parser = argparse.ArgumentParser(
        prog="afterword-worker",
        description="Offline Afterword processing worker."
    )
    parser.add_argument("--version", action="version", version=f"%(prog)s {version}")
    subparsers = parser.add_subparsers(dest="command")
    process = subparsers.add_parser("process")
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
    args = parser.parse_args()
    if args.command != "process":
        parser.print_help()
        return 0
    try:
        identifier(args.run_id)
    except WorkerError:
        parser.error("Invalid run ID")
    control = Control(args.run_id, progress_events=args.progress_events)
    try:
        from .pipeline import process as run_process
        run_process(args, control)
        return 0
    except Cancelled:
        control.emit("cancelled", stage=control.stage)
        return 2
    except WorkerError as error:
        control.emit("failed", stage=control.stage, code=error.code, message=str(error))
        return 1
    except (OSError, ValueError, KeyError, TypeError, AttributeError, EOFError):
        control.emit("failed", stage=control.stage, code="processing", message="Processing could not read, validate, or publish its local artifacts.")
        return 1


if __name__ == "__main__":
    sys.exit(main())
