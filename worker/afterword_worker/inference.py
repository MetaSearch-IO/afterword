from __future__ import annotations

from decimal import Decimal
from pathlib import Path
import re
import wave

from .artifacts import map_interval, read_json, relative, require
from .protocol import WorkerError


RATE = 16_000
WINDOW = 300 * RATE
OVERLAP = 2 * RATE
ASR_VERSION = 6
ALIGNMENT_VERSION = 3
MODEL_WINDOW_SAMPLES = 30 * RATE
VAD_OPTIONS = {"min_speech_ms": 100, "min_silence_ms": 400, "padding_ms": 100}
ASR_BATCH_SIZE = 64


def extract_wav(source: Path, target: Path, start: int, end: int, check=lambda: None) -> bool:
    audible = False
    with wave.open(str(source), "rb") as reader, wave.open(str(target), "wb") as writer:
        writer.setparams((1, 2, RATE, 0, "NONE", "not compressed"))
        reader.setpos(start)
        remaining = end - start
        while remaining:
            check()
            count = min(remaining, RATE * 10)
            data = reader.readframes(count)
            require(len(data) == count * 2, "Prepared audio is truncated.")
            audible = audible or any(data)
            writer.writeframesraw(data)
            remaining -= count
    return audible


def parse_whisper(value: dict, frame_count: int):
    require(type(frame_count) is int and frame_count > 0, "Whisper input has no audio frames.")
    require(isinstance(value, dict) and isinstance(value.get("transcription"), list), "Whisper output is missing transcription data.")
    multilingual = value.get("model", {}).get("multilingual")
    require(multilingual is True, "The configured Whisper model must support Chinese and English.")
    segments = []
    for entry in value["transcription"]:
        require(isinstance(entry, dict) and isinstance(entry.get("text"), str), "Whisper returned an invalid segment.")
        text = entry["text"].strip()
        if not text or re.fullmatch(r"\[.*\]|\(.*\)|<\|.*\|>", text):
            continue
        offsets = entry.get("offsets", {})
        start, end = offsets.get("from"), offsets.get("to")
        require(type(start) is int and type(end) is int and 0 <= start < end,
                "Whisper returned invalid segment offsets.")
        start, end = start * 16, end * 16
        require(end - start <= MODEL_WINDOW_SAMPLES and end <= frame_count + MODEL_WINDOW_SAMPLES,
                "Whisper offsets exceed the decoder's possible audio window.")
        require(start < frame_count, "Whisper interval has no overlap with retained audio.")
        segment = {"sample_start": start, "sample_end": min(end, frame_count), "text": text}
        if end > frame_count + 160:
            segment["timing_ambiguity"] = True
        segments.append(segment)
    require(all(a["sample_start"] <= b["sample_start"] for a, b in zip(segments, segments[1:])), "Whisper segments are unordered.")
    return segments


def parse_vad(text: str, frame_count: int):
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    require(lines and re.fullmatch(r"Detected [0-9]+ speech segments:", lines[0]), "VAD output has an unexpected header.")
    count = int(lines[0].split()[1])
    require(len(lines) == count + 1, "VAD output has an unexpected segment count.")
    ranges = []
    previous_end = 0
    for index, line in enumerate(lines[1:]):
        match = re.fullmatch(r"Speech segment ([0-9]+): start = ([0-9]+\.[0-9]{2}), end = ([0-9]+\.[0-9]{2})", line)
        require(match is not None and int(match[1]) == index, "VAD returned a malformed speech range.")
        start, end = round(Decimal(match[2]) * 160), round(Decimal(match[3]) * 160)
        require(previous_end <= start < end <= frame_count + 320, "VAD speech range exceeds or overlaps the source audio.")
        end = min(end, frame_count)
        require(start < end, "VAD speech range has no source audio.")
        ranges.append((start, end))
        previous_end = end
    return ranges


def speech_support(regions, index: int, frame_count: int):
    start, end = regions[index]
    # Printed VAD boundaries lose up to one centisecond; keep that margin.
    padding = max(0, VAD_OPTIONS["padding_ms"] - 10) * RATE // 1000
    lower = start + padding if start > 0 and (index == 0 or regions[index - 1][1] < start) else start
    upper = end - padding if end < frame_count - 160 and (index + 1 == len(regions) or end < regions[index + 1][0]) else end
    return (lower, upper) if lower < upper else (start, end)


