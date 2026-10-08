from __future__ import annotations

import argparse
import json
from numbers import Integral
from pathlib import Path
import wave


def progress_hook():
    counts = {}

    def hook(step, artifact=None, **kwargs):
        unit = {"segmentation": "segmentation_chunks", "embeddings": "embedding_batches"}.get(step)
        if unit is None:
            return
        completed, total = kwargs.get("completed"), kwargs.get("total")
        if completed is None and total is None:
            if step not in counts:
                return
            completed = total = counts[step][1]
        elif not (isinstance(completed, Integral) and not isinstance(completed, bool)
                  and isinstance(total, Integral) and not isinstance(total, bool)):
            return
        completed, total = int(completed), int(total)
        # pyannote counts padded batch slots; wait for its final artifact before reporting completion.
        if not 0 <= completed <= total <= 1_000_000_000 or total == 0:
            return
        previous = counts.get(step)
        if previous is not None and (previous[1] != total or previous[0] >= completed):
            return
        counts[step] = (completed, total)
        print(json.dumps({"type": "progress", "completed": completed, "total": total,
                          "progress_unit": unit, "progress_phase": step}, separators=(",", ":")), flush=True)

    return hook


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--audio", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--device", choices=("auto", "cpu", "mps"), default="auto")
    parser.add_argument("--progress-events", action="store_true")
    args = parser.parse_args()
    import numpy as np
    import torch
    from pyannote.audio import Pipeline

    device = args.device
    if device != "cpu":
        if torch.backends.mps.is_available():
            device = "mps"
        elif device == "mps":
            raise RuntimeError("MPS is not available. Use --device cpu for CPU diarization.")
        else:
            device = "cpu"
    with wave.open(str(args.audio), "rb") as audio:
        count = audio.getnframes()
        waveform = torch.from_numpy(np.frombuffer(audio.readframes(count), dtype="<i2").astype(np.float32) / 32768).unsqueeze(0)
    pipeline = Pipeline.from_pretrained(str(args.model))
    if pipeline is None:
        raise RuntimeError("The local diarization pipeline could not be loaded.")
    pipeline.to(torch.device(device))
    options = {"hook": progress_hook()} if args.progress_events else {}
    result = pipeline({"waveform": waveform, "sample_rate": 16000}, **options)

    def turns(annotation):
        output = []
        for turn, _, speaker in annotation.itertracks(yield_label=True):
            start, end = max(0, round(turn.start * 16000)), min(count, round(turn.end * 16000))
            if end > start:
                output.append({"sample_start": start, "sample_end": end, "speaker": str(speaker)})
        return output

    value = {"schema_version": 1, "regular": turns(result.speaker_diarization),
             "exclusive": turns(result.exclusive_speaker_diarization),
             "execution": {"device": str(pipeline.device),
                           "segmentation_batch_size": pipeline.segmentation_batch_size,
                           "embedding_batch_size": pipeline.embedding_batch_size,
                           "torch_num_threads": torch.get_num_threads()}}
    args.output.write_text(json.dumps(value), encoding="utf-8")


if __name__ == "__main__":
    main()
