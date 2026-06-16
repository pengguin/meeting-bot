import unittest
from unittest.mock import Mock, patch

import asr_runtime


class ASRRuntimeTests(unittest.TestCase):
    def test_create_model_enables_batching(self):
        base_model = Mock()
        with patch("asr_runtime.WhisperModel", return_value=base_model) as model_type, patch(
            "asr_runtime.BatchedInferencePipeline", return_value="batched"
        ) as batched_type, patch("asr_runtime.ASR_BATCH_SIZE", 8):
            result = asr_runtime.create_asr_model()

        self.assertEqual(result, "batched")
        model_type.assert_called_once_with(
            asr_runtime.ASR_MODEL,
            device="cpu",
            compute_type="int8",
            cpu_threads=asr_runtime.ASR_CPU_THREADS,
            num_workers=1,
        )
        batched_type.assert_called_once_with(base_model)

    def test_transcribe_passes_batch_and_timestamp_options(self):
        model = Mock(spec=asr_runtime.BatchedInferencePipeline)
        with patch("asr_runtime.ASR_BATCH_SIZE", 8), patch("asr_runtime.ASR_BEAM_SIZE", 5):
            asr_runtime.transcribe_with_asr_model(model, "/tmp/audio.wav")

        model.transcribe.assert_called_once_with(
            "/tmp/audio.wav",
            language=asr_runtime.ASR_LANGUAGE,
            vad_filter=True,
            beam_size=5,
            batch_size=8,
            without_timestamps=False,
        )


if __name__ == "__main__":
    unittest.main()
