# OS-Level Recording Pipeline for Google Meet Client Calls
**Implementation Plan · macOS · May 2026**

## The One Constraint That Drives the Design
macOS will not let any application — QuickTime, OBS, anything — capture system audio (your client's voice routed to your AirPods) without a **virtual audio driver** in between. This is by design in Apple's security model. Solve that single problem cleanly and the rest of the pipeline is straightforward glue code.

The fix is **BlackHole** (free, open-source, from Existential Audio) combined with macOS's built-in *Audio MIDI Setup*. You create a **Multi-Output Device** that simultaneously routes client audio to your AirPods (so you hear them) and to BlackHole (so OBS can capture them). Your Blue Snowball is captured separately as a second audio track.

**Why OBS, not QuickTime**: QuickTime can only capture one audio source, so you'd have to pre-mix your mic and BlackHole into a single stream and lose the ability to balance the two voices afterward. OBS writes them as **separate tracks in the same MP4**, which keeps your options open in post.

## Setup Steps

**1. Install OBS Studio**

OBS is the recording engine. Download it from **https://obsproject.com** — pick the macOS installer that matches your chip (Apple Silicon for any M-series Mac, Intel otherwise). Open the `.dmg` and drag OBS into Applications, then launch it.

On first launch you'll hit two prompts:
- The **Auto-Configuration Wizard** asks what you'll use OBS for. Choose **"Optimize just for recording, I will not be streaming."** Accept the default resolution and frame rate (30 fps is fine). Click through to finish.
- macOS will pop a permission dialog for **Screen Recording**. Click "Open System Settings," toggle OBS on in the list, then quit and relaunch OBS so the permission takes effect. macOS may also prompt for **Microphone** and **Camera** access the first time you add those sources — allow both.

Quit OBS once after this. You'll come back to it in step 4.

(Command-line equivalent if you prefer: `brew install --cask obs`.)

**2. Install the command-line dependencies**

These are the audio driver, audio extractor, device-switcher, transcriber, and Python libraries. Open Terminal and run:

```bash
# If you don't have Homebrew, install it first (see brew.sh):
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

brew install blackhole-2ch ffmpeg switchaudio-osx whisper-cpp ollama
brew services start ollama
ollama pull qwen2.5:7b
pip3 install ollama watchdog
```

Installing `blackhole-2ch` adds a new virtual audio device to macOS — you don't see anything change immediately, but it'll show up in the next step.

**3. Create the Multi-Output Device (Audio MIDI Setup walkthrough)**

*What this app is*: Audio MIDI Setup is a built-in macOS utility for managing audio devices. You'll use it exactly once to build a virtual "splitter" device that sends sound to your AirPods (so you hear the client) and to BlackHole (so OBS can record the client) at the same time.

*To open it*: press `Cmd + Space` to open Spotlight, type **audio midi**, hit Enter. Its icon looks like a small piano keyboard. It also lives at `/Applications/Utilities/Audio MIDI Setup.app` if you prefer Finder.

*What you'll see*: a window with a sidebar on the left listing every audio device macOS knows about — built-in mic, built-in speakers, your Blue Snowball, BlackHole 2ch (now that you installed it), and AirPods Pro (if currently connected).

*The actual steps*:

1. **Connect your AirPods first** so they appear in the sidebar.
2. At the **bottom-left** of the sidebar, click the small **`+` button**. A popup appears with a few options — choose **"Create Multi-Output Device."**
3. A new entry called *"Multi-Output Device"* appears in the sidebar, already selected. The right side of the window now shows a table of every available audio device with **"Use" checkboxes**.
4. **Check the box next to AirPods Pro** and **check the box next to BlackHole 2ch**. Leave everything else unchecked.
5. Above the table, find the **"Primary Device"** dropdown and set it to **AirPods Pro**. This anchors timing/drift correction to your headphones, which prevents the small audio glitches that happen when Bluetooth and a virtual device fall out of sync.
6. In the same table, **check the "Drift Correction" box on the BlackHole 2ch row** (not on the AirPods row).
7. In the sidebar, **right-click "Multi-Output Device" → Rename**. Call it `Meeting Output`.
8. **Verify the sample rate**: with `Meeting Output` still selected, look at the **Format** dropdown at the top of the right panel. It should read **48,000 Hz**. Leave it. Every device in your audio chain — WebRTC (Google Meet's audio layer), BlackHole, OBS, AirPods, and the Snowball — runs natively at 48 kHz. When all endpoints match, Core Audio doesn't have to resample on the fly, which eliminates the subtle clicks and drift that plague Multi-Output Devices.

*To activate it before a call*: click the **speaker icon in the menu bar** (or open System Settings → Sound → Output) and pick `Meeting Output` instead of AirPods. Anything that plays audio now goes to your ears and BlackHole simultaneously. After the call, switch back to AirPods directly so music and notifications don't get pointlessly looped through BlackHole.

**4. Configure OBS**

Reopen OBS. The main window has three panels along the bottom: **Scenes**, **Sources**, and **Audio Mixer**. You're going to add one video source and two audio sources, then prune OBS's default audio sources that would otherwise contaminate your tracks.

*Add the video source*:
- In the **Sources** panel, click `+` → **macOS Screen Capture** → name it "Screen" → OK → in the properties dialog, leave **Method** as *Display Capture* and select your monitor from the dropdown.
- *Optional*: click `+` again → **Video Capture Device** → choose your Logitech webcam, then drag the preview to a corner for picture-in-picture.

> Older guides reference a source called "Display Capture" which OBS has deprecated. The new "macOS Screen Capture" uses Apple's ScreenCaptureKit framework and handles HDR, multiple monitors, and Retina scaling correctly. If you see "Display Capture" only in the *Deprecated* submenu, use macOS Screen Capture instead.

*Fit the source to canvas if you see diagonal stripes*: high-DPI displays (4K, 5K, or a 32" monitor at native resolution) overflow OBS's default 1920×1080 canvas, showing as diagonal black-and-grey stripes in the preview where content extends past the canvas edge. The recording would only capture the portion inside the canvas. Click the "Screen" source in the preview to select it, then press **Cmd+F** ("Fit to screen"). The source scales down to fit. This is the right answer for meeting recordings — Whisper doesn't benefit from extra pixels, and smaller MP4 files are easier to move.

*Add two audio sources* (the part that matters):
- Click `+` in Sources → **Audio Input Capture** → name it "Mic" → in the *Device* dropdown, pick **Blue Snowball**.
- Click `+` again → **Audio Input Capture** → name it "System Audio" → pick **BlackHole 2ch**.

*Disable OBS's default global audio*: OBS auto-creates a hidden "Mic/Auxiliary Audio" source that captures whatever macOS considers your default mic — which is your Snowball *again*. That duplicates your voice and assigns it to all six tracks, contaminating Track 2 with mic bleed. Open **OBS → Settings → Audio → Global Audio Devices** and set every entry (Desktop Audio, Mic/Auxiliary Audio 1-4) to **Disabled**. Click OK.

*Assign each audio source to its own track*: in the **Audio Mixer** panel, click the **gear icon** next to any source → **Advanced Audio Properties**. The table that opens has one row per source. Configure as follows:
- **Mic**: check Track **1** only (uncheck 2–6)
- **System Audio**: check Track **2** only (uncheck 1, 3–6)
- **Screen**: uncheck **ALL** six track boxes

The last one is non-obvious and easy to miss. macOS Screen Capture captures system audio as a side effect of capturing video, and OBS doesn't expose an off switch in the source properties. Unchecking every track discards that audio before it lands in the MP4. The source still shows as "Active" in the mixer with no tracks selected — that's expected. Optionally, click the speaker icon next to "Screen" in the main Audio Mixer panel to mute it visually; cosmetic only, since the track unassignment does the real work. Close the dialog.

*Set the recording output*:
- Top menu: **OBS → Settings → Output**.
- Set **Output Mode** to *Advanced* (this is what unlocks per-track recording).
- Switch to the **Recording** tab. Set **Recording Path** to `~/Recordings/Meetings` (create that folder in Finder first if it doesn't exist). Set **Recording Format** to **`mp4`** specifically — not "Hybrid MOV," not anything else. The Python watcher's `on_created` callback filters explicitly on `.mp4` and silently ignores other extensions.
- Under **Audio Track**, check both **1** and **2**.
- Click OK.

> **Ignore the yellow pause warning.** OBS will display *"Recordings cannot be paused if the recording encoder is set to (Use stream encoder)."* This is irrelevant here. You're not streaming, you don't want to pause client calls mid-conversation, and the shared encoder keeps CPU usage lower. Leave Video Encoder set to `(Use stream encoder)`.

*Confirm OBS's sample rate matches the rest of your audio chain*: **OBS → Settings → Audio → Sample Rate** should be **48 kHz** (it's the default). Same rationale as the Audio MIDI Setup step — mismatched rates between OBS and Core Audio cause subtle gremlins that don't surface until you're listening back to a client call.

**5. Verify the whole setup before any real call**

Switch your system output to `Meeting Output` (menu bar speaker icon). Open a browser tab with any audio source — a YouTube video works. In OBS, click **Start Recording**, let the audio play for ~10 seconds, and speak into the Snowball at the same time. Click **Stop Recording**. Open the resulting MP4 from `~/Recordings/Meetings/` in QuickTime — you should hear both your voice and the browser audio. If the browser side is silent, your system output is still set to AirPods directly instead of Meeting Output.

## Post-Processing Pipeline

A Python watcher daemon handles everything from "OBS dropped a new MP4" through "files arrive in iCloud." It runs at login via a `launchd` plist (full version in the next section).

### `~/dev/recording-solution/meeting_pipeline.py`

```python
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler
from logging.handlers import TimedRotatingFileHandler
from pathlib import Path
import ollama, subprocess, time, logging, sys, traceback

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
        subprocess.run(["ffmpeg","-i",str(mp4),"-vn","-q:a","2",str(mp3)],
                       check=True, capture_output=True)

        log.info("Transcribing with Whisper.cpp")
        subprocess.run(["whisper-cli","-m",str(MODEL),"-f",str(mp3),
                        "-otxt","-of",str(stem)],
                       check=True, capture_output=True)
        transcript = Path(f"{stem}.txt").read_text()
        log.info("Transcript ready (%d chars)", len(transcript))

        log.info("Summarizing with Ollama (%s)", LLM)
        resp = ollama.chat(
            model=LLM,
            messages=[{"role":"user","content":
                "Summarize this client meeting. Output sections: Context, "
                "Decisions, Action items (owner + due date), Open questions.\n\n"
                + transcript}],
            options={"num_ctx": 16384}
        )
        summary = resp["message"]["content"]

        log.info("Moving artifacts to iCloud")
        out = ICLOUD / mp4.stem; out.mkdir(parents=True, exist_ok=True)
        mp4.replace(out/mp4.name)
        mp3.replace(out/mp3.name)
        Path(f"{stem}.txt").replace(out/"transcript.txt")
        (out/"summary.md").write_text(summary)
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
```

### `~/Library/LaunchAgents/com.jordan.meetingpipeline.plist`

The launch agent that starts the watcher at login and restarts it if it crashes. Replace `jordan` with your macOS short username throughout, and confirm the `python3` path matches your `which python3` output.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.jordan.meetingpipeline</string>

    <key>ProgramArguments</key>
    <array>
        <string>/opt/homebrew/bin/python3</string>
        <string>/Users/jordan/dev/recording-solution/meeting_pipeline.py</string>
    </array>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <true/>

    <!-- Fallback log files for anything that bypasses Python's logging
         (import errors, syntax errors, early startup crashes).
         The main pipeline.log is owned and rotated by Python itself. -->
    <key>StandardOutPath</key>
    <string>/Users/jordan/dev/recording-solution/launchd-stdout.log</string>

    <key>StandardErrorPath</key>
    <string>/Users/jordan/dev/recording-solution/launchd-stderr.log</string>

    <key>WorkingDirectory</key>
    <string>/Users/jordan/dev/recording-solution</string>
</dict>
</plist>
```

Load (or reload) the agent after creating or editing the plist:

```bash
launchctl unload ~/Library/LaunchAgents/com.jordan.meetingpipeline.plist 2>/dev/null
launchctl load   ~/Library/LaunchAgents/com.jordan.meetingpipeline.plist
launchctl list | grep meetingpipeline    # confirm it's running (PID column has a number)
```

After editing `meeting_pipeline.py` itself (without touching the plist), restart with:

```bash
launchctl kickstart -k gui/$(id -u)/com.jordan.meetingpipeline
```

### Log Files Produced

| File | Owner | Rotation | Purpose |
|---|---|---|---|
| `pipeline.log` | Python | Daily, 7-day retention | Main operational log: per-meeting progress and errors |
| `pipeline.log.YYYY-MM-DD` | Python | Auto-pruned after 7 days | Rotated historical logs |
| `launchd-stdout.log` | launchd | Never (stays small) | Anything Python prints before logging is configured |
| `launchd-stderr.log` | launchd | Never (stays small) | Daemon-level crashes (import errors, syntax errors) |

The `launchd-*.log` files should remain near-empty in normal operation. If they ever grow large, that's a signal that the daemon is failing to start cleanly and worth investigating.

## Why This Tool Split
- **Whisper.cpp (local) for transcription**: runs natively on Apple Silicon, no API cost, no audio leaves your machine. The `large-v3` model produces ~95% accuracy on clean meeting audio and processes 30 min in roughly 90 seconds on an M-series chip. Same Whisper model that OpenAI's API runs.
- **Ollama with Qwen 2.5 7B (local) for summarization**: runs a quantized open-weight LLM on your Mac via Ollama's local HTTP server on port 11434. Qwen 2.5 punches above its weight on structured extraction tasks (decisions, action items, owners, dates) — exactly the shape we want. ~10–30 seconds per meeting summary on M-series. Zero API cost, no text leaves your machine.
- **Your Claude.ai Pro, Gemini, and Copilot subscriptions** aren't in the runtime path. Claude.ai Pro and the Anthropic API are separately billed — Pro covers the chat interface, not API access. Use Copilot in your IDE while writing and extending this script.
- **Upgrade path**: if summary quality ever feels thin, swap the `LLM` constant to `qwen2.5:14b` (needs ~24GB RAM) or `llama3.3:70b` (M3/M4 Max territory). The script doesn't change otherwise.

## Operational Notes
- **Consent**: nothing here is stealth. Disclose recording at the start of every call. California, EU, and UK require explicit two-party consent.
- **Cost ceiling**: $0 marginal cost end-to-end. The entire pipeline runs locally with no API spend. The break-even calculation versus Google Workspace Business Standard is now moot — you simply pay nothing per call.
- **iCloud sync** is automatic once files land in `com~apple~CloudDocs/`; expect 1–5 min lag before they appear on other devices.
- **Failure mode to plan for**: keep the local MP4 in `~/Recordings/Meetings/` for 72 hours before deleting, in case the pipeline silently fails (Ollama service stopped, Whisper model missing). Add a log file at `~/dev/recording-solution/pipeline.log` and have the `Handler` wrap each step in try/except that appends to it.
- **Resource use during summarization**: Ollama loads the model into memory on first call and keeps it warm. Expect ~5GB of RAM held for `qwen2.5:7b` while summaries are being generated. The model unloads after ~5 minutes of inactivity by default.

## Daily Workflow
1. Open Audio MIDI Setup (or run the SwitchAudioSource one-liner) → set output to **Meeting Output**.
2. Join the Google Meet from the browser. Disclose recording, get consent.
3. Hit **Start Recording** in OBS. Take the call.
4. **Stop Recording** when the call ends.
5. Walk away. Within 2–3 minutes the pipeline drops `meeting.mp4`, `meeting.mp3`, `transcript.txt`, and `summary.md` into a dated folder in iCloud Drive.

See the architecture diagram in chat for the full data flow.
