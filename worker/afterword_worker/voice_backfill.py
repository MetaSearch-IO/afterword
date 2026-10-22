from __future__ import annotations

import argparse
import os
from pathlib import Path
import wave

from .artifacts import file_hash, read_versioned, relative, validate_prepared
from .inference import validate_turns
from .protocol import meeting_lock
from .voice_profiles import MEETING_ID, assign_profiles, embedding_fingerprint, load_prior_profiles, save_profiles, unit_vector


RATE = 16_000
CLIP_FRAMES = 3 * RATE


def backfill_meeting(root: Path, runtime: dict, embed_clip, extra_prior=(), make_id=None):
    meeting = read_versioned(root / "meeting.json")
    if meeting.get("id") != root.name or not MEETING_ID.fullmatch(root.name) \
            or meeting.get("audio_removed_at") is not None or meeting.get("audio_removal_started_at") is not None:
        return None
    revision_id = meeting.get("active_revision_id")
    if not isinstance(revision_id, str):
        return None
    transcript = read_versioned(relative(root, f"revisions/{revision_id}/transcript.json"))
    run_id = transcript.get("run_id")
    if not isinstance(run_id, str) or transcript.get("meeting_id") != meeting.get("id"):
        return None
    provenance = read_versioned(relative(root, f"revisions/{revision_id}/provenance.json"))
    corrections = provenance.get("speaker_corrections", [])
    if corrections:
        if not isinstance(corrections, list) or not isinstance(corrections[0], dict):
            return None
        revision_id = corrections[0].get("parent_revision_id")
        if not isinstance(revision_id, str):
            return None
        transcript = read_versioned(relative(root, f"revisions/{revision_id}/transcript.json"))
        run_id = transcript.get("run_id")
        if transcript.get("meeting_id") != meeting["id"] or not isinstance(run_id, str):
            return None
    prepared_path = relative(root, f"work/{run_id}/prepared.json")
    turns_path = relative(root, f"work/{run_id}/diarization.json")
    if not prepared_path.is_file() or not turns_path.is_file():
        return None
    prepared = validate_prepared(root, read_versioned(prepared_path),
                                 run_id, meeting["id"])
    turns = read_versioned(turns_path)
    source = next((item for item in prepared.get("sources", []) if item.get("source") == "system"), None)
    if source is None or not isinstance(turns.get("exclusive"), list) or not isinstance(turns.get("regular"), list):
        return None
    audio_path = relative(root, source["relative_path"])
    if not audio_path.is_file():
        return None
    validate_turns(turns, source["pieces"][-1]["sample_end"])
    fingerprint = embedding_fingerprint(runtime)
    if fingerprint is None:
        raise ValueError("The embedding model has no pinned fingerprint.")
    labels = sorted({turn["speaker"] for turn in turns["exclusive"]})
    speaker_ids = {label: f"remote-{index + 1:03d}" for index, label in enumerate(labels)}
    vectors = {}
    with wave.open(str(audio_path), "rb") as audio:
        if (audio.getframerate(), audio.getnchannels(), audio.getsampwidth()) != (RATE, 1, 2):
            raise ValueError("Prepared system audio is not 16 kHz mono PCM.")
        for label in labels:
            clean = []
            for turn in turns["exclusive"]:
                if turn["speaker"] != label or turn["sample_end"] - turn["sample_start"] < CLIP_FRAMES:
                    continue
                start = (turn["sample_start"] + turn["sample_end"] - CLIP_FRAMES) // 2
                end = start + CLIP_FRAMES
                if any(other["speaker"] != label and other["sample_start"] < end and other["sample_end"] > start
                       for other in turns["regular"]):
                    continue
                clean.append(start)
            if len(clean) < 2:
                continue
            count = min(5, len(clean))
            selected = [clean[index * (len(clean) - 1) // (count - 1)] for index in range(count)]
            samples = []
            for start in selected:
                audio.setpos(start)
                raw = audio.readframes(CLIP_FRAMES)
                if len(raw) != CLIP_FRAMES * 2:
                    raise ValueError("Prepared system audio ended before a selected speaker turn.")
                vector = unit_vector(embed_clip(raw))
                if vector is not None:
                    samples.append(vector)
            if len(samples) < 2:
                continue
            vectors[speaker_ids[label]] = unit_vector([sum(vector[index] for vector in samples) / len(samples)
                                                       for index in range(len(samples[0]))])
    vectors = {speaker: vector for speaker, vector in vectors.items() if vector is not None}
    if not vectors:
        return None
    prior = load_prior_profiles(root, fingerprint, len(next(iter(vectors.values())))) + list(extra_prior)
    options = {"make_id": make_id} if make_id is not None else {}
    return assign_profiles(meeting["id"], revision_id, run_id, fingerprint, vectors, prior, **options)


def main():
    parser = argparse.ArgumentParser(description="Backfill local voice profiles from retained meeting audio.")
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--meeting", type=Path, action="append", required=True)
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    runtime = read_versioned(args.runtime)
    fingerprint = embedding_fingerprint(runtime)
    model_root = Path(runtime["diarization_model"])
    model_file = model_root / "embedding/pytorch_model.bin"
    if fingerprint is None or not model_file.is_file() or file_hash(model_file) != fingerprint:
        parser.error("The pinned local embedding model is unavailable or changed.")
    roots = [path.resolve() for path in args.meeting]
    if len({root.parent for root in roots}) != 1 or any(path.is_symlink() or not path.is_dir()
                                                     or not MEETING_ID.fullmatch(root.name)
                                                     for path, root in zip(args.meeting, roots)):
        parser.error("Meetings must be real directories under one local meetings root.")
    os.environ.setdefault("HF_HUB_OFFLINE", "1")
    os.environ.setdefault("TRANSFORMERS_OFFLINE", "1")
    os.environ.setdefault("OMP_NUM_THREADS", "2")
    os.environ.setdefault("MKL_NUM_THREADS", "2")
    import numpy as np
    import torch
    from pyannote.audio.pipelines.speaker_verification import PretrainedSpeakerEmbedding

    torch.set_num_threads(2)
    embedder = PretrainedSpeakerEmbedding({"checkpoint": str(model_root), "subfolder": "embedding"})

    def embed_clip(raw):
        waveform = torch.from_numpy(np.frombuffer(raw, dtype="<i2").astype(np.float32) / 32768).reshape(1, 1, -1)
        return embedder(waveform).reshape(-1).tolist()

    pending = []
    for root in roots:
        known_ids = {profile["voice_id"] for profile in pending}
        known_ids.update(profile["voice_id"] for profile in load_prior_profiles(root, fingerprint, 256))
        if args.apply:
            with meeting_lock(root):
                value = backfill_meeting(root, runtime, embed_clip, pending)
                if value is not None:
                    save_profiles(root, value)
        else:
            value = backfill_meeting(root, runtime, embed_clip, pending)
        if value is None:
            print(f"{root.name}: no eligible saved speaker turns")
            continue
        matched = sum(profile["voice_id"] in known_ids for profile in value["profiles"])
        pending.extend({"voice_id": item["voice_id"], "vector": item["vector"]} for item in value["profiles"])
        print(f"{root.name}: {len(value['profiles'])} voices, {matched} matched, {'saved' if args.apply else 'preview only'}")


if __name__ == "__main__":
    main()
