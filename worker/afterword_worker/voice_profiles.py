from __future__ import annotations

import json
import math
import os
from pathlib import Path
import re
import uuid


PROFILE_NAME = "voice_profiles.json"
MATCH_MINIMUM = 0.65
MATCH_MARGIN = 0.15
MAX_PROFILE_BYTES = 1_048_576
MAX_PRIOR_PROFILES = 256
MAX_SCANNED_MEETINGS = 512
MEETING_ID = re.compile(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\Z")
VOICE_ID = re.compile(r"[0-9a-f]{32}\Z")
FINGERPRINT = re.compile(r"[0-9a-f]{64}\Z")


def unit_vector(value, dimension=None):
    if not isinstance(value, (list, tuple)) or not 2 <= len(value) <= 1024:
        return None
    if dimension is not None and len(value) != dimension:
        return None
    if any(type(item) not in (int, float) or not math.isfinite(item) for item in value):
        return None
    length = math.sqrt(sum(item * item for item in value))
    if not math.isfinite(length) or length < 1e-6:
        return None
    return [round(item / length, 8) for item in value]


def voice_label(voice_id):
    return "Voice " + voice_id[:8].upper()


def embedding_fingerprint(runtime):
    files = runtime.get("models", {}).get("diarization", {}).get("files", [])
    matches = [entry.get("sha256") for entry in files if isinstance(entry, dict)
               and isinstance(entry.get("path"), str)
               and tuple(Path(entry["path"]).parts[-2:]) == ("embedding", "pytorch_model.bin")]
    return matches[0] if len(matches) == 1 and isinstance(matches[0], str) \
        and FINGERPRINT.fullmatch(matches[0]) else None


def load_prior_profiles(meeting_root: Path, model_fingerprint: str, dimension: int, check=lambda: None):
    profiles = []
    for index, child in enumerate(meeting_root.parent.iterdir()):
        check()
        if index >= MAX_SCANNED_MEETINGS or len(profiles) >= MAX_PRIOR_PROFILES:
            break
        if not MEETING_ID.fullmatch(child.name) or child.is_symlink() or not child.is_dir():
            continue
        path = child / PROFILE_NAME
        try:
            if path.is_symlink() or not path.is_file() or path.stat().st_size > MAX_PROFILE_BYTES:
                continue
            value = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, UnicodeError, ValueError):
            continue
        if not isinstance(value, dict) or value.get("schema_version") != 1 \
                or value.get("meeting_id") != child.name or value.get("model_fingerprint") != model_fingerprint \
                or not isinstance(value.get("profiles"), list) or len(value["profiles"]) > 64 \
                or not isinstance(value.get("retained", []), list) \
                or len(value["profiles"]) + len(value.get("retained", [])) > MAX_PRIOR_PROFILES:
            continue
        for profile in value["profiles"] + value.get("retained", []):
            if len(profiles) >= MAX_PRIOR_PROFILES:
                break
            if not isinstance(profile, dict) or not isinstance(profile.get("voice_id"), str) \
                    or not VOICE_ID.fullmatch(profile["voice_id"]):
                continue
            vector = unit_vector(profile.get("vector"), dimension)
            if vector is not None:
                profiles.append({"voice_id": profile["voice_id"], "vector": vector})
    return profiles


def save_profiles(meeting_root: Path, value: dict):
    path = meeting_root / PROFILE_NAME
    if path.is_symlink():
        raise ValueError("A voice profile cannot replace a symbolic link.")
    if path.is_file() and path.stat().st_size <= MAX_PROFILE_BYTES:
        try:
            previous = json.loads(path.read_text(encoding="utf-8"))
            if previous.get("schema_version") == 1 and previous.get("meeting_id") == value.get("meeting_id") \
                    and previous.get("model_fingerprint") == value.get("model_fingerprint"):
                current = {item["voice_id"] for item in value["profiles"]}
                history = previous.get("profiles", []) + previous.get("retained", [])
                value = {**value, "retained": [
                    {"voice_id": item["voice_id"], "vector": item["vector"]}
                    for item in history if isinstance(item, dict) and item.get("voice_id") not in current
                    and VOICE_ID.fullmatch(item.get("voice_id", ""))
                    and unit_vector(item.get("vector")) is not None
                ][:MAX_PRIOR_PROFILES - len(value["profiles"])]}
        except (OSError, UnicodeError, ValueError, TypeError, KeyError):
            pass
    encoded = json.dumps(value, ensure_ascii=False, allow_nan=False, separators=(",", ":")) + "\n"
    if len(encoded.encode("utf-8")) > MAX_PROFILE_BYTES:
        raise ValueError("Voice profiles exceed their size limit.")
    temporary = meeting_root / f".{PROFILE_NAME}.{uuid.uuid4().hex}.partial"
    try:
        with temporary.open("x", encoding="utf-8") as stream:
            stream.write(encoded)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def assign_profiles(meeting_id: str, revision_id: str, run_id: str, model_fingerprint: str,
                    current: dict[str, list[float]], prior: list[dict], make_id=lambda: uuid.uuid4().hex):
    vectors = {speaker: vector for speaker, value in current.items()
               if (vector := unit_vector(value)) is not None}
    candidates = []
    for speaker, vector in vectors.items():
        scores = {}
        for profile in prior:
            other = unit_vector(profile.get("vector"), len(vector))
            voice_id = profile.get("voice_id")
            if other is None or not isinstance(voice_id, str) or not VOICE_ID.fullmatch(voice_id):
                continue
            score = sum(a * b for a, b in zip(vector, other))
            scores[voice_id] = max(score, scores.get(voice_id, -1.0))
        ranked = sorted(scores.items(), key=lambda item: item[1], reverse=True)
        if ranked and ranked[0][1] >= MATCH_MINIMUM \
                and (len(ranked) == 1 or ranked[0][1] - ranked[1][1] >= MATCH_MARGIN):
            candidates.append((ranked[0][1], speaker, ranked[0][0]))
    assigned = {}
    used = set()
    for _, speaker, voice_id in sorted(candidates, reverse=True):
        if voice_id not in used:
            assigned[speaker] = voice_id
            used.add(voice_id)
    profiles = []
    for speaker, vector in sorted(vectors.items()):
        voice_id = assigned.get(speaker) or make_id()
        profiles.append({"speaker_id": speaker, "voice_id": voice_id, "vector": vector})
    return {"schema_version": 1, "meeting_id": meeting_id, "revision_id": revision_id,
            "run_id": run_id, "model_fingerprint": model_fingerprint, "profiles": profiles}
