#!/usr/bin/env python3
import argparse
import math
import subprocess
from pathlib import Path

import numpy as np
import onnxruntime as ort


N_FFT = 1024
HOP_LENGTH = 512
DIM_F = 384
DIM_T = 64
N_FREQS = N_FFT // 2 + 1
OVERLAP = N_FFT // 2
INF_CHUNK = HOP_LENGTH * (DIM_T - 1)
GEN_SIZE = INF_CHUNK - 2 * OVERLAP
CHANNELS = 2
SAMPLE_RATE = 44_100
VOCALS_IDX = 3


def db(value: float) -> float:
    return 20.0 * math.log10(max(value, 1e-12))


def decode_audio(path: Path, start: float, frames: int) -> np.ndarray:
    duration = frames / SAMPLE_RATE
    cmd = [
        "ffmpeg",
        "-v",
        "error",
        "-ss",
        f"{start:.9f}",
        "-i",
        str(path),
        "-t",
        f"{duration:.9f}",
        "-map",
        "0:a:0",
        "-ac",
        "2",
        "-ar",
        str(SAMPLE_RATE),
        "-f",
        "f32le",
        "-acodec",
        "pcm_f32le",
        "-",
    ]
    raw = subprocess.check_output(cmd)
    audio = np.frombuffer(raw, dtype=np.float32).reshape(-1, 2)
    if audio.shape[0] < frames:
        padded = np.zeros((frames, 2), dtype=np.float32)
        padded[: audio.shape[0]] = audio
        audio = padded
    return np.ascontiguousarray(audio[:frames])


def hann_window() -> np.ndarray:
    return np.hanning(N_FFT + 1)[:-1].astype(np.float32)


WINDOW = hann_window()


