from pathlib import Path
from types import SimpleNamespace
import json
import tempfile
import unittest
from unittest.mock import MagicMock, patch
import wave

from afterword_worker.diarize import main


class DiarizeDeviceTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        root = Path(self.folder.name)
        audio = root / "audio.wav"
        with wave.open(str(audio), "wb") as stream:
            stream.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
            stream.writeframes(b"\0\0" * 32000)
        self.output = root / "turns.json"
        self.arguments = ["diarize", "--model", str(root / "model"), "--audio", str(audio),
                          "--output", str(self.output)]
        self.torch = MagicMock()
        self.torch.device.side_effect = lambda name: name
        self.torch.get_num_threads.return_value = 12
        self.pipeline = MagicMock()
        self.pipeline.segmentation_batch_size = 32
        self.pipeline.embedding_batch_size = 32
        self.pipeline.to.side_effect = lambda device: setattr(self.pipeline, "device", device)
        annotation = MagicMock()
        annotation.itertracks.return_value = [(SimpleNamespace(start=0.25, end=1), None, "SPEAKER_00")]
        self.pipeline.return_value = SimpleNamespace(speaker_diarization=annotation,
                                                    exclusive_speaker_diarization=annotation)
        self.loader = MagicMock()
        self.loader.from_pretrained.return_value = self.pipeline
        audio_module = SimpleNamespace(Pipeline=self.loader)
        self.modules = {"torch": self.torch, "numpy": MagicMock(),
                        "pyannote": SimpleNamespace(audio=audio_module), "pyannote.audio": audio_module}

    def run_main(self, *arguments):
        with patch.dict("sys.modules", self.modules), patch("sys.argv", self.arguments + list(arguments)):
            main()

    def test_default_uses_mps_and_records_actual_execution_without_changing_turns(self):
        self.torch.backends.mps.is_available.return_value = True
        self.run_main()
        self.torch.device.assert_called_once_with("mps")
        self.pipeline.to.assert_called_once_with("mps")
        output = json.loads(self.output.read_text())
        self.assertEqual(output["execution"], {"device": "mps", "segmentation_batch_size": 32,
                                              "embedding_batch_size": 32, "torch_num_threads": 12})
        self.assertEqual(output["schema_version"], 1)
        self.assertEqual(output["regular"], [{"sample_start": 4000, "sample_end": 16000,
                                              "speaker": "SPEAKER_00"}])
        self.assertEqual(output["exclusive"], output["regular"])

    def test_auto_uses_cpu_when_mps_is_unavailable(self):
        self.torch.backends.mps.is_available.return_value = False
        self.run_main("--device", "auto")
        self.pipeline.to.assert_called_once_with("cpu")
        self.assertEqual(json.loads(self.output.read_text())["execution"]["device"], "cpu")

    def test_explicit_cpu_ignores_mps_availability(self):
        self.run_main("--device", "cpu")
        self.torch.backends.mps.is_available.assert_not_called()
        self.pipeline.to.assert_called_once_with("cpu")

    def test_explicit_unavailable_mps_fails_before_loading_model(self):
        self.torch.backends.mps.is_available.return_value = False
        with self.assertRaisesRegex(RuntimeError, "MPS is not available"):
            self.run_main("--device", "mps")
        self.loader.from_pretrained.assert_not_called()
        self.assertFalse(self.output.exists())

    def test_mps_inference_error_propagates_without_cpu_retry_or_output(self):
        self.torch.backends.mps.is_available.return_value = True
        self.pipeline.side_effect = RuntimeError("MPS operation failed")
        with self.assertRaisesRegex(RuntimeError, "MPS operation failed"):
            self.run_main("--device", "mps")
        self.pipeline.to.assert_called_once_with("mps")
        self.assertEqual(self.pipeline.call_count, 1)
        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main()
