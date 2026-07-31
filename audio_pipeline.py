import json
import shutil
import subprocess
import threading
import time
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional

from asr_runtime import asr_runtime_description, create_asr_model, transcribe_with_asr_model
from chinese_text import simplify_chinese
from diarization_runtime import configure_diarization_pipeline, run_diarization_pipeline
from transcription_progress import TranscriptionProgress, audio_duration_seconds


StatusCallback = Callable[..., None]


class AudioPipeline:
    def __init__(
        self,
        asr_model_name: str,
        diarization_model_name: str,
        hf_token: str,
        ffmpeg_bin: str,
        status_callback: StatusCallback,
        command_runner=subprocess.run,
        asr_factory=create_asr_model,
        asr_transcriber=transcribe_with_asr_model,
        diarization_runner=run_diarization_pipeline,
        pipeline_configurer=configure_diarization_pipeline,
        duration_reader=audio_duration_seconds,
        probe_runner=subprocess.run,
        max_duration_seconds: int = 3 * 60 * 60,
        max_decoded_mb: int = 1024,
        stage_timeout_seconds: int = 2 * 60 * 60,
    ) -> None:
        self.asr_model_name = asr_model_name
        self.diarization_model_name = diarization_model_name
        self.hf_token = hf_token
        self.ffmpeg_bin = ffmpeg_bin
        self.status_callback = status_callback
        self.command_runner = command_runner
        self.asr_factory = asr_factory
        self.asr_transcriber = asr_transcriber
        self.diarization_runner = diarization_runner
        self.pipeline_configurer = pipeline_configurer
        self.duration_reader = duration_reader
        self.probe_runner = probe_runner
        self.max_duration_seconds = max(1, int(max_duration_seconds))
        self.max_decoded_bytes = max(1, int(max_decoded_mb)) * 1024 * 1024
        self.stage_timeout_seconds = max(1, int(stage_timeout_seconds))
        self._model_lock = threading.Lock()
        self._diarization_lock = threading.Lock()
        self._whisper_model = None
        self._diarization_pipeline = None

    def get_whisper_model(self):
        if self._whisper_model is not None:
            return self._whisper_model
        with self._model_lock:
            if self._whisper_model is None:
                print(f"[ASR] 首次任务正在加载模型：{self.asr_model_name}")
                self._whisper_model = self.asr_factory()
                print(f"[ASR] 模型加载完成：{asr_runtime_description()}")
        return self._whisper_model

    def get_diarization_pipeline(self):
        if self._diarization_pipeline is not None:
            return self._diarization_pipeline
        with self._model_lock:
            if self._diarization_pipeline is None:
                from pyannote.audio import Pipeline

                print(f"[Diarization] 首次任务正在加载模型：{self.diarization_model_name}")
                pipeline = Pipeline.from_pretrained(
                    self.diarization_model_name,
                    token=self.hf_token,
                )
                device = self.pipeline_configurer(pipeline)
                self._diarization_pipeline = pipeline
                print(f"[Diarization] 模型加载完成，运行设备：{device.type}")
        return self._diarization_pipeline

    def convert_audio_to_wav_16k_mono(
        self,
        input_audio: Path,
        session_path: Path,
    ) -> Path:
        output_wav = session_path / "analysis_audio_16k_mono.wav"
        duration = self.validate_audio_duration(input_audio)
        expected_decoded_bytes = int(duration * 16_000 * 2) + 44
        if expected_decoded_bytes > self.max_decoded_bytes:
            raise RuntimeError(
                "音频解码后预计超过允许大小"
                f"（上限 {self.max_decoded_bytes // 1024 // 1024} MB）"
            )
        try:
            result = self.command_runner(
                [
                    self.ffmpeg_bin,
                    "-y",
                    "-i",
                    str(input_audio),
                    "-ac",
                    "1",
                    "-ar",
                    "16000",
                    "-vn",
                    str(output_wav),
                ],
                capture_output=True,
                text=True,
                timeout=min(1800, self.stage_timeout_seconds),
            )
            if result.returncode != 0:
                raise RuntimeError(
                    "FFmpeg 音频转换失败。\n"
                    f"STDOUT:\n{result.stdout}\nSTDERR:\n{result.stderr}"
                )
            if not output_wav.exists():
                raise RuntimeError("FFmpeg 未生成转换后的 WAV 文件")
            if output_wav.stat().st_size > self.max_decoded_bytes:
                raise RuntimeError(
                    "音频解码结果超过允许大小"
                    f"（上限 {self.max_decoded_bytes // 1024 // 1024} MB）"
                )
            return output_wav
        except Exception:
            output_wav.unlink(missing_ok=True)
            raise

    def validate_audio_duration(self, audio_path: Path) -> float:
        try:
            duration = float(self.duration_reader(audio_path))
        except Exception:
            ffmpeg_path = Path(self.ffmpeg_bin)
            sibling_ffprobe = ffmpeg_path.with_name("ffprobe")
            ffprobe = (
                str(sibling_ffprobe)
                if sibling_ffprobe.is_file()
                else shutil.which("ffprobe")
            )
            if not ffprobe:
                raise RuntimeError("无法读取音频时长：未找到 ffprobe")
            result = self.probe_runner(
                [
                    ffprobe,
                    "-v",
                    "error",
                    "-show_entries",
                    "format=duration",
                    "-of",
                    "default=noprint_wrappers=1:nokey=1",
                    str(audio_path),
                ],
                capture_output=True,
                text=True,
                timeout=30,
            )
            try:
                duration = float(result.stdout.strip())
            except (AttributeError, TypeError, ValueError) as error:
                raise RuntimeError("无法读取音频时长") from error
        if duration <= 0:
            raise RuntimeError("无法确认音频时长")
        if duration > self.max_duration_seconds:
            limit_hours = self.max_duration_seconds / 3600
            raise RuntimeError(f"录音时长超过允许上限（{limit_hours:g} 小时）")
        return duration

    def load_waveform_for_pyannote(self, wav_path: Path) -> Dict:
        import soundfile as sf
        import torch

        info = sf.info(str(wav_path))
        max_frames = self.max_decoded_bytes // max(1, info.channels * 4)
        if info.frames > max_frames:
            raise RuntimeError(
                "音频波形超过内存处理上限"
                f"（最多 {max_frames} 帧）"
            )
        if info.duration > self.max_duration_seconds:
            raise RuntimeError("录音时长超过允许上限")
        waveform_np, sample_rate = sf.read(str(wav_path), dtype="float32")
        waveform_np = waveform_np[None, :] if waveform_np.ndim == 1 else waveform_np.T
        return {
            "waveform": torch.from_numpy(waveform_np),
            "sample_rate": sample_rate,
        }

    def diarize_audio(self, audio_path: Path, session_path: Path) -> List[Dict]:
        print(f"[Diarization] 开始说话人分离：{audio_path.name}")
        self.validate_audio_duration(audio_path)
        audio_for_pyannote = self.load_waveform_for_pyannote(audio_path)
        deadline = time.monotonic() + self.stage_timeout_seconds
        progress_state = {"step": "", "percent": -1, "updated_at": 0.0}
        step_labels = {
            "segmentation": "检测语音活动",
            "speaker_counting": "估算说话人数",
            "embeddings": "提取说话人特征",
            "discrete_diarization": "整理说话人时间段",
        }

        def progress_hook(
            step_name: str,
            _artifact=None,
            completed: Optional[int] = None,
            total: Optional[int] = None,
            **_kwargs,
        ) -> None:
            if time.monotonic() > deadline:
                raise TimeoutError("说话人分离超过允许处理时间，任务已中止")
            if completed is None or total is None or total <= 0:
                return
            percent = min(100, max(0, int(completed * 100 / total)))
            now = time.monotonic()
            same_step = progress_state["step"] == step_name
            if (
                same_step
                and percent < progress_state["percent"] + 5
                and now < progress_state["updated_at"] + 15
            ):
                return
            progress_state.update(
                {"step": step_name, "percent": percent, "updated_at": now}
            )
            label = step_labels.get(step_name, step_name)
            self.status_callback(
                task_status="processing",
                stage="diarization",
                message=f"正在进行说话人分离：{label} {percent}%",
                session_path=session_path,
            )

        if not self._diarization_lock.acquire(blocking=False):
            self.status_callback(
                task_status="processing",
                stage="diarization",
                message="已有录音正在进行说话人分离，当前任务正在排队",
                session_path=session_path,
            )
            self._diarization_lock.acquire()
        try:
            def on_device_fallback(_error: str) -> None:
                self.status_callback(
                    task_status="processing",
                    stage="diarization",
                    message="Apple GPU 不兼容当前音频处理步骤，已自动切换 CPU 继续",
                    session_path=session_path,
                )

            output = self.diarization_runner(
                self.get_diarization_pipeline(),
                audio_for_pyannote,
                hook=progress_hook,
                on_fallback=on_device_fallback,
            )
        finally:
            self._diarization_lock.release()
        diarization = getattr(
            output,
            "exclusive_speaker_diarization",
            output.speaker_diarization,
        )
        segments = [
            {"start": float(turn.start), "end": float(turn.end), "speaker": str(speaker)}
            for turn, _, speaker in diarization.itertracks(yield_label=True)
        ]
        segments.sort(key=lambda item: item["start"])
        (session_path / "diarization.json").write_text(
            json.dumps(segments, ensure_ascii=False, indent=2),
            encoding="utf-8",
        )
        print(f"[Diarization] 完成，共 {len(segments)} 段")
        return segments

    def transcribe_audio(self, audio_path: Path, session_path: Path) -> List[Dict]:
        print(f"[ASR] 开始转写：{audio_path.name}")
        duration = self.validate_audio_duration(audio_path)
        deadline = time.monotonic() + self.stage_timeout_seconds
        progress = TranscriptionProgress(
            duration=duration,
            update=lambda message: self.status_callback(
                task_status="processing",
                stage="transcribing",
                message=message,
                session_path=session_path,
            ),
        )
        progress.start()
        segments, _info = self.asr_transcriber(self.get_whisper_model(), audio_path)
        transcript_segments: List[Dict] = []
        for segment in segments:
            if time.monotonic() > deadline:
                raise TimeoutError("语音转写超过允许处理时间，任务已中止")
            text = simplify_chinese(segment.text.strip())
            progress.advance(float(segment.end))
            if text:
                transcript_segments.append(
                    {
                        "start": float(segment.start),
                        "end": float(segment.end),
                        "text": text,
                    }
                )
        if not transcript_segments:
            raise RuntimeError("转写结果为空")
        progress.complete()
        (session_path / "transcript_segments.json").write_text(
            json.dumps(transcript_segments, ensure_ascii=False, indent=2),
            encoding="utf-8",
        )
        print(f"[ASR] 完成，共 {len(transcript_segments)} 段")
        return transcript_segments
