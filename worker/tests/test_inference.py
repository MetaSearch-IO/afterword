from pathlib import Path
import json
import tempfile
import unittest
import wave

from afterword_worker.inference import align, attribution, extract_wav, parse_vad, parse_whisper, reconcile_overlap, speech_support, transcribe
from afterword_worker.pipeline import validate_asr
from afterword_worker.protocol import WorkerError


class InferenceTests(unittest.TestCase):
    def test_vad_support_only_removes_known_padding_with_rounding_margin(self):
        self.assertEqual(speech_support([(1600, 8000)], 0, 16000), (3040, 6560))
        self.assertEqual(speech_support([(0, 16000)], 0, 16000), (0, 16000))
        self.assertEqual(speech_support([(0, 15840)], 0, 16000), (0, 15840))
        self.assertEqual(speech_support([(1600, 8000), (8000, 14000)], 0, 16000), (3040, 8000))
        self.assertEqual(speech_support([(1600, 8000), (8000, 14000)], 1, 16000), (8000, 12560))
        self.assertEqual(speech_support([(1600, 2000)], 0, 16000), (1600, 2000))

    def test_checkpoint_padding_support_requires_bounded_paired_integers(self):
        segment = {"source": "system", "sample_start": 0, "sample_end": 16000, "text": "Speech"}
        prepared = {"sources": [{"source": "system", "pieces": [{"sample_start": 0, "sample_end": 16000}]}]}
        self.assertEqual(validate_asr([segment], prepared), [segment])
        valid = {**segment, "speech_sample_start": 1440, "speech_sample_end": 14560}
        self.assertEqual(validate_asr([valid], prepared), [valid])
        for invalid in ({"speech_sample_start": 10}, {"speech_sample_start": True, "speech_sample_end": 15000},
                        {"speech_sample_start": 1441, "speech_sample_end": 15000},
                        {"speech_sample_start": 1000, "speech_sample_end": 14559},
                        {"speech_sample_start": 1000, "speech_sample_end": 17000}):
            with self.subTest(invalid=invalid), self.assertRaises(WorkerError):
                validate_asr([{**segment, **invalid}], prepared)

    def test_window_merge_discards_padding_support_and_preserves_ambiguity(self):
        prior = {"sample_start": 0, "sample_end": 16000, "text": "same", "speech_sample_start": 1440,
                 "speech_sample_end": 14560}
        self.assertTrue(reconcile_overlap(prior, {"sample_start": 15000, "sample_end": 31000,
                                                 "text": "same", "timing_ambiguity": True}))
        self.assertNotIn("speech_sample_start", prior)
        self.assertNotIn("speech_sample_end", prior)
        self.assertTrue(prior["timing_ambiguity"])

    def test_known_vad_padding_does_not_require_speaker_coverage(self):
        segment = {"source": "system", "sample_start": 0, "sample_end": 16000,
                   "speech_sample_start": 1440, "speech_sample_end": 14560}
        turn = {"sample_start": 1000, "sample_end": 15000, "speaker": "A"}
        self.assertEqual(attribution(segment, {"regular": [turn], "exclusive": [turn]}),
                         ("A", "single_exclusive_turn_with_vad_padding", False))
        original = {k: v for k, v in segment.items() if not k.startswith("speech_")}
        self.assertEqual(attribution(original, {"regular": [turn], "exclusive": [turn]}),
                         (None, "incomplete_speaker_timing", False))

    def test_padding_support_cannot_hide_missing_speech_changes_or_overlap(self):
        segment = {"source": "system", "sample_start": 0, "sample_end": 16000,
                   "speech_sample_start": 1440, "speech_sample_end": 14560}
        turn = {"sample_start": 1000, "sample_end": 15000, "speaker": "A"}
        cases = [
            ([turn], [{**turn, "sample_start": 1441}]),
            ([turn], [{**turn, "sample_end": 14559}]),
            ([turn], [{**turn, "sample_end": 7000}, {**turn, "sample_start": 7001}]),
            ([turn], []),
            ([turn], [turn, {"sample_start": 0, "sample_end": 800, "speaker": "B"}]),
            ([turn, {"sample_start": 0, "sample_end": 800, "speaker": "B"}], [turn]),
            ([turn, {"sample_start": 14000, "sample_end": 16000, "speaker": "B"}], [turn]),
        ]
        for regular, exclusive in cases:
            with self.subTest(regular=regular, exclusive=exclusive):
                self.assertIsNone(attribution(segment, {"regular": regular, "exclusive": exclusive})[0])

    def test_short_input_timestamp_overrun_preserves_text_with_ambiguous_timing(self):
        output = {"model": {"multilingual": True}, "transcription": [
            {"text": "brief speech", "offsets": {"from": 0, "to": 840}}]}
        result = parse_whisper(output, 6240)
        self.assertEqual(result, [{"sample_start": 0, "sample_end": 6240,
                                  "text": "brief speech", "timing_ambiguity": True}])

    def test_padding_bounds_are_not_a_fixed_thirty_second_grid(self):
        output = {"model": {"multilingual": True}, "transcription": [
            {"text": "tail", "offsets": {"from": 39000, "to": 65000}}]}
        result = parse_whisper(output, 40 * 16000)
        self.assertEqual(result[0]["sample_end"], 40 * 16000)
        self.assertTrue(result[0]["timing_ambiguity"])

    def test_timestamp_normalization_rejects_unsupported_units_order_and_intervals(self):
        cases = [[(0, 840000)], [(400, 840)], [(200, 100)], [(100, 300), (0, 200)], [(0, 30010)]]
        for intervals in cases:
            output = {"model": {"multilingual": True}, "transcription": [
                {"text": "speech", "offsets": {"from": start, "to": end}} for start, end in intervals]}
            with self.subTest(intervals=intervals), self.assertRaises(WorkerError):
                parse_whisper(output, 6240)

    def test_normalized_timing_stays_inside_source_and_is_visible_in_transcript(self):
        source = {"source": "microphone", "pieces": [{"sample_start": 0, "sample_end": 6240, "meeting_start_us": 1000000}]}
        output = {"model": {"multilingual": True}, "transcription": [
            {"text": "brief speech", "offsets": {"from": 0, "to": 840}}]}
        parsed = [{**segment, "source": "microphone"} for segment in parse_whisper(output, 6240)]
        result = align(parsed, {"regular": [], "exclusive": []}, {"sources": [source]}, "meeting", "revision", "run")
        segment = result["segments"][0]
        self.assertEqual((segment["start_us"], segment["end_us"]), (1000000, 1390000))
        self.assertIsNone(segment["speaker_id"])
        self.assertEqual(segment["attribution_reason"], "asr_timing_exceeds_retained_audio")
        self.assertTrue(any("padding" in warning for warning in result["warnings"]))

    def test_whisper_uses_mapped_segment_offsets_not_raw_vad_tokens(self):
        output = {"model": {"multilingual": True}, "transcription": [{"text": " 中文 English", "offsets": {"from": 5000, "to": 6000},
                   "tokens": [{"text": "中文", "offsets": {"from": 0, "to": 1000}}]}]}
        result = parse_whisper(output, 160000)
        self.assertEqual(result, [{"sample_start": 80000, "sample_end": 96000, "text": "中文 English"}])
        for output in ({"transcription": []}, {"model": {"multilingual": True}, "transcription": [{"text": "x", "offsets": {"from": -1, "to": 2}}]}):
            with self.assertRaises(WorkerError):
                parse_whisper(output, 160000)

    def test_silence_gate_keeps_brief_nonzero_sample(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            with wave.open(str(root / "input.wav"), "wb") as audio:
                audio.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
                audio.writeframes(b"\0\0" * 16000 + b"\1\0" + b"\0\0" * 15999)
            self.assertFalse(extract_wav(root / "input.wav", root / "silent.wav", 0, 16000))
            self.assertTrue(extract_wav(root / "input.wav", root / "brief.wav", 16000, 32000))

    def test_turn_change_and_overlap_remain_unknown(self):
        segment = {"source": "system", "sample_start": 0, "sample_end": 16000}
        a = {"sample_start": 0, "sample_end": 16000, "speaker": "A"}
        b = {"sample_start": 8000, "sample_end": 16000, "speaker": "B"}
        self.assertEqual(attribution(segment, {"regular": [a], "exclusive": [a]}), ("A", "single_exclusive_turn", False))
        self.assertEqual(attribution(segment, {"regular": [a, b], "exclusive": [a]})[1:], ("overlapping_remote_speech", True))
        self.assertIsNone(attribution(segment, {"regular": [], "exclusive": [{**a, "sample_end": 8000}, b]})[0])
        self.assertIsNone(attribution(segment, {"regular": [], "exclusive": []})[0])

    def test_unequal_source_start_and_pause_mapping(self):
        prepared = {"sources": [{"source": "microphone", "pieces": [{"sample_start": 0, "sample_end": 16000, "meeting_start_us": 3000000}]}]}
        result = align([{"source": "microphone", "sample_start": 0, "sample_end": 16000, "text": "after pause"}],
                       {"regular": [], "exclusive": []}, prepared, "meeting", "revision", "run")
        self.assertEqual(result["segments"][0]["start_us"], 3000000)
        self.assertEqual(result["segments"][0]["speaker_id"], "local")

    def test_pending_speaker_labels_preserve_timing_text_and_local_attribution(self):
        pieces = [{"sample_start": 0, "sample_end": 16000, "meeting_start_us": 3000000}]
        prepared = {"sources": [{"source": source, "pieces": pieces} for source in ("microphone", "system")]}
        segments = [{"source": "microphone", "sample_start": 0, "sample_end": 8000, "text": "Local speech"},
                    {"source": "system", "sample_start": 8000, "sample_end": 16000, "text": "中文 English", "timing_ambiguity": True}]
        empty = {"regular": [], "exclusive": []}
        original = align(segments, empty, prepared, "meeting", "revision", "run")
        preview = align(segments, {**empty, "mode": "deferred", "status": "pending"}, prepared, "meeting", "run", "run")
        self.assertEqual(preview["segments"][0], original["segments"][0])
        self.assertEqual(preview["segments"][1], {**original["segments"][1], "attribution_reason": "speaker_labeling_pending"})
        self.assertTrue(any("Speaker labeling is still pending" in warning for warning in preview["warnings"]))
        self.assertTrue(any("padding" in warning for warning in preview["warnings"]))

    def test_differently_segmented_window_overlap_preserves_english_and_chinese(self):
        for previous, current, expected in (("We will ship the feature", "the feature tomorrow", "We will ship the feature tomorrow"),
                                           ("我们明天发布", "发布新版本", "我们明天发布新版本")):
            prior = {"sample_start": 295, "sample_end": 300, "text": previous}
            new = {"sample_start": 298, "sample_end": 310, "text": current}
            self.assertTrue(reconcile_overlap(prior, new))
            self.assertEqual(prior["text"], expected)
            self.assertEqual(prior["sample_end"], 310)
        prior = {"sample_start": 0, "sample_end": 10, "text": "this"}
        self.assertFalse(reconcile_overlap(prior, {"sample_start": 5, "sample_end": 20, "text": "sample"}))

    def test_vad_centiseconds_are_source_sample_positions(self):
        ranges = parse_vad("\nDetected 2 speech segments:\nSpeech segment 0: start = 100.00, end = 200.00\nSpeech segment 1: start = 400.00, end = 500.00\n", 96000)
        self.assertEqual(ranges, [(16000, 32000), (64000, 80000)])
        self.assertEqual(parse_vad("Detected 0 speech segments:\n", 96000), [])
        for value in ("Detected 0 speech segments:\nextra", "Detected 1 speech segments:\nSpeech segment 0: start = 0.00, end = 900.00"):
            with self.assertRaises(WorkerError):
                parse_vad(value, 96000)

    def test_large_utterance_batches_preserve_remainder_order_and_pause_boundaries(self):
        class FixtureControl:
            def __init__(self):
                self.commands = []
            def check(self):
                pass
            def run(self, arguments, output, **kwargs):
                self.commands.append(arguments)
                if arguments[0] == "vad":
                    ranges = [f"Speech segment {index}: start = {index * 20:.2f}, end = {index * 20 + 10:.2f}"
                              for index in range(65)]
                    output.write_text("Detected 65 speech segments:\n" + "\n".join(ranges) + "\n")
                    return
                for position, argument in enumerate(arguments):
                    if argument != "--output-file": continue
                    prefix = Path(arguments[position + 1])
                    index = int(prefix.name.rsplit("-", 1)[1])
                    prefix.with_suffix(".json").write_text(json.dumps({"model": {"multilingual": True}, "transcription": [
                        {"text": f"Speech {index}", "offsets": {"from": 0, "to": 100}}]}))
                output.write_text("")
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            work = root / "work"
            work.mkdir()
            with wave.open(str(root / "audio.wav"), "wb") as audio:
                audio.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
                audio.writeframes(b"\0\1" * 416000)
            prepared = {"sources": [{"source": "microphone", "relative_path": "audio.wav", "pieces": [
                {"sample_start": 0, "sample_end": 208000, "meeting_start_us": 0},
                {"sample_start": 208000, "sample_end": 416000, "meeting_start_us": 20000000}]}]}
            control = FixtureControl()
            segments = transcribe(control, root, work, prepared,
                                  {"vad_cli": "vad", "vad_model": "vadmodel", "whisper_cli": "whisper", "asr_model": "asrmodel"})
            result = align(segments, {"regular": [], "exclusive": []}, prepared, "meeting", "revision", "run")
            self.assertEqual([segment["text"] for segment in result["segments"]], [f"Speech {index}" for index in range(65)] * 2)
            self.assertEqual([segment["start_us"] for segment in result["segments"]],
                             [base + index * 200000 for base in (0, 20000000) for index in range(65)])
            commands = [command for command in control.commands if command[0] == "whisper"]
            self.assertEqual([command.count("--file") for command in commands], [64, 1, 64, 1])
            for batch, command in enumerate(commands):
                self.assertEqual(command[command.index("--language") + 1], "auto")
                files = [Path(command[index + 1]).name for index, value in enumerate(command) if value == "--file"]
                self.assertTrue(all(name.startswith(f"microphone-{batch // 2}-") for name in files))

    def test_utterance_batches_redetect_language_without_crossing_pause(self):
        class FixtureControl:
            def __init__(self):
                self.commands = []
                self.environments = []
            def check(self):
                pass
            def run(self, arguments, output, **kwargs):
                self.commands.append(arguments)
                self.environments.append(kwargs.get("environment"))
                if arguments[0] == "vad":
                    output.write_text("Detected 2 speech segments:\nSpeech segment 0: start = 0.00, end = 100.00\nSpeech segment 1: start = 200.00, end = 300.00\n")
                    return
                prefixes = [arguments[index + 1] for index, argument in enumerate(arguments) if argument == "--output-file"]
                for index, prefix in enumerate(prefixes):
                    Path(prefix).with_suffix(".json").write_text(json.dumps({"model": {"multilingual": True}, "transcription": [
                        {"text": "English" if index == 0 else "中文", "offsets": {"from": 0, "to": 1000}}]}))
                output.write_text("")
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            work = root / "work"
            work.mkdir()
            with wave.open(str(root / "audio.wav"), "wb") as audio:
                audio.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
                audio.writeframes(b"\0\1" * 128000)
            prepared = {"sources": [{"source": "microphone", "relative_path": "audio.wav", "pieces": [
                {"sample_start": 0, "sample_end": 64000, "meeting_start_us": 0},
                {"sample_start": 64000, "sample_end": 128000, "meeting_start_us": 10000000}]}]}
            control = FixtureControl()
            segments = transcribe(control, root, work, prepared, {"vad_cli": "vad", "vad_model": "vadmodel", "whisper_cli": "whisper", "asr_model": "asrmodel"})
            result = align(segments, {"regular": [], "exclusive": []}, prepared, "meeting", "revision", "run")
            self.assertEqual([segment["start_us"] for segment in result["segments"]], [0, 2000000, 10000000, 12000000])
            asr_commands = [command for command in control.commands if command[0] == "whisper"]
            self.assertEqual(len(asr_commands), 2)
            self.assertEqual([environment for command, environment in zip(control.commands, control.environments)
                              if command[0] == "whisper"], [{"AFTERWORD_EXPERIMENTAL_ENCODER_REUSE": "0",
                                                           "AFTERWORD_AUTO_LANGUAGE_EN_ZH": "0"}] * 2)
            for command in asr_commands:
                self.assertEqual(command.count("--file"), 2)
                self.assertEqual(command[command.index("--language") + 1], "auto")
                self.assertNotIn("--vad", command)
            chosen = root / "chosen"
            chosen.mkdir()
            explicit = FixtureControl()
            transcribe(explicit, root, chosen, prepared,
                       {"vad_cli": "vad", "vad_model": "vadmodel", "whisper_cli": "whisper", "asr_model": "asrmodel"}, language="zh")
            self.assertTrue(all(command[command.index("--language") + 1] == "zh"
                                for command in explicit.commands if command[0] == "whisper"))
            for index, enabled in enumerate((True, False, "true")):
                directory = root / f"reuse-{index}"
                directory.mkdir()
                fixture = FixtureControl()
                transcribe(fixture, root, directory, prepared,
                           {"vad_cli": "vad", "vad_model": "vadmodel", "whisper_cli": "whisper", "asr_model": "asrmodel",
                            "native": {"whisper": {"encoder_reuse": enabled}}})
                self.assertEqual([environment for command, environment in zip(fixture.commands, fixture.environments)
                                  if command[0] == "whisper"],
                                 [{"AFTERWORD_EXPERIMENTAL_ENCODER_REUSE": "1" if enabled is True else "0",
                                   "AFTERWORD_AUTO_LANGUAGE_EN_ZH": "0"}] * 2)
            for language in ("auto", "zh", "en"):
                for index, enabled in enumerate((True, False, "true")):
                    directory = root / f"policy-{language}-{index}"
                    directory.mkdir()
                    fixture = FixtureControl()
                    transcribe(fixture, root, directory, prepared,
                               {"vad_cli": "vad", "vad_model": "vadmodel", "whisper_cli": "whisper", "asr_model": "asrmodel",
                                "native": {"whisper": {"auto_language_en_zh": enabled}}}, language=language)
                    environments = [environment for command, environment in zip(fixture.commands, fixture.environments)
                                    if command[0] == "whisper"]
                    self.assertEqual([environment["AFTERWORD_AUTO_LANGUAGE_EN_ZH"] for environment in environments],
                                     ["1" if language == "auto" and enabled is True else "0"] * 2)
                    self.assertTrue(all(command[command.index("--language") + 1] == language
                                        for command in fixture.commands if command[0] == "whisper"))


if __name__ == "__main__":
    unittest.main()
