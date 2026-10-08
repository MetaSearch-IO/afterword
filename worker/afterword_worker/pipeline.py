from __future__ import annotations

import hashlib
import os
from pathlib import Path
import stat
import time

from .artifacts import (atomic_json, digest, file_hash, identifier, read_versioned, relative, require,
                        validate_prepared, validate_summary, validate_transcript)
from .inference import ALIGNMENT_VERSION, ASR_VERSION, RATE, VAD_OPTIONS, align, diarize, transcribe
from .protocol import WorkerError, meeting_lock
from .summary import (INSTRUCTIONS, MODEL_SCHEMA, SummaryEngine, extraction_identity,
                      recover_extraction_checkpoint, summarize, validate_extraction_checkpoint)


def committed_fingerprint(meeting):
    lines = []
    for chunk in sorted(meeting["chunks"], key=lambda item: item["id"]):
        lines.append("|".join(str(chunk[key]) for key in ("id", "source", "generation", "start_us", "frame_count"))
                     + f"|{float(chunk['sample_rate']):.6f}|{chunk['channel_count']}|{chunk['relative_path']}\n")
    return hashlib.sha256("".join(lines).encode()).hexdigest()


def runtime_preflight(runtime, keys):
    for key in keys:
        value = runtime.get(key)
        if not isinstance(value, str) or not Path(value).is_absolute() or not Path(value).is_file():
            raise WorkerError("setup", f"Local runtime asset '{key}' is missing. Complete runtime setup before retrying.")
        if key in {"python", "whisper_cli", "vad_cli", "llama_completion", "llama_tokenize", "llama_summary_batch"} and not os.access(value, os.X_OK):
            raise WorkerError("setup", f"Local runtime executable '{key}' is not executable.")


def runtime_hashes(runtime, keys, control):
    expected = {}
    for component in runtime.get("native", {}).values():
        expected.update({entry["path"]: entry["sha256"] for entry in component.get("executables", {}).values()})
    for model in runtime.get("models", {}).values():
        expected.update({entry["path"]: entry["sha256"] for entry in model.get("files", [])})
    result = {}
    for key in keys:
        path = runtime[key]
        result[key] = file_hash(Path(path), control.check)
        if path in expected:
            require(result[key] == expected[path], "A local runtime asset failed its pinned integrity check.")
        if key.endswith("_model"):
            for entry in runtime.get("models", {}).get(key.removesuffix("_model"), {}).get("files", []):
                if entry["path"] == path:
                    continue
                shard = Path(entry["path"])
                require(shard.is_absolute() and shard.is_file(), "A required local model shard is missing.")
                fingerprint = file_hash(shard, control.check)
                require(fingerprint == entry["sha256"], "A local model shard failed its pinned integrity check.")
                result[f"{key}/{shard.name}"] = fingerprint
    return result


def validate_asr(segments, prepared):
    require(isinstance(segments, list), "Invalid ASR checkpoint.")
    sources = {source["source"]: source for source in prepared["sources"]}
    for segment in segments:
        require(isinstance(segment, dict) and segment.get("source") in sources and isinstance(segment.get("text"), str)
                and 0 < len(segment["text"].strip()) <= 32_000 and type(segment.get("sample_start")) is int
                and type(segment.get("sample_end")) is int and 0 <= segment["sample_start"] < segment["sample_end"],
                "Invalid ASR checkpoint segment.")
        require(any(piece["sample_start"] <= segment["sample_start"] < segment["sample_end"] <= piece["sample_end"]
                    for piece in sources[segment["source"]]["pieces"]), "ASR checkpoint crosses a timeline gap.")
        if "speech_sample_start" in segment or "speech_sample_end" in segment:
            lower, upper = segment.get("speech_sample_start"), segment.get("speech_sample_end")
            padding = max(0, VAD_OPTIONS["padding_ms"] - 10) * RATE // 1000
            require(type(lower) is int and type(upper) is int
                    and segment["sample_start"] <= lower < upper <= segment["sample_end"]
                    and lower - segment["sample_start"] <= padding and segment["sample_end"] - upper <= padding,
                    "ASR checkpoint has invalid VAD padding support.")
    return segments


