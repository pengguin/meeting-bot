from faster_whisper import BatchedInferencePipeline, WhisperModel

from meetingbot_config import (
    ASR_BATCH_SIZE,
    ASR_BEAM_SIZE,
    ASR_CPU_THREADS,
    ASR_LANGUAGE,
    ASR_MODEL,
)


def create_asr_model():
    model = WhisperModel(
        ASR_MODEL,
        device="cpu",
        compute_type="int8",
        cpu_threads=ASR_CPU_THREADS,
        num_workers=1,
    )
    if ASR_BATCH_SIZE > 1:
        return BatchedInferencePipeline(model)
    return model


def transcribe_with_asr_model(model, audio_path):
    options = {
        "language": ASR_LANGUAGE if ASR_LANGUAGE else None,
        "vad_filter": True,
        "beam_size": ASR_BEAM_SIZE,
    }
    if isinstance(model, BatchedInferencePipeline):
        options["batch_size"] = ASR_BATCH_SIZE
        options["without_timestamps"] = False
    return model.transcribe(str(audio_path), **options)


def asr_runtime_description() -> str:
    batch = f"，批量大小 {ASR_BATCH_SIZE}" if ASR_BATCH_SIZE > 1 else ""
    return f"CPU int8，{ASR_CPU_THREADS} 线程{batch}，beam size {ASR_BEAM_SIZE}"
