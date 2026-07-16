from pathlib import Path
from types import SimpleNamespace

from audio_pipeline import AudioPipeline


def make_pipeline(statuses, **overrides):
    defaults = {
        "asr_model_name": "whisper-test",
        "diarization_model_name": "speaker-test",
        "hf_token": "token",
        "ffmpeg_bin": "/usr/bin/ffmpeg",
        "status_callback": lambda **payload: statuses.append(payload),
    }
    defaults.update(overrides)
    return AudioPipeline(**defaults)


def test_ffmpeg_conversion_uses_expected_audio_contract(tmp_path):
    commands = []

    def runner(command, **kwargs):
        commands.append((command, kwargs))
        Path(command[-1]).write_bytes(b"wav")
        return SimpleNamespace(returncode=0, stdout="", stderr="")

    pipeline = make_pipeline([], command_runner=runner)
    output = pipeline.convert_audio_to_wav_16k_mono(tmp_path / "input.m4a", tmp_path)

    assert output.read_bytes() == b"wav"
    assert commands[0][0][-6:] == ["-ac", "1", "-ar", "16000", "-vn", str(output)]
    assert commands[0][1]["timeout"] == 1800


def test_asr_model_is_loaded_once_and_transcription_updates_status(tmp_path):
    statuses = []
    loads = []
    model = object()
    segments = [
        SimpleNamespace(start=0, end=2, text=" 第一段 "),
        SimpleNamespace(start=2, end=5, text="第二段"),
    ]
    pipeline = make_pipeline(
        statuses,
        asr_factory=lambda: loads.append(True) or model,
        asr_transcriber=lambda loaded, _path: (segments, {"language": "zh"}),
        duration_reader=lambda _path: 5.0,
    )

    first = pipeline.transcribe_audio(tmp_path / "audio.wav", tmp_path)
    second_model = pipeline.get_whisper_model()

    assert len(loads) == 1
    assert second_model is model
    assert [item["text"] for item in first] == ["第一段", "第二段"]
    assert (tmp_path / "transcript_segments.json").exists()
    assert any(item["stage"] == "transcribing" for item in statuses)


def test_diarization_pipeline_writes_sorted_segments_and_progress(tmp_path):
    statuses = []

    class FakeTimeline:
        def itertracks(self, yield_label):
            assert yield_label is True
            yield SimpleNamespace(start=4, end=7), None, "SPEAKER_01"
            yield SimpleNamespace(start=0, end=3), None, "SPEAKER_00"

    output = SimpleNamespace(speaker_diarization=FakeTimeline())

    def diarization_runner(_pipeline, _audio, hook, on_fallback):
        hook("segmentation", completed=1, total=2)
        return output

    pipeline = make_pipeline(statuses, diarization_runner=diarization_runner)
    pipeline._diarization_pipeline = object()
    pipeline.load_waveform_for_pyannote = lambda _path: {"waveform": object(), "sample_rate": 16000}

    result = pipeline.diarize_audio(tmp_path / "audio.wav", tmp_path)

    assert [item["speaker"] for item in result] == ["SPEAKER_00", "SPEAKER_01"]
    assert any("50%" in item["message"] for item in statuses)
    assert (tmp_path / "diarization.json").exists()
