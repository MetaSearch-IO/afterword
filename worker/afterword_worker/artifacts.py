from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import re
import wave

from .protocol import WorkerError


SOURCES = {"microphone", "system"}
NOTE_FIELDS = ("overview", "discussion_points", "decisions", "open_questions")
SELF_COMMITMENT = re.compile(r"^(?:I (?:will|shall|am going to|am responsible for)\b|I['’]ll\b|我(?:会|来|将|负责|承担)|由我(?:来|负责|承担))", re.IGNORECASE)


def require(condition, message):
    if not condition:
        raise WorkerError("invalid_artifact", message)


def identifier(value):
    require(isinstance(value, str) and re.fullmatch(r"[A-Za-z0-9_-]{1,128}", value), "Invalid artifact identifier.")
    return value


def relative(root: Path, value: str) -> Path:
    require(isinstance(value, str) and value and not value.startswith("/")
            and "\\" not in value and "\0" not in value
            and all(part not in {"", ".", ".."} for part in value.split("/")), "Invalid artifact path.")
    path = root / value
    require(path.resolve().is_relative_to(root.resolve()), "Artifact path escapes its meeting.")
    return path


def read_json(path: Path, limit: int = 16 * 1024 * 1024):
    require(path.stat().st_size <= limit, "JSON artifact exceeds the size limit.")
    try:
        return json.loads(path.read_bytes(), parse_constant=lambda _: (_ for _ in ()).throw(ValueError()))
    except (ValueError, UnicodeError):
        raise WorkerError("invalid_artifact", "An artifact is not valid JSON.") from None


def read_versioned(path: Path):
    value = read_json(path)
    require(isinstance(value, dict) and value.get("schema_version") == 1, "Unsupported artifact schema version.")
    return value


def digest(value) -> str:
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False,
                                     allow_nan=False).encode()).hexdigest()


def file_hash(path: Path, check=lambda: None) -> str:
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            check()
            result.update(block)
    return result.hexdigest()


def atomic_json(path: Path, value):
    require(not path.exists(), "An immutable artifact already exists.")
    temporary = path.with_name(path.name + ".partial")
    with temporary.open("x", encoding="utf-8") as stream:
        json.dump(value, stream, ensure_ascii=False, allow_nan=False, separators=(",", ":"))
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    os.link(temporary, path)
    temporary.unlink()


def validate_prepared(root: Path, value: dict, run_id: str, meeting_id: str):
    require(value.get("schema_version") == 1 and value.get("run_id") == run_id
            and value.get("meeting_id") == meeting_id and value.get("sample_rate") == 16_000,
            "Prepared audio does not match this run.")
    require(isinstance(value.get("sources"), list), "Prepared audio sources are missing.")
    seen = set()
    for source in value["sources"]:
        name = source.get("source")
        require(name in SOURCES and name not in seen, "Invalid or duplicate audio source.")
        seen.add(name)
        path = relative(root, source.get("relative_path"))
        with wave.open(str(path), "rb") as audio:
            require((audio.getnchannels(), audio.getsampwidth(), audio.getframerate(), audio.getcomptype())
                    == (1, 2, 16_000, "NONE"), "Prepared audio must be mono 16 kHz PCM16 WAV.")
            total = audio.getnframes()
        require(isinstance(source.get("pieces"), list), "Prepared timeline pieces are missing.")
        previous_sample = previous_time = 0
        for piece in source["pieces"]:
            start, end, timestamp = (piece.get(key) for key in ("sample_start", "sample_end", "meeting_start_us"))
            require(all(type(item) is int for item in (start, end, timestamp))
                    and start == previous_sample and end > start and timestamp >= previous_time,
                    "Prepared audio has invalid timeline pieces.")
            previous_sample = end
            previous_time = timestamp + (end - start) * 1_000_000 // 16_000
        require(previous_sample == total, "Prepared timeline does not cover exactly the WAV frames.")
    return value