def reconcile_overlap(previous: dict, current: dict) -> bool:
    if previous["sample_end"] <= current["sample_start"] or previous["sample_start"] >= current["sample_end"]:
        return False
    def normalized(text):
        positions = [index for index, char in enumerate(text) if char.isalnum()]
        return "".join(text[index].casefold() for index in positions), positions
    left, _ = normalized(previous["text"])
    right, positions = normalized(current["text"])
    if left == right:
        previous["sample_start"] = min(previous["sample_start"], current["sample_start"])
        previous["sample_end"] = max(previous["sample_end"], current["sample_end"])
        if current.get("timing_ambiguity"):
            previous["timing_ambiguity"] = True
        previous.pop("speech_sample_start", None)
        previous.pop("speech_sample_end", None)
        return True
    for length in range(min(len(left), len(right)), 0, -1):
        match = left[-length:]
        if match != right[:length]:
            continue
        if len(match) < (2 if any(ord(char) > 127 for char in match) else 4):
            continue
        boundary = positions[length - 1] + 1
        if match.isascii() and boundary < len(current["text"]) and current["text"][boundary].isalnum():
            continue
        previous["text"] += current["text"][boundary:]
        previous["sample_start"] = min(previous["sample_start"], current["sample_start"])
        previous["sample_end"] = max(previous["sample_end"], current["sample_end"])
        if current.get("timing_ambiguity"):
            previous["timing_ambiguity"] = True
        previous.pop("speech_sample_start", None)
        previous.pop("speech_sample_end", None)
        return True
    return False


def transcribe(control, root: Path, work: Path, prepared: dict, runtime: dict, language: str = "auto"):
    require(language in {"auto", "zh", "en"}, "Unsupported transcription language.")
    output = []
    window_step = WINDOW - OVERLAP
    window_total = sum(1 + (max(0, piece["sample_end"] - piece["sample_start"] - WINDOW) + window_step - 1) // window_step
                       for source in prepared["sources"] for piece in source["pieces"])
    window_done = 0
    progress = getattr(control, "progress", lambda **_: None)
    if window_total:
        progress(completed=0, total=window_total, unit="audio_windows", phase="windows")
    for source in prepared["sources"]:
        source_path = relative(root, source["relative_path"])
        previous = []
        for piece_index, piece in enumerate(source["pieces"]):
            piece_start, piece_end = piece["sample_start"], piece["sample_end"]
            start = piece_start
            while start < piece_end:
                control.check()
                end = min(start + WINDOW, piece_end)
                name = f"{source['source']}-{piece_index}-{start}"
                wav = work / f"{name}.wav"
                audible = extract_wav(source_path, wav, start, end, control.check)
                if audible:
                    vad_output = work / f"{name}-vad.txt"
                    control.run([runtime["vad_cli"], "--file", str(wav), "--vad-model", runtime["vad_model"],
                                 "--no-prints", "--vad-min-speech-duration-ms", str(VAD_OPTIONS["min_speech_ms"]),
                                 "--vad-min-silence-duration-ms", str(VAD_OPTIONS["min_silence_ms"]),
                                 "--vad-speech-pad-ms", str(VAD_OPTIONS["padding_ms"])], vad_output, limit=1024 * 1024)
                    regions = parse_vad(vad_output.read_text(encoding="utf-8"), end - start)
                    utterances = []
                    for region_index, (speech_start, speech_end) in enumerate(regions):
                        prefix = work / f"{name}-speech-{region_index}"
                        utterance = prefix.with_suffix(".wav")
                        extract_wav(wav, utterance, speech_start, speech_end, control.check)
                        utterances.append((utterance, prefix, speech_start, speech_end))
                    if utterances:
                        progress(completed=0, total=len(utterances), unit="speech_clips", phase=f"window_{window_done + 1}")
                    for batch_start in range(0, len(utterances), ASR_BATCH_SIZE):
                        batch = utterances[batch_start:batch_start + ASR_BATCH_SIZE]
                        arguments = [runtime["whisper_cli"], "--model", runtime["asr_model"], "--language", language, "--output-json-full", "--no-prints"]
                        for utterance, prefix, _, _ in batch:
                            arguments.extend(["--file", str(utterance), "--output-file", str(prefix)])
                        control.run(arguments, work / f"{name}-batch-{batch_start}.stdout", limit=8 * 1024 * 1024,
                                    environment={"AFTERWORD_EXPERIMENTAL_ENCODER_REUSE": "1" if
                                                 runtime.get("native", {}).get("whisper", {}).get("encoder_reuse") is True else "0",
                                                 "AFTERWORD_AUTO_LANGUAGE_EN_ZH": "1" if language == "auto" and
                                                 runtime.get("native", {}).get("whisper", {}).get("auto_language_en_zh") is True else "0"})
                    for clip_index, (_, prefix, speech_start, speech_end) in enumerate(utterances, 1):
                        raw = parse_whisper(read_json(prefix.with_suffix(".json")), speech_end - speech_start)
                        support_start, support_end = speech_support(regions, clip_index - 1, end - start)
                        for segment in raw:
                            begin, finish = start + speech_start + segment["sample_start"], start + speech_start + segment["sample_end"]
                            item = {**segment, "sample_start": begin, "sample_end": finish, "source": source["source"]}
                            lower, upper = max(begin, start + support_start), min(finish, start + support_end)
                            if lower < upper and (lower > begin or upper < finish):
                                item.update(speech_sample_start=lower, speech_sample_end=upper)
                            if start > piece_start and begin < start + OVERLAP:
                                candidates = [prior for prior in previous[-20:] if prior["sample_end"] > begin and prior["sample_start"] < finish]
                                if any(reconcile_overlap(prior, item) for prior in candidates):
                                    continue
                                if candidates:
                                    item["window_ambiguity"] = True
                            output.append(item)
                            previous.append(item)
                        progress(completed=clip_index, total=len(utterances), unit="speech_clips", phase=f"window_{window_done + 1}")
                window_done += 1
                progress(completed=window_done, total=window_total, unit="audio_windows", phase="windows")
                if end == piece_end:
                    break
                start = end - OVERLAP
    return output


