import os
import unittest
from unittest.mock import patch

import torch

from diarization_runtime import (
    configure_diarization_pipeline,
    preferred_diarization_device,
    run_diarization_pipeline,
)


class FakePipeline:
    def __init__(self, fail_once: bool = False):
        self.device = torch.device("cpu")
        self.fail_once = fail_once
        self.call_count = 0

    def to(self, device):
        self.device = device
        return self

    def __call__(self, audio, hook=None):
        self.call_count += 1
        if self.fail_once and self.call_count == 1:
            raise RuntimeError("unsupported MPS operation")
        return {"audio": audio, "hook": hook, "device": self.device.type}


class DiarizationRuntimeTests(unittest.TestCase):
    def test_auto_prefers_mps_when_available(self):
        with patch.dict(os.environ, {"DIARIZATION_DEVICE": "auto"}), patch(
            "torch.backends.mps.is_available", return_value=True
        ):
            self.assertEqual(preferred_diarization_device().type, "mps")

    def test_explicit_cpu_keeps_pipeline_on_cpu(self):
        pipeline = FakePipeline()
        with patch.dict(os.environ, {"DIARIZATION_DEVICE": "cpu"}):
            device = configure_diarization_pipeline(pipeline)
        self.assertEqual(device.type, "cpu")
        self.assertEqual(pipeline.device.type, "cpu")

    def test_mps_runtime_error_retries_on_cpu(self):
        pipeline = FakePipeline(fail_once=True)
        pipeline.device = torch.device("mps")
        fallback_errors = []

        result = run_diarization_pipeline(
            pipeline,
            "audio",
            on_fallback=fallback_errors.append,
        )

        self.assertEqual(pipeline.call_count, 2)
        self.assertEqual(result["device"], "cpu")
        self.assertEqual(len(fallback_errors), 1)


if __name__ == "__main__":
    unittest.main()
