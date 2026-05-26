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
        # Only react to .mp4 files dropped directly into WATCH by OBS.
        # The observer is non-recursive, so subdirectory events don't fire here,
        # and directory creations in WATCH (e.g. our own meeting folders) are
        # filtered out by the .mp4 extension check.
        if e.is_directory or not e.src_path.endswith(".mp4"): return
        try:
            self.process(Path(e.src_path))
        except subprocess.CalledProcessError as exc:
            log.error("Subprocess failed for %s: %s", e.src_path, exc)
            log.error("stderr:\n%s", (exc.stderr or b"").decode(errors="replace"))
        except Exception:
            log.error("Pipeline failed for %s:\n%s", e.src_path, traceback.format_exc())

    def process(self, mp4):
        log.info("New recording detected: %s", mp4.name)
        time.sleep(15)                                 # let OBS finalize the moov atom BEFORE we touch the file

        # --- Stage 1: create per-meeting subdirectory and relocate the .mp4 ---
        meeting_dir = WATCH / mp4.stem
        meeting_dir.mkdir(parents=True, exist_ok=True)
        log.info("Created meeting folder: %s", meeting_dir)

        mp4_local = meeting_dir / mp4.name
        log.info("Moving recording into meeting folder")
        shutil.move(str(mp4), str(mp4_local))
        mp4 = mp4_local

        mp3            = meeting_dir / f"{mp4.stem}.mp3"
        transcript_txt = meeting_dir / "transcript.txt"
        summary_md     = meeting_dir / "summary.md"

        # --- Stage 2: extract audio, transcribe, summarize (all inside meeting_dir) ---
        log.info("Extracting audio with FFmpeg")
        subprocess.run(["ffmpeg", "-i", str(mp4), "-vn", "-q:a", "2", str(mp3)],
                       check=True, capture_output=True)

        log.info("Transcribing with Whisper.cpp")
        # whisper-cli's -of takes a path WITHOUT extension; -otxt appends .txt
        subprocess.run(["whisper-cli", "-m", str(MODEL), "-f", str(mp3),
                        "-otxt", "-of", str(meeting_dir / "transcript")],
                       check=True, capture_output=True)
        transcript = transcript_txt.read_text()
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
        summary_md.write_text(resp["message"]["content"])

        # --- Stage 3: mirror the completed meeting folder to iCloud ---
        log.info("Copying meeting folder to iCloud (originals remain in %s)", meeting_dir)
        out = ICLOUD / mp4.stem
        if out.exists():
            log.info("Existing iCloud folder found, replacing: %s", out)
            shutil.rmtree(out)
        shutil.copytree(meeting_dir, out)
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
