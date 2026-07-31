from pathlib import Path
from types import SimpleNamespace
import wave

import pytest

import audio_pipeline
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

    pipeline = make_pipeline([], command_runner=runner, duration_reader=lambda _path: 60.0)
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

    pipeline = make_pipeline(
        statuses,
        diarization_runner=diarization_runner,
        duration_reader=lambda _path: 7.0,
    )
    pipeline._diarization_pipeline = object()
    pipeline.load_waveform_for_pyannote = lambda _path: {"waveform": object(), "sample_rate": 16000}

    result = pipeline.diarize_audio(tmp_path / "audio.wav", tmp_path)

    assert [item["speaker"] for item in result] == ["SPEAKER_00", "SPEAKER_01"]
    assert any("50%" in item["message"] for item in statuses)
    assert (tmp_path / "diarization.json").exists()


def test_overlong_audio_is_rejected_before_conversion(tmp_path):
    commands = []
    pipeline = make_pipeline(
        [],
        duration_reader=lambda _path: 3601.0,
        max_duration_seconds=3600,
        command_runner=lambda *args, **kwargs: commands.append((args, kwargs)),
    )

    try:
        pipeline.convert_audio_to_wav_16k_mono(tmp_path / "long.m4a", tmp_path)
    except RuntimeError as error:
        assert "时长超过" in str(error)
    else:
        raise AssertionError("overlong audio was accepted")

    assert commands == []


def test_oversized_decoded_wav_is_removed(tmp_path):
    def runner(command, **kwargs):
        Path(command[-1]).write_bytes(b"x" * (1024 * 1024 + 1))
        return SimpleNamespace(returncode=0, stdout="", stderr="")

    pipeline = make_pipeline(
        [],
        command_runner=runner,
        duration_reader=lambda _path: 1.0,
        max_decoded_mb=1,
    )
    output = tmp_path / "analysis_audio_16k_mono.wav"

    try:
        pipeline.convert_audio_to_wav_16k_mono(tmp_path / "input.m4a", tmp_path)
    except RuntimeError as error:
        assert "解码结果超过" in str(error)
    else:
        raise AssertionError("oversized decoded audio was accepted")

    assert not output.exists()


def test_waveform_frame_limit_is_checked_before_read(tmp_path, monkeypatch):
    path = tmp_path / "large.wav"
    with wave.open(str(path), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(16_000)
        output.writeframes(b"\0\0" * 300_000)

    import soundfile as sf

    read_called = False

    def unexpected_read(*args, **kwargs):
        nonlocal read_called
        read_called = True
        raise AssertionError("waveform allocation should not run")

    monkeypatch.setattr(sf, "read", unexpected_read)
    pipeline = make_pipeline([], max_decoded_mb=1)

    with pytest.raises(RuntimeError, match="波形超过内存处理上限"):
        pipeline.load_waveform_for_pyannote(path)

    assert not read_called


def test_diarization_timeout_releases_worker_lock(tmp_path, monkeypatch):
    def diarization_runner(_pipeline, _audio, hook, on_fallback):
        hook("segmentation", completed=1, total=2)

    monotonic_values = iter([0.0, 2.0])
    monkeypatch.setattr(audio_pipeline.time, "monotonic", lambda: next(monotonic_values))
    pipeline = make_pipeline(
        [],
        diarization_runner=diarization_runner,
        duration_reader=lambda _path: 10.0,
        stage_timeout_seconds=1,
    )
    pipeline._diarization_pipeline = object()
    pipeline.load_waveform_for_pyannote = lambda _path: {
        "waveform": object(),
        "sample_rate": 16_000,
    }

    with pytest.raises(TimeoutError, match="超过允许处理时间"):
        pipeline.diarize_audio(tmp_path / "audio.wav", tmp_path)

    assert pipeline._diarization_lock.acquire(blocking=False)
    pipeline._diarization_lock.release()