def stft_channel(samples: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    specs = []
    for frame_idx in range(DIM_T):
        frame_start = frame_idx * HOP_LENGTH - OVERLAP
        frame = np.zeros(N_FFT, dtype=np.float32)
        for i in range(N_FFT):
            source = frame_start + i
            if 0 <= source < INF_CHUNK:
                frame[i] = samples[source] * WINDOW[i]
        specs.append(np.fft.rfft(frame, n=N_FFT).astype(np.complex64))
    spec = np.stack(specs, axis=1)
    return spec.real, spec.imag


def model_input_from_chunk(chunk: np.ndarray) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    padded = np.zeros((INF_CHUNK, 2), dtype=np.float32)
    padded[OVERLAP : OVERLAP + GEN_SIZE] = chunk
    left = padded[:, 0]
    right = padded[:, 1]

    onnx_in = np.zeros((1, 4, DIM_F, DIM_T), dtype=np.float32)
    for ch, samples in enumerate((left, right)):
        re, im = stft_channel(samples)
        onnx_in[0, ch * 2, :, :] = re[:DIM_F, :]
        onnx_in[0, ch * 2 + 1, :, :] = im[:DIM_F, :]
    return onnx_in, left, right


def istft_vocals(model_output: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    waveforms = []
    for ch in range(CHANNELS):
        output = np.zeros(N_FFT + HOP_LENGTH * (DIM_T - 1), dtype=np.float32)
        win_sum = np.zeros_like(output)

        re_bins = model_output[0, VOCALS_IDX, ch * 2]
        im_bins = model_output[0, VOCALS_IDX, ch * 2 + 1]

        for frame_idx in range(DIM_T):
            spec = np.zeros(N_FREQS, dtype=np.complex64)
            spec[:DIM_F] = re_bins[:, frame_idx] + 1j * im_bins[:, frame_idx]
            frame = np.fft.irfft(spec, n=N_FFT).astype(np.float32)
            start = frame_idx * HOP_LENGTH
            output[start : start + N_FFT] += frame * WINDOW
            win_sum[start : start + N_FFT] += WINDOW * WINDOW

        valid = win_sum > 1e-8
        output[valid] /= win_sum[valid]
        waveforms.append(output[OVERLAP:-OVERLAP])
    return waveforms[0], waveforms[1]


def process(audio: np.ndarray, session: ort.InferenceSession) -> np.ndarray:
    input_name = session.get_inputs()[0].name
    output_name = session.get_outputs()[0].name
    out = np.zeros_like(audio)

    for offset in range(0, audio.shape[0], GEN_SIZE):
        chunk = audio[offset : offset + GEN_SIZE]
        onnx_in, left, right = model_input_from_chunk(chunk)
        model_out = session.run([output_name], {input_name: onnx_in})[0]
        vocal_left, vocal_right = istft_vocals(model_out)
        inst = np.stack(
            [
                np.clip(left[OVERLAP : OVERLAP + GEN_SIZE] - vocal_left[OVERLAP : OVERLAP + GEN_SIZE], -1, 1),
                np.clip(right[OVERLAP : OVERLAP + GEN_SIZE] - vocal_right[OVERLAP : OVERLAP + GEN_SIZE], -1, 1),
            ],
            axis=1,
        )
        out[offset : offset + GEN_SIZE] = inst[: chunk.shape[0]]
        print(f"processed chunk {offset // GEN_SIZE + 1}/{audio.shape[0] // GEN_SIZE}", flush=True)
    return out


def metrics(name: str, audio: np.ndarray) -> dict[str, float]:
    mono = audio.mean(axis=1)
    return {
        f"{name}_rms": float(np.sqrt(np.mean(audio * audio))),
        f"{name}_rms_dbfs": db(float(np.sqrt(np.mean(audio * audio)))),
        f"{name}_mono_rms_dbfs": db(float(np.sqrt(np.mean(mono * mono)))),
        f"{name}_peak_dbfs": db(float(np.max(np.abs(audio)))),
    }


def compare(processed: np.ndarray, instrumental: np.ndarray) -> dict[str, float]:
    n = min(processed.shape[0], instrumental.shape[0])
    p = processed[:n]
    i = instrumental[:n]
    diff = p - i
    rms_p = float(np.sqrt(np.mean(p * p)))
    rms_i = float(np.sqrt(np.mean(i * i)))
    rms_diff = float(np.sqrt(np.mean(diff * diff)))
    corr = float(np.corrcoef(p.reshape(-1), i.reshape(-1))[0, 1])
    return {
        "processed_vs_instrumental_diff_rms_dbfs": db(rms_diff),
        "processed_minus_instrumental_db": db(rms_p) - db(rms_i),
        "instrumental_to_diff_snr_db": 20.0 * math.log10(max(rms_i, 1e-12) / max(rms_diff, 1e-12)),
        "processed_instrumental_corr": corr,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--song", required=True, type=Path)
    parser.add_argument("--instrumental", required=True, type=Path)
    parser.add_argument("--model", default="Sources/GlobalVocalRemover/Resources/Models/all_rt.onnx", type=Path)
    parser.add_argument("--start", type=float, default=60.0)
    parser.add_argument("--chunks", type=int, default=40)
    parser.add_argument("--provider", choices=["coreml", "cpu"], default="coreml")
    args = parser.parse_args()

    frames = GEN_SIZE * args.chunks
    providers = ["CoreMLExecutionProvider", "CPUExecutionProvider"] if args.provider == "coreml" else ["CPUExecutionProvider"]
    session = ort.InferenceSession(str(args.model), providers=providers)
    print("providers:", session.get_providers())

    song = decode_audio(args.song, args.start, frames)
    instrumental = decode_audio(args.instrumental, args.start, frames)
    processed = process(song, session)

    result = {}
    result.update(metrics("song", song))
    result.update(metrics("reference_instrumental", instrumental))
    result.update(metrics("processed", processed))
    result.update(metrics("song_minus_reference_instrumental", song - instrumental))
    result.update(compare(processed, instrumental))

    for key, value in result.items():
        print(f"{key}: {value:.4f}")


if __name__ == "__main__":
    main()