def checkpoint(root, fingerprint, prepared):
    directory = relative(root, "work")
    candidates = sorted(directory.glob("*/asr.json"), key=lambda path: path.stat().st_mtime, reverse=True)[:32]
    for candidate in candidates:
        try:
            candidate = relative(root, str(candidate.relative_to(root)))
            value = read_versioned(candidate)
            if value.get("input_fingerprint") == fingerprint:
                return validate_asr(value.get("segments"), prepared)
        except (WorkerError, OSError, ValueError, TypeError):
            continue
    return None


def summary_checkpoint(root, work, transcript, names, models, engine, control):
    identity = extraction_identity(transcript, names, models, engine.context, engine.reserve, engine.execution_identity)
    candidates = []
    for candidate in relative(root, "work").iterdir():
        control.check()
        try:
            info = candidate.lstat()
        except OSError:
            continue
        if candidate != work and stat.S_ISDIR(info.st_mode):
            candidates.append((info.st_mtime_ns, candidate))
    for _, candidate in sorted(candidates, key=lambda item: item[0], reverse=True)[:32]:
        control.check()
        try:
            candidate = relative(root, str(candidate.relative_to(root)))
            path = relative(root, str((candidate / "summary-extraction.json").relative_to(root)))
            if path.is_file():
                validate_extraction_checkpoint(read_versioned(path), transcript, identity)
                return path
            if engine.execution_identity is not None and next(candidate.glob("extraction-summary-*.json"), None):
                recovered = recover_extraction_checkpoint(candidate, transcript, names, models, models,
                                                          engine.context, engine.reserve, engine.execution_identity)
            else:
                continue
        except (WorkerError, OSError, ValueError, TypeError, KeyError):
            continue
        path = work / "summary-extraction-recovered.json"
        atomic_json(path, recovered)
        return path
    return None


