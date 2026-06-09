from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler
from datetime import datetime, timedelta
from pathlib import Path
from faster_whisper import WhisperModel
import ollama, subprocess, time, logging, traceback, shutil, threading, queue

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

# --- Paths and models ---
RAW      = Path("~/Recordings/Meetings-Raw").expanduser()   # OBS writes here; the watcher observes this dir
MEETINGS = Path("~/Recordings/Meetings").expanduser()       # organized per-meeting folders live here
ICLOUD   = Path("~/Library/Mobile Documents/com~apple~CloudDocs/Meetings").expanduser()
LLM      = "qwen2.5:7b"   # local model served by Ollama on :11434

# --- Concurrency ---
# The watchdog observer thread does nothing but enqueue detected files; a small
# pool of worker threads drains the queue and does the actual (slow, CPU-bound)
# processing. This decouples detection from work: new files are still noticed
# and queued promptly even while a long transcription is in flight, instead of
# the observer thread blocking inside process() as it did when on_created called
# process() directly.
#
# NUM_WORKERS is deliberately conservative. Transcription is CPU-only int8
# inference that already saturates multiple cores per job, so running many jobs
# at once just thrashes the cores and helps nothing. 1 keeps behaviour identical
# to the old serial pipeline (just with a responsive watcher); 2 lets a short
# meeting slip past a long one. Above ~2 is almost never worth it on one machine.
NUM_WORKERS = 1
work_q: "queue.Queue[Path]" = queue.Queue()

# Files currently queued or in flight, so a duplicate FSEvent for a path we're
# already handling is dropped at enqueue time rather than racing down to the
# mkdir lock. Guarded by _inflight_lock. The mkdir(exist_ok=False) lock remains
# the *authoritative* guard (it also defends against a second process); this set
# is just an early, cheap filter within this process.
_inflight: set[str] = set()
_inflight_lock = threading.Lock()

# --- File-stability settling ---
# OBS finalizing its moov atom, a Finder drag, or a cross-volume `cp` all leave
# the file growing after the on_created event fires. More importantly, OBS fires
# on_created when it *opens* the file at the START of recording, so the file then
# grows for the entire meeting. We must wait out the whole recording, which has
# no fixed upper bound — a long all-hands can run for hours.
#
# So we poll size+mtime and call it done after SETTLE_STABLE_CHECKS consecutive
# unchanged samples. Crucially, SETTLE_TIMEOUT is a *stall* ceiling, not a cap on
# total elapsed time: it only counts time during which the file is NOT growing
# (see wait_until_stable). As long as the recording keeps growing the file we
# keep waiting, so meetings of any length are fine; we give up only if the file
# stops growing yet never settles — i.e. a wedged writer, not a long meeting.
SETTLE_POLL_SECONDS  = 3     # seconds between size/mtime samples
SETTLE_STABLE_CHECKS = 3     # consecutive unchanged samples required to call it done
SETTLE_TIMEOUT       = 1800  # stall ceiling (s): max time with no growth before giving up

# faster-whisper (CTranslate2). On Apple Silicon CTranslate2 has no Metal/GPU
# backend, so this runs CPU-only; int8 is the best-performing CPU precision.
WHISPER_MODEL   = "large-v3"                       # CT2 model name; auto-downloaded & cached on first run
WHISPER_DEVICE  = "cpu"
WHISPER_COMPUTE = "int8"
WHISPER_CACHE   = Path("~/.whisper").expanduser()  # keep the CT2 model alongside other local models

# Quiet the first-run HF Hub download chatter so it doesn't flood pipeline.log.
logging.getLogger("httpx").setLevel(logging.WARNING)
logging.getLogger("huggingface_hub").setLevel(logging.WARNING)

# Lazy singleton: load the model once on first use, then reuse for the life of
# the watcher process. Avoids paying the load cost at startup if no meeting ever
# happens, and avoids reloading per meeting.
#
# With NUM_WORKERS > 1 the lazy init must be guarded so two workers don't both
# start loading on the first concurrent jobs. The lock is held only around the
# one-time construction; steady-state calls just read the already-set global.
# Note: a single WhisperModel is shared across workers. faster-whisper does not
# document model.transcribe() as safe for truly concurrent calls on one instance,
# so if you ever raise NUM_WORKERS for real parallel transcription, give each
# worker its own model (or serialize transcribe() behind its own lock) rather
# than sharing this one.
_whisper_model = None
_whisper_lock  = threading.Lock()

def get_whisper_model():
    global _whisper_model
    if _whisper_model is None:
        with _whisper_lock:
            if _whisper_model is None:   # re-check inside the lock (double-checked locking)
                log.info("Loading faster-whisper model '%s' (%s / %s) — first use only",
                         WHISPER_MODEL, WHISPER_DEVICE, WHISPER_COMPUTE)
                _whisper_model = WhisperModel(
                    WHISPER_MODEL,
                    device=WHISPER_DEVICE,
                    compute_type=WHISPER_COMPUTE,
                    download_root=str(WHISPER_CACHE),
                )
    return _whisper_model