def validate_turns(value, frames: int):
    require(isinstance(value, dict) and value.get("schema_version") == 1, "Invalid diarization output schema.")
    for field in ("regular", "exclusive"):
        require(isinstance(value.get(field), list), "Diarization output is missing speaker turns.")
        for turn in value[field]:
            require(isinstance(turn, dict) and type(turn.get("sample_start")) is int
                    and type(turn.get("sample_end")) is int and 0 <= turn["sample_start"] < turn["sample_end"] <= frames
                    and isinstance(turn.get("speaker"), str) and turn["speaker"], "Invalid diarization turn.")
    return value


def diarize(control, root, work, prepared, runtime, segments, allow_unknown_speakers=False):
    if not any(segment["source"] == "system" for segment in segments):
        return {"schema_version": 1, "regular": [], "exclusive": [], "mode": "not_needed", "status": "not_needed"}
    model = runtime.get("diarization_model")
    if not model or not Path(model).is_absolute() or not Path(model).is_dir():
        if allow_unknown_speakers:
            return {"schema_version": 1, "regular": [], "exclusive": [], "mode": "unknown_speakers", "status": "unavailable"}
        raise WorkerError("setup", "System speech needs the local Community-1 model. Accept its terms and configure local access, then retry.")
    source = next(source for source in prepared["sources"] if source["source"] == "system")
    target = work / "diarization.json"
    arguments = [runtime["python"], "-m", "afterword_worker.diarize", "--model", model,
                 "--audio", str(relative(root, source["relative_path"])), "--output", str(target)]
    options = {}
    if getattr(control, "progress_enabled", False):
        arguments.append("--progress-events")
        def progress_event(value):
            if set(value) != {"type", "completed", "total", "progress_unit", "progress_phase"} or value.get("type") != "progress":
                raise WorkerError("native_protocol", "Unexpected diarization progress event.")
            control.progress(value["completed"], value["total"], value["progress_unit"], value["progress_phase"])
        options["line_callback"] = progress_event
    control.run(arguments, work / "diarization.stdout", environment={"MPLCONFIGDIR": str(work / "matplotlib")},
                limit=1024 * 1024, **options)
    return {**validate_turns(read_json(target), source["pieces"][-1]["sample_end"]), "mode": "community1", "status": "completed"}


