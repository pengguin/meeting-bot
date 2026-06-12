import os
from typing import Callable, Optional

# Let PyTorch move unsupported MPS operations back to CPU instead of failing
# the entire diarization job.
os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")

import torch


def preferred_diarization_device() -> torch.device:
    configured = os.getenv("DIARIZATION_DEVICE", "auto").strip().lower()
    if configured == "cpu":
        return torch.device("cpu")
    if configured in {"auto", "mps"} and torch.backends.mps.is_available():
        return torch.device("mps")
    return torch.device("cpu")


def configure_diarization_pipeline(pipeline) -> torch.device:
    device = preferred_diarization_device()
    try:
        pipeline.to(device)
    except (RuntimeError, NotImplementedError):
        if device.type != "mps":
            raise
        device = torch.device("cpu")
        pipeline.to(device)
    return device


def run_diarization_pipeline(
    pipeline,
    audio,
    hook=None,
    on_fallback: Optional[Callable[[str], None]] = None,
):
    try:
        return pipeline(audio, hook=hook)
    except (RuntimeError, NotImplementedError) as exc:
        device = getattr(pipeline, "device", torch.device("cpu"))
        if getattr(device, "type", str(device)) != "mps":
            raise

        if on_fallback is not None:
            on_fallback(str(exc))
        pipeline.to(torch.device("cpu"))
        return pipeline(audio, hook=hook)