def wait_until_stable(path):
    """Block until `path` stops growing, or raise if it vanishes / stalls.

    Returns True when the file's (size, mtime) is unchanged across
    SETTLE_STABLE_CHECKS consecutive polls. Returns False if the file
    disappears mid-wait (a duplicate-event source that was already claimed and
    cleaned up, or an aborted copy).

    The timeout is measured against *inactivity*, not total elapsed time: the
    clock resets every time the file grows. OBS fires on_created at the start of
    recording, so this routine waits out the entire meeting (however long) and
    only raises TimeoutError if the file goes SETTLE_TIMEOUT seconds without
    growing yet never holds still long enough to look finished — i.e. something
    is genuinely wedged, not just a long recording.
    """
    last_sig    = None
    stable_for  = 0
    last_growth = time.monotonic()

    while True:
        try:
            st = path.stat()
        except FileNotFoundError:
            return False
        sig = (st.st_size, st.st_mtime)

        if sig == last_sig:
            stable_for += 1
            if stable_for >= SETTLE_STABLE_CHECKS:
                return True
        else:
            if last_sig is None or st.st_size > last_sig[0]:
                last_growth = time.monotonic()   # still recording — keep waiting, any length
            stable_for = 0
            last_sig = sig

        if time.monotonic() - last_growth > SETTLE_TIMEOUT:
            raise TimeoutError(
                f"{path.name} stopped growing but never settled within {SETTLE_TIMEOUT}s "
                f"(last size {sig[0]} bytes)"
            )
        time.sleep(SETTLE_POLL_SECONDS)


def process(mp4_raw):
    """Full pipeline for one recording. Runs on a worker thread, not the observer."""
    log.info("New recording detected: %s", mp4_raw.name)

    # Wait for the file to finish landing instead of a fixed sleep. This covers
    # OBS finalizing the moov atom AND large copies/drags that take longer than
    # the old 15s window. A vanished source (duplicate event, aborted copy)
    # returns False and we bail cleanly.
    if not wait_until_stable(mp4_raw):
        log.info("Source %s vanished before it settled; skipping (likely duplicate event)", mp4_raw.name)
        return
    log.info("Source %s settled (%d bytes); processing", mp4_raw.name, mp4_raw.stat().st_size)

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

    log.info("Transcribing with faster-whisper")
    model = get_whisper_model()
    segments, info = model.transcribe(
        str(mp3),
        language="en",                 # meetings are English; skip detection (remove for auto-detect)
        beam_size=5,                   # more robust than greedy decoding
        vad_filter=True,               # Silero VAD strips silence -> kills silence-hallucination at the source
        vad_parameters=dict(min_silence_duration_ms=500, speech_pad_ms=400),
        condition_on_previous_text=False,  # the loop-killer: a bad segment can't poison the next (whisper.cpp -mc 0 analog)
        no_speech_threshold=0.6,       # discard segments the model is confident are non-speech
        word_timestamps=True,          # required for hallucination_silence_threshold below
        hallucination_silence_threshold=2.0,  # skip silent gaps that tend to trigger hallucinated text
    )
    log.info("Detected %s (p=%.2f); %.0fs audio, %.0fs after VAD",
             info.language, info.language_probability, info.duration, info.duration_after_vad)

    # `segments` is a lazy generator — iterating it is what actually runs the
    # transcription. We log progress periodically since CPU-only runs are slow.
    lines = []
    for i, seg in enumerate(segments, 1):
        lines.append(seg.text.strip())
        if i % 25 == 0:
            log.info("  …%d segments transcribed, up to %.0fs", i, seg.end)
    transcript = "\n".join(lines)
    transcript_txt.write_text(transcript + "\n", encoding="utf-8")
    log.info("Transcript ready (%d chars, %d segments)", len(transcript), len(lines))

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
    log.info("Copying meeting folder to iCloud")
    out = ICLOUD / mp4.stem
    if out.exists():
        log.info("Existing iCloud folder found, replacing: %s", out)
        shutil.rmtree(out)
    shutil.copytree(meeting_dir, out)
    log.info("Done -> %s", out)


def worker():
    """Drain the work queue forever. One of these runs per worker thread.

    Each item is wrapped in the same try/except that on_created used to carry, so
    a failure on one recording is logged and the worker moves on to the next
    rather than dying. The _inflight bookkeeping is always cleared in finally so
    a failed/duplicate file can be retried by a later event.
    """
    while True:
        mp4_raw = work_q.get()
        try:
            process(mp4_raw)
        except subprocess.CalledProcessError as exc:
            log.error("Subprocess failed for %s: %s", mp4_raw, exc)
            log.error("stderr:\n%s", (exc.stderr or b"").decode(errors="replace"))
        except Exception:
            log.error("Pipeline failed for %s:\n%s", mp4_raw, traceback.format_exc())
        finally:
            with _inflight_lock:
                _inflight.discard(str(mp4_raw))
            work_q.task_done()


class Handler(FileSystemEventHandler):
    def on_created(self, e):
        # Only react to .mp4 files dropped directly into RAW by OBS.
        # The observer is non-recursive, so subdirectory events don't fire here,
        # and non-mp4 creations are filtered out by the extension check.
        #
        # This callback now does almost nothing: it filters, de-dupes, and hands
        # the path to the work queue. All the slow work happens on a worker
        # thread, so the observer stays free to notice the next file immediately.
        if e.is_directory or not e.src_path.endswith(".mp4"):
            return
        with _inflight_lock:
            if e.src_path in _inflight:
                # A duplicate FSEvent for a file we've already queued / are
                # processing. Drop it here; the mkdir lock would catch it later
                # anyway, but skipping the enqueue avoids a redundant settle wait.
                return
            _inflight.add(e.src_path)
        work_q.put(Path(e.src_path))


if __name__ == "__main__":
    log.info("Meeting pipeline watcher starting. Watching %s (%d worker%s)",
             RAW, NUM_WORKERS, "" if NUM_WORKERS == 1 else "s")

    # Start the worker pool before the observer so no enqueued file waits on
    # a not-yet-running consumer. Daemon threads so they don't block process exit.
    for n in range(NUM_WORKERS):
        threading.Thread(target=worker, name=f"worker-{n}", daemon=True).start()

    obs = Observer()
    obs.schedule(Handler(), str(RAW))
    obs.start()
    try:
        while True: time.sleep(1)
    except KeyboardInterrupt:
        obs.stop()
    obs.join()