def attribution(segment: dict, turns: dict):
    if segment["source"] == "microphone":
        return "local", "microphone", False
    start, end = segment["sample_start"], segment["sample_end"]
    regular = [turn for turn in turns["regular"] if turn["sample_start"] < end and turn["sample_end"] > start]
    overlap = any(a["speaker"] != b["speaker"] and max(start, a["sample_start"], b["sample_start"])
                  < min(end, a["sample_end"], b["sample_end"]) for i, a in enumerate(regular) for b in regular[i + 1:])
    if overlap:
        return None, "overlapping_remote_speech", True
    exclusive = [turn for turn in turns["exclusive"] if turn["sample_start"] < end and turn["sample_end"] > start]
    labels = {turn["speaker"] for turn in exclusive}
    if len(labels) != 1:
        return None, "speaker_change_or_missing_timing", False
    label = next(iter(labels))
    intervals = sorted((max(start, turn["sample_start"]), min(end, turn["sample_end"])) for turn in exclusive)
    def covers(lower_bound, upper_bound):
        covered = lower_bound
        for lower, upper in intervals:
            if upper <= lower_bound or lower >= upper_bound:
                continue
            if lower > covered:
                return False
            covered = max(covered, upper)
        return covered >= upper_bound
    if covers(start, end):
        return label, "single_exclusive_turn", False
    supported_start = segment.get("speech_sample_start", start)
    supported_end = segment.get("speech_sample_end", end)
    if any(turn["speaker"] != label for turn in regular):
        return None, "speaker_change_or_missing_timing", False
    if covers(supported_start, supported_end):
        return label, "single_exclusive_turn_with_vad_padding", False
    if "speech_sample_start" in segment:
        speech_intervals = sorted((max(supported_start, lower), min(supported_end, upper))
                                  for lower, upper in intervals if lower < supported_end and upper > supported_start)
        if speech_intervals:
            lower, upper = speech_intervals[0]
            contiguous = True
            for next_lower, next_upper in speech_intervals[1:]:
                if next_lower > upper:
                    contiguous = False
                    break
                upper = max(upper, next_upper)
            if contiguous and (upper - lower) * 10 >= (supported_end - supported_start) * 9 \
                    and upper - lower >= RATE // 2 \
                    and max(lower - supported_start, supported_end - upper) <= RATE * 150 // 1000:
                return label, "single_exclusive_turn_with_bounded_gap", False
    return None, "incomplete_speaker_timing", False


def align(segments: list[dict], turns: dict, prepared: dict, meeting_id: str, revision_id: str, run_id: str):
    labels = sorted({turn["speaker"] for turn in turns["exclusive"]})
    speaker_ids = {label: f"remote-{index + 1:03d}" for index, label in enumerate(labels)}
    speakers = [{"id": "local", "source": "microphone", "label": "You"}] if any(s["source"] == "microphone" for s in segments) else []
    speakers += [{"id": speaker_ids[label], "source": "system", "label": f"Speaker {index + 1}"} for index, label in enumerate(labels)]
    sources = {source["source"]: source for source in prepared["sources"]}
    result = []
    for segment in segments:
        mapped = map_interval(segment["sample_start"], segment["sample_end"], sources[segment["source"]]["pieces"])
        require(len(mapped) == 1, "An ASR segment crossed a discontinuity; separate transcription is required.")
        speaker, reason, overlap = attribution(segment, turns)
        if segment.get("timing_ambiguity"):
            speaker, reason = None, "asr_timing_exceeds_retained_audio"
        if segment.get("window_ambiguity"):
            speaker, reason = None, "unresolved_asr_window_boundary"
        if segment["source"] == "system" and turns.get("status") == "unavailable":
            speaker, reason = None, "diarization_unavailable"
        if segment["source"] == "system" and turns.get("status") == "pending":
            speaker, reason = None, "speaker_labeling_pending"
        result.append({"source": segment["source"], "start_us": mapped[0][0], "end_us": mapped[0][1],
                       "text": segment["text"], "speaker_id": speaker_ids.get(speaker, speaker),
                       "attribution_reason": reason, "overlap": overlap})
    result.sort(key=lambda item: (item["start_us"], item["source"], item["end_us"]))
    for index, segment in enumerate(result):
        segment["id"] = f"seg-{index + 1:06d}"
    coverage = [{"source": source["source"], "start_us": piece["meeting_start_us"],
                 "end_us": piece["meeting_start_us"] + (piece["sample_end"] - piece["sample_start"]) * 1_000_000 // RATE}
                for source in prepared["sources"] for piece in source["pieces"]]
    warnings = ["Word timestamps are experimental. Remote turns spanning a speaker change or overlap remain unattributed."] if any(s["source"] == "system" for s in result) else []
    if any(segment.get("window_ambiguity") for segment in segments):
        warnings.append("Some ASR window boundaries contain overlapping alternatives that could not be reconciled. Review those unattributed segments against audio.")
    if any(segment.get("timing_ambiguity") for segment in segments):
        warnings.append("Some ASR timestamps extended into model padding. Their displayed intervals show only the overlap with retained audio, and speaker attribution is unknown. Review these segments against the audio.")
    if turns.get("status") == "unavailable":
        warnings.append("Community-1 is unavailable. At your request, system audio is shown with Unknown speakers; speaker separation and overlapping speech have not been assessed.")
    if turns.get("status") == "pending":
        warnings.append("Transcription is ready. Speaker labeling is still pending; remote speech is shown without speaker labels, and overlapping speech has not yet been assessed.")
    return {"schema_version": 1, "run_id": run_id, "meeting_id": meeting_id, "revision_id": revision_id,
            "segments": result, "speakers": speakers, "coverage": coverage,
            "warnings": warnings}
