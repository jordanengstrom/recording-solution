from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler
from datetime import datetime, timedelta
from pathlib import Path
import ollama, subprocess, time, logging, traceback, shutil

# /Users/jordan/Library/LaunchAgents/com.jordan.meetingpipeline.plist
# --- Logging: single file with a trailing 14-day window ---
LOG_DIR  = Path("~/dev/recording-solution").expanduser()
LOG_FILE = LOG_DIR / "pipeline.log"


class TrailingWindowFileHandler(logging.FileHandler):
    """Single-file handler that keeps only entries newer than `window_days`.

    The file is trimmed in place on startup and then periodically during normal
    operation (every `check_every_hours`). Multi-line records (e.g. tracebacks)
    are treated as continuations of the preceding timestamped line and inherit
    its keep/drop decision, so we never orphan a traceback from its header.
    """

    TS_LEN = 19   # length of "YYYY-MM-DD HH:MM:SS" prefix in default asctime

    def __init__(self, filename, window_days=14, check_every_hours=6, encoding="utf-8"):
        super().__init__(filename, mode="a", encoding=encoding)
        self.window         = timedelta(days=window_days)
        self.check_interval = timedelta(hours=check_every_hours)
        self._last_check    = datetime.min
        self._trim()   # prune any backlog at startup

    def emit(self, record):
        super().emit(record)
        if datetime.now() - self._last_check >= self.check_interval:
            self._trim()

    def _trim(self):
        self._last_check = datetime.now()
        path = Path(self.baseFilename)
        if not path.exists(): return
        cutoff = datetime.now() - self.window

        self.acquire()
        try:
            self.close()
            with path.open("r", encoding=self.encoding, errors="replace") as f:
                lines = f.readlines()

            kept, keep = [], False
            for line in lines:
                try:
                    ts = datetime.strptime(line[:self.TS_LEN], "%Y-%m-%d %H:%M:%S")
                    keep = ts >= cutoff
                except (ValueError, IndexError):
                    pass   # continuation line — inherits previous keep decision
                if keep: kept.append(line)

            path.write_text("".join(kept), encoding=self.encoding)
            self.stream = self._open()
        finally:
            self.release()


logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[TrailingWindowFileHandler(LOG_FILE)],
    force=True,
)
log = logging.getLogger(__name__)

# --- Paths and model ---
RAW      = Path("~/Recordings/Meetings-Raw").expanduser()   # OBS writes here; the watcher observes this dir
MEETINGS = Path("~/Recordings/Meetings").expanduser()       # organized per-meeting folders live here
ICLOUD   = Path("~/Library/Mobile Documents/com~apple~CloudDocs/Meetings").expanduser()
MODEL    = Path("~/.whisper/ggml-large-v3.bin").expanduser()
LLM      = "qwen2.5:7b"   # local model served by Ollama on :11434

# --- Waiting for OBS to finish recording ---
# on_created fires the instant OBS opens the file at "Start Recording"; OBS then
# writes to it for the entire meeting (regularly 1-2 hours) and only finalizes
# the moov atom at "Stop Recording". We must wait until OBS is done — detected by
# the file size holding steady — before touching it.
SETTLE_SECONDS = 60      # size must hold steady this long to count as finished
POLL_SECONDS   = 5       # how often to re-check the size while waiting
MAX_WAIT_HOURS = 4       # safety ceiling so a stuck/abandoned file can't block forever


