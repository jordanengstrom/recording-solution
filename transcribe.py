"""Transcription sidecar for the Go meeting pipeline daemon.

Invoked per job by the Go worker:

    venv/bin/python transcribe.py <input.mp3> <output_transcript.txt>

Contract:
  - stderr: human-readable progress (the Go worker streams it into
    pipeline.log at INFO); on failure, the traceback.
  - stdout: exactly one line on success: "OK <char_count> <segment_count>".
  - exit 0 on success, non-zero on any failure.
  - The transcript is written to the output path, one segment per line,
    with a trailing newline — same format as meeting_pipeline.py produced.

Transcription parameters are copied verbatim from meeting_pipeline.py (the
hallucination guards there are load-bearing); the only addition is
cpu_threads=6 to pin the work to the M3 Pro's 6 performance cores.
"""

import logging
import sys
import traceback
from pathlib import Path

# Quiet the first-run HF Hub download chatter so it doesn't flood pipeline.log.
logging.getLogger("httpx").setLevel(logging.WARNING)
logging.getLogger("huggingface_hub").setLevel(logging.WARNING)

from faster_whisper import WhisperModel

# faster-whisper (CTranslate2). On Apple Silicon CTranslate2 has no Metal/GPU
# backend, so this runs CPU-only; int8 is the best-performing CPU precision.
WHISPER_MODEL   = "large-v3"                       # CT2 model name; auto-downloaded & cached on first run
WHISPER_DEVICE  = "cpu"
WHISPER_COMPUTE = "int8"
WHISPER_CACHE   = Path("~/.whisper").expanduser()  # keep the CT2 model alongside other local models


def progress(msg):
    print(msg, file=sys.stderr, flush=True)


def main():
    if len(sys.argv) != 3:
        progress(f"usage: {sys.argv[0]} <input.mp3> <output_transcript.txt>")
        return 2
    mp3, transcript_txt = sys.argv[1], sys.argv[2]

    progress(f"Loading faster-whisper model '{WHISPER_MODEL}' ({WHISPER_DEVICE} / {WHISPER_COMPUTE})")
    model = WhisperModel(
        WHISPER_MODEL,
        device=WHISPER_DEVICE,
        compute_type=WHISPER_COMPUTE,
        download_root=str(WHISPER_CACHE),
        cpu_threads=6,                 # M3 Pro: 6 P-cores
    )

    segments, info = model.transcribe(
        mp3,
        language="en",                 # meetings are English; skip detection (remove for auto-detect)
        beam_size=5,                   # more robust than greedy decoding
        vad_filter=True,               # Silero VAD strips silence -> kills silence-hallucination at the source
        vad_parameters=dict(min_silence_duration_ms=500, speech_pad_ms=400),
        condition_on_previous_text=False,  # the loop-killer: a bad segment can't poison the next (whisper.cpp -mc 0 analog)
        no_speech_threshold=0.6,       # discard segments the model is confident are non-speech
        word_timestamps=True,          # required for hallucination_silence_threshold below
        hallucination_silence_threshold=2.0,  # skip silent gaps that tend to trigger hallucinated text
    )
    progress("Detected %s (p=%.2f); %.0fs audio, %.0fs after VAD"
             % (info.language, info.language_probability, info.duration, info.duration_after_vad))

    # `segments` is a lazy generator — iterating it is what actually runs the
    # transcription. Emit progress periodically since CPU-only runs are slow.
    lines = []
    for i, seg in enumerate(segments, 1):
        lines.append(seg.text.strip())
        if i % 25 == 0:
            progress("  …%d segments transcribed, up to %.0fs" % (i, seg.end))

    transcript = "\n".join(lines)
    Path(transcript_txt).write_text(transcript + "\n", encoding="utf-8")

    print(f"OK {len(transcript)} {len(lines)}", flush=True)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        traceback.print_exc()
        sys.exit(1)