def process(args, control):
    root = Path(args.meeting)
    require(root.is_absolute() and root.is_dir(), "Meeting directory must be an existing absolute path.")
    root = root.resolve()
    for value in (args.run_id, args.revision_id, args.summary_id):
        identifier(value)
    runtime_path = Path(args.runtime)
    require(runtime_path.is_absolute(), "Runtime configuration path must be absolute.")
    runtime = read_versioned(runtime_path)
    language = getattr(args, "language", "auto")
    require(language in {"auto", "zh", "en"}, "Unsupported transcription language.")
    transcript_first = getattr(args, "transcript_first", False)
    require(not transcript_first or args.run_id != args.revision_id, "Transcript-first processing requires distinct run and final revision IDs.")
    language_policy = ("per-utterance-auto-en-zh-preserve" if language == "auto"
                       and runtime.get("native", {}).get("whisper", {}).get("auto_language_en_zh") is True
                       else f"per-utterance-{language}-preserve")
    with meeting_lock(root) as lock_fd:
        control.lock_fd = lock_fd
        control.check()
        meeting = read_versioned(relative(root, "meeting.json"))
        meeting_id = identifier(meeting.get("id"))
        require(meeting.get("capture_state") in {"stopped", "interrupted"}, "Capture must finish before processing.")
        if transcript_first and not args.summary_only:
            preview = relative(root, f"revisions/{args.run_id}")
            require(not preview.exists() and not preview.is_symlink(), "Transcript-first processing must use a new preview revision ID.")
        committed = committed_fingerprint(meeting)
        work = relative(root, f"work/{args.run_id}")
        work.mkdir(parents=True, exist_ok=True)
        marker = work / ".worker-started"
        try:
            marker.touch(exist_ok=False)
        except FileExistsError:
            raise WorkerError("run_id", "A processing run ID cannot be reused.") from None
        control.emit("started", meeting_id=meeting_id, revision_id=args.revision_id)
        names, name_revision = {}, digest({})
        if args.names:
            value = read_versioned(relative(root, args.names))
            names = value.get("speaker_names")
            name_revision = value.get("name_map_revision")
            require(isinstance(names, dict) and all(isinstance(key, str) and isinstance(name, str) and len(name) <= 200 for key, name in names.items())
                    and isinstance(name_revision, str) and len(name_revision) <= 128, "Invalid speaker name map.")
            require(args.summary_only or not names, "Full regeneration cannot reuse names from an earlier transcript revision.")
        revision = relative(root, f"revisions/{args.revision_id}")
        transcript_path = revision / "transcript.json"
        provenance_path = revision / "provenance.json"
        started = time.monotonic()
        if args.summary_only:
            control.begin("alignment")
            transcript = validate_transcript(read_versioned(transcript_path), meeting_id, args.revision_id)
            provenance = read_versioned(provenance_path)
            require(provenance.get("meeting_id") == meeting_id and provenance.get("revision_id") == args.revision_id
                    and provenance.get("committed_audio_fingerprint") == committed,
                    "The transcript does not match the retained source audio.")
        else:
            require(args.prepared is not None, "Prepared audio is required for a full processing run.")
            require(not revision.exists(), "Full processing must use a new revision ID.")
            control.begin("preparation")
            prepared = validate_prepared(root, read_versioned(relative(root, args.prepared)), args.run_id, meeting_id)
            fingerprints = {source["source"]: file_hash(relative(root, source["relative_path"]), control.check) for source in prepared["sources"]}
            runtime_preflight(runtime, ["python", "whisper_cli", "vad_cli", "asr_model", "vad_model"])
            verified = runtime_hashes(runtime, ["whisper_cli", "vad_cli", "asr_model", "vad_model"], control)
            asr_key = digest({"version": ASR_VERSION, "language_policy": language_policy, "asr_language": language, "vad_options": VAD_OPTIONS,
                              "prepared": fingerprints,
                              "verified_assets": verified,
                              "pieces": {source["source"]: source["pieces"] for source in prepared["sources"]},
                              "models": {key: runtime.get("models", {}).get(key) for key in ("asr", "vad")},
                              "paths": {key: runtime[key] for key in ("asr_model", "vad_model", "whisper_cli")},
                              "whisper": runtime.get("native", {}).get("whisper")})
            control.emit("stage_completed", stage="preparation", artifacts=[args.prepared], input_fingerprint=asr_key)
            control.begin("asr")
            segments = checkpoint(root, asr_key, prepared)
            reused = segments is not None
            if segments is None:
                segments = validate_asr(transcribe(control, root, work, prepared, runtime, language=language), prepared)
            control.check()
            atomic_json(work / "asr.json", {"schema_version": 1, "run_id": args.run_id,
                                          "input_fingerprint": asr_key, "segments": segments})
            control.emit("stage_completed", stage="asr", artifacts=[f"work/{args.run_id}/asr.json"], input_fingerprint=asr_key, reused=reused)

            def publish_transcript(revision_id, turns):
                transcript = validate_transcript(align(segments, turns, prepared, meeting_id, revision_id, args.run_id), meeting_id, revision_id)
                provenance = {"schema_version": 1, "run_id": args.run_id, "meeting_id": meeting_id, "revision_id": revision_id,
                              "input_fingerprint": digest({"asr": asr_key, "diarization": runtime.get("models", {}).get("diarization") if turns["mode"] != "deferred" else None,
                                                           "diarization_mode": turns["mode"], "diarization_status": turns["status"],
                                                           "diarization_execution": turns.get("execution"), "alignment": ALIGNMENT_VERSION}),
                              "diarization_mode": turns["mode"], "diarization_status": turns["status"],
                              "diarization_execution": turns.get("execution"),
                              "preparation_version": 1, "alignment_version": ALIGNMENT_VERSION, "language_policy": language_policy, "asr_language": language,
                              "runtime": runtime, "prepared_fingerprints": fingerprints, "committed_audio_fingerprint": committed}
                staging = work / "revision.partial"
                staging.mkdir()
                atomic_json(staging / "transcript.json", transcript)
                atomic_json(staging / "provenance.json", provenance)
                (staging / "summaries").mkdir()
                relative(root, "revisions").mkdir(exist_ok=True)
                destination = relative(root, f"revisions/{revision_id}")
                control.check()
                require(not destination.exists() and not destination.is_symlink(), "Revision already exists.")
                staging.rename(destination)
                return transcript, provenance

            has_remote_speech = any(segment["source"] == "system" for segment in segments)
            if transcript_first and has_remote_speech:
                control.begin("transcript")
                _, preview_provenance = publish_transcript(args.run_id, {"regular": [], "exclusive": [], "mode": "deferred", "status": "pending"})
                paths = [f"revisions/{args.run_id}/transcript.json", f"revisions/{args.run_id}/provenance.json"]
                control.emit("stage_completed", stage="transcript", revision_id=args.run_id,
                             transcript_path=paths[0], provenance_path=paths[1], artifacts=paths,
                             input_fingerprint=preview_provenance["input_fingerprint"])
            control.begin("diarization")
            if has_remote_speech:
                model_root = runtime.get("diarization_model")
                entries = runtime.get("models", {}).get("diarization", {}).get("files", [])
                if model_root and Path(model_root).is_dir():
                    require(entries, "The diarization snapshot has no pinned integrity manifest. Run model setup again.")
                    for entry in entries:
                        path = Path(entry["path"])
                        require(path.resolve().is_relative_to(Path(model_root).resolve())
                                and file_hash(path, control.check) == entry["sha256"],
                                "The local diarization model failed its pinned integrity check.")
            turns = diarize(control, root, work, prepared, runtime, segments,
                            allow_unknown_speakers=getattr(args, "allow_unknown_speakers", False))
            atomic_json(work / "diarization-checkpoint.json", {"schema_version": 1, "run_id": args.run_id, **turns})
            control.emit("stage_completed", stage="diarization", artifacts=[f"work/{args.run_id}/diarization-checkpoint.json"], input_fingerprint=asr_key)
            control.begin("alignment")
            transcript, provenance = publish_transcript(args.revision_id, turns)
        control.emit("stage_completed", stage="alignment", revision_id=args.revision_id,
                     transcript_path=str(transcript_path.relative_to(root)), provenance_path=str(provenance_path.relative_to(root)),
                     artifacts=[str(transcript_path.relative_to(root)), str(provenance_path.relative_to(root))],
                     input_fingerprint=provenance["input_fingerprint"])
        speaker_ids = {speaker["id"] for speaker in transcript["speakers"]}
        require(set(names).issubset(speaker_ids), "Speaker names belong to a different transcript revision.")
        summary_path = None
        if transcript["segments"]:
            control.begin("summary")
            summary_assets = ["llama_completion", "llama_tokenize", "summary_model"]
            if runtime.get("native", {}).get("summary_batch", {}).get("enabled") is True:
                summary_assets.append("llama_summary_batch")
            runtime_preflight(runtime, summary_assets)
            summary_hashes = runtime_hashes(runtime, summary_assets, control)
            engine = SummaryEngine(control, work, runtime)
            checkpoint_path = relative(root, args.summary_checkpoint) if getattr(args, "summary_checkpoint", None) else None
            if checkpoint_path is None:
                checkpoint_path = summary_checkpoint(root, work, transcript, names, summary_hashes, engine, control)
            notes = summarize(engine, transcript, names, checkpoint_path=checkpoint_path, model_fingerprints=summary_hashes)
            summary = {"schema_version": 1, "run_id": args.run_id, "meeting_id": meeting_id,
                       "revision_id": args.revision_id, "summary_id": args.summary_id, "name_map_revision": name_revision,
                       "runtime_fingerprints": summary_hashes,
                       "summary_policy": {"version": 8, "prompt_sha256": hashlib.sha256(INSTRUCTIONS.encode()).hexdigest(), "schema_sha256": digest(MODEL_SCHEMA),
                                          "map_execution": engine.execution_identity or {"mode": "one_shot"},
                                          "partition_search": "previous_maximum_exact_bracketing_v1",
                                          "action_grounding": "source-id-selection",
                                          "max_evidence_refs_per_note": 4,
                                          "context_tokens": engine.context, "output_reserve_tokens": engine.reserve,
                                          "generation_token_budgets": engine.generation_budgets,
                                          "output_budget_policy": "remaining_context", "extraction_reused": checkpoint_path is not None,
                                          "max_validation_retries": 1, "template": "qwen2.5-chatml"},
                       "covered_segment_ids": [segment["id"] for segment in transcript["segments"]], **notes}
            validate_summary(summary, transcript, args.summary_id)
            summary_path = revision / "summaries" / f"{args.summary_id}.json"
            control.check()
            atomic_json(summary_path, summary)
            control.emit("stage_completed", stage="summary", revision_id=args.revision_id, summary_id=args.summary_id,
                         artifacts=[str(summary_path.relative_to(root))], input_fingerprint=digest({"transcript": transcript, "names": names}))
        control.check()
        validate_transcript(read_versioned(transcript_path), meeting_id, args.revision_id)
        if summary_path:
            validate_summary(read_versioned(summary_path), transcript, args.summary_id)
        control.emit("completed", revision_id=args.revision_id, summary_id=args.summary_id if summary_path else None,
                     transcript_path=str(transcript_path.relative_to(root)), summary_path=str(summary_path.relative_to(root)) if summary_path else None,
                     elapsed_seconds=round(time.monotonic() - started, 3))