def map_interval(start: int, end: int, pieces: list[dict]):
    require(type(start) is int and type(end) is int and 0 <= start < end, "Invalid model time interval.")
    result = []
    for piece in pieces:
        lower, upper = max(start, piece["sample_start"]), min(end, piece["sample_end"])
        if upper > lower:
            origin = piece["meeting_start_us"]
            result.append((origin + (lower - piece["sample_start"]) * 1_000_000 // 16_000,
                           origin + (upper - piece["sample_start"]) * 1_000_000 // 16_000))
    return result


def validate_transcript(value: dict, meeting_id: str, revision_id: str):
    require(value.get("schema_version") == 1 and value.get("meeting_id") == meeting_id
            and value.get("revision_id") == revision_id, "Transcript revision does not match.")
    identifier(value.get("run_id"))
    require(isinstance(value.get("speakers"), list) and isinstance(value.get("segments"), list), "Transcript arrays are missing.")
    speakers = {}
    for speaker in value["speakers"]:
        sid = identifier(speaker.get("id"))
        require(sid not in speakers and speaker.get("source") in SOURCES and isinstance(speaker.get("label"), str),
                "Invalid transcript speaker.")
        speakers[sid] = speaker
    seen = set()
    previous = -1
    for segment in value["segments"]:
        sid = identifier(segment.get("id"))
        start, end = segment.get("start_us"), segment.get("end_us")
        require(sid not in seen and segment.get("source") in SOURCES
                and type(start) is int and type(end) is int and 0 <= start < end and start >= previous
                and isinstance(segment.get("text"), str) and 0 < len(segment["text"].strip()) <= 32_000
                and type(segment.get("overlap")) is bool and isinstance(segment.get("attribution_reason"), str),
                "Invalid transcript segment.")
        speaker = segment.get("speaker_id")
        require(speaker is None or (speaker in speakers and speakers[speaker]["source"] == segment["source"]),
                "Transcript references an unknown speaker.")
        require(not segment["overlap"] or speaker is None or segment["source"] == "microphone",
                "Overlapping remote speech cannot have certain attribution.")
        seen.add(sid)
        previous = start
    require(isinstance(value.get("coverage"), list) and isinstance(value.get("warnings"), list), "Transcript coverage is missing.")
    for segment in value["segments"]:
        require(any(piece.get("source") == segment["source"] and piece.get("start_us", -1) <= segment["start_us"]
                    and piece.get("end_us", -1) >= segment["end_us"] for piece in value["coverage"]),
                "Transcript crosses a gap in retained audio.")
    return value


def validate_notes(value: dict, segments: list[dict], allowed: set[str] | None = None):
    require(isinstance(value, dict), "Summary must be a JSON object.")
    index = {segment["id"]: segment for segment in segments}
    allowed = set(index) if allowed is None else allowed
    for field in (*NOTE_FIELDS, "action_items"):
        items = value.get(field)
        require(isinstance(items, list) and len(items) <= 512, "Summary fields must be bounded arrays.")
        for item in items:
            require(isinstance(item, dict) and isinstance(item.get("text"), str)
                    and 0 < len(item["text"].strip()) <= 8000, "A summary note is invalid.")
            refs = item.get("segment_ids")
            require(isinstance(refs, list) and refs and all(isinstance(ref, str) and ref in allowed for ref in refs)
                    and len(set(refs)) == len(refs), "Summary references invalid transcript evidence.")
            if field != "action_items":
                continue
            require(len(refs) == 1 and item["text"] in index[refs[0]]["text"],
                    "Action text must quote exactly one source segment, preserving its named owner.")
            for key, evidence_key in (("owner_speaker_id", "owner_evidence_segment_ids"), ("due_date", "due_date_evidence_segment_ids")):
                require(key in item and evidence_key in item, "Action evidence fields are missing.")
                evidence = item[evidence_key]
                require(isinstance(evidence, list) and all(ref in refs for ref in evidence), "Action evidence must support this action.")
                if item[key] is None:
                    require(not evidence, "Null action attributes must not claim evidence.")
                else:
                    require(isinstance(item[key], str) and evidence, "Action attributes require explicit evidence.")
                    if key == "owner_speaker_id":
                        require(SELF_COMMITMENT.match(item["text"]) is not None
                                and any(index[ref].get("speaker_id") == item[key] for ref in evidence),
                                "Action owner requires an explicit first-person commitment in its exact evidence quote.")
                    else:
                        require(any(item[key].casefold() in index[ref]["text"].casefold() for ref in evidence), "Action due date is not explicit in its evidence.")
    return value


def validate_summary(value, transcript, summary_id):
    require(value.get("schema_version") == 1 and value.get("meeting_id") == transcript["meeting_id"]
            and value.get("revision_id") == transcript["revision_id"] and value.get("summary_id") == summary_id
            and isinstance(value.get("name_map_revision"), str), "Summary identity does not match.")
    identifier(value.get("run_id"))
    coverage = value.get("covered_segment_ids")
    require(isinstance(coverage, list) and len(coverage) == len(set(coverage))
            and set(coverage) == {s["id"] for s in transcript["segments"]}, "Summary does not cover the full transcript.")
    return validate_notes(value, transcript["segments"])
