from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler
from logging.handlers import TimedRotatingFileHandler
from pathlib import Path
import ollama, subprocess, time, logging, sys, traceback, shutil

# --- Logging: rotating daily, 7-day retention ---
LOG_DIR  = Path("~/dev/recording-solution").expanduser()
LOG_FILE = LOG_DIR / "pipeline.log"

file_handler = TimedRotatingFileHandler(
    LOG_FILE,
    when="midnight",     # rotate at 00:00 local time
    interval=1,          # every 1 day
    backupCount=7,       # keep 7 rotated files, auto-delete older
    encoding="utf-8",
)
file_handler.suffix = "%Y-%m-%d"   # human-readable dated filenames

stream_handler = logging.StreamHandler(sys.stdout)   # also echo to launchd's stdout

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[file_handler, stream_handler],
    force=True,
)
sys.stdout.reconfigure(line_buffering=True)
sys.stderr.reconfigure(line_buffering=True)
log = logging.getLogger(__name__)

# --- Paths and model ---
WATCH  = Path("~/Recordings/Meetings").expanduser()
ICLOUD = Path("~/Library/Mobile Documents/com~apple~CloudDocs/Meetings").expanduser()
MODEL  = Path("~/.whisper/ggml-large-v3.bin").expanduser()
LLM    = "qwen2.5:7b"   # local model served by Ollama on :11434


class Handler(FileSystemEventHandler):
    def on_created(self, e):
        if not e.src_path.endswith(".mp4"): return
        try:
            self.process(Path(e.src_path))
        except subprocess.CalledProcessError as exc:
            log.error("Subprocess failed for %s: %s", e.src_path, exc)
            log.error("stderr:\n%s", (exc.stderr or b"").decode(errors="replace"))
        except Exception:
            log.error("Pipeline failed for %s:\n%s", e.src_path, traceback.format_exc())

    def process(self, mp4):
        log.info("New recording detected: %s", mp4.name)
        time.sleep(15)                                 # let OBS finalize the moov atom
        mp3, stem = mp4.with_suffix(".mp3"), mp4.with_suffix('')

        log.info("Extracting audio with FFmpeg")
        subprocess.run(["ffmpeg", "-i", str(mp4), "-vn", "-q:a", "2", str(mp3)],
                       check=True, capture_output=True)

        log.info("Transcribing with Whisper.cpp")
        subprocess.run(["whisper-cli", "-m", str(MODEL), "-f", str(mp3),
                        "-otxt", "-of", str(stem)],
                       check=True, capture_output=True)
        transcript = Path(f"{stem}.txt").read_text()
        log.info("Transcript ready (%d chars)", len(transcript))

        log.info("Summarizing with Ollama (%s)", LLM)
        resp = ollama.chat(
            model=LLM,
            messages=[{"role": "user", "content":
                "Summarize this client meeting. Output sections: Context, "
                "Decisions, Action items (owner + due date), Open questions.\n\n"
                + transcript}],
            options={"num_ctx": 16384}
        )
        summary = resp["message"]["content"]

        log.info("Copying artifacts to iCloud (originals remain in %s)", WATCH)
        out = ICLOUD / mp4.stem
        if out.exists():
            log.info("Existing iCloud folder found, replacing: %s", out)
            shutil.rmtree(out)
        out.mkdir(parents=True, exist_ok=True)
        shutil.copy2(mp4, out / mp4.name)
        shutil.copy2(mp3, out / mp3.name)
        shutil.copy2(Path(f"{stem}.txt"), out / "transcript.txt")
        (out / "summary.md").write_text(summary)
        log.info("Done → %s", out)


if __name__ == "__main__":
    log.info("Meeting pipeline watcher starting. Watching %s", WATCH)
    obs = Observer()
    obs.schedule(Handler(), str(WATCH))
    obs.start()
    try:
        while True: time.sleep(1)
    except KeyboardInterrupt:
        obs.stop()
    obs.join()