class Handler(FileSystemEventHandler):
    def on_created(self, e):
        # Only react to .mp4 files dropped directly into RAW by OBS.
        # The observer is non-recursive, so subdirectory events don't fire here,
        # and non-mp4 creations are filtered out by the extension check.
        if e.is_directory or not e.src_path.endswith(".mp4"): return
        try:
            self.process(Path(e.src_path))
        except subprocess.CalledProcessError as exc:
            log.error("Subprocess failed for %s: %s", e.src_path, exc)
            log.error("stderr:\n%s", (exc.stderr or b"").decode(errors="replace"))
        except Exception:
            log.error("Pipeline failed for %s:\n%s", e.src_path, traceback.format_exc())

    def _wait_until_complete(self, path):
        """Block until `path` stops growing, i.e. OBS has stopped recording.

        Returns True once the size holds steady for SETTLE_SECONDS, or False if
        the file vanishes first (a macOS FSEvents duplicate on_created, or the
        recording being discarded). The MAX_WAIT_HOURS ceiling guards against a
        file that never settles (e.g. OBS crashed leaving the handle open).
        """
        deadline   = time.monotonic() + MAX_WAIT_HOURS * 3600
        last_size  = -1
        stable_for = 0
        while time.monotonic() < deadline:
            if not path.exists():
                return False
            size = path.stat().st_size
            if size > 0 and size == last_size:
                stable_for += POLL_SECONDS
                if stable_for >= SETTLE_SECONDS:
                    return True
            else:
                stable_for, last_size = 0, size
            time.sleep(POLL_SECONDS)
        log.warning("Source %s still changing after %dh; processing anyway",
                    path.name, MAX_WAIT_HOURS)
        return True

    def process(self, mp4_raw):
        log.info("New recording detected: %s", mp4_raw.name)

        # OBS is still recording when on_created fires; wait for it to finish
        # writing before we touch the file, otherwise we only capture the first
        # few seconds of audio that have been flushed to disk so far.
        if not self._wait_until_complete(mp4_raw):
            log.info("Source %s vanished before it finished; skipping (likely duplicate event)", mp4_raw.name)
            return
        log.info("Recording finished (%.0f MB); processing", mp4_raw.stat().st_size / 1e6)

        # --- Stage 1: create per-meeting subdirectory in MEETINGS and copy the .mp4 in ---
        # mkdir(exist_ok=False) is atomic at the filesystem level, so it doubles
        # as a lock: whichever invocation creates the directory first owns this
        # recording. A racing duplicate will get FileExistsError and exit clean.
        # The original .mp4 stays in RAW as a safety net for retries.
        meeting_dir = MEETINGS / mp4_raw.stem
        try:
            meeting_dir.mkdir(parents=True, exist_ok=False)
        except FileExistsError:
            log.info("Meeting folder %s already claimed; skipping", meeting_dir.name)
            return
        log.info("Created meeting folder: %s", meeting_dir)

        mp4 = meeting_dir / mp4_raw.name
        log.info("Copying recording into meeting folder")
        shutil.copy2(str(mp4_raw), str(mp4))

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
                "Summarize this recording. Choose section headings that fit the "
                "content. For example, a planning meeting might have Goals, Decisions, "
                "Deliverables, Next Steps, etc. while a status update might have "
                "Progress and Blockers. A recording of a lecture might have Topics, "
                "Key Points, etc. Always include an Action items section with owners "
                "and due dates where stated. It may be empty if action items are "
                "not applicable for the type of recording/meeting you encounter. "
                "Please keep in mind, you may encounter many different meeting "
                "types and you should be able to handle them all.\n\n" + transcript}],
            options={"num_ctx": 16384}
        )
        summary_md.write_text(resp["message"]["content"])

        # --- Stage 3: mirror the completed meeting folder to iCloud ---
        log.info("Copying meeting folder to iCloud")
        out = ICLOUD / mp4.stem
        if out.exists():
            log.info("Existing iCloud folder found, replacing: %s", out)
            shutil.rmtree(out)
        shutil.copytree(meeting_dir, out)
        log.info("Done → %s", out)


if __name__ == "__main__":
    log.info("Meeting pipeline watcher starting. Watching %s", RAW)
    obs = Observer()
    obs.schedule(Handler(), str(RAW))
    obs.start()
    try:
        while True: time.sleep(1)
    except KeyboardInterrupt:
        obs.stop()
    obs.join()
