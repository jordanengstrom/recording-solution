# Migrating the meeting pipeline from Python to Go

The Go daemon (`go/`) replaces `meeting_pipeline.py` for everything except
transcription, which it delegates to `transcribe.py` (run with the existing
`venv/bin/python`) as a subprocess per job. `meeting_pipeline.py` stays in the
repo untouched as the rollback path.

## Build

```sh
cd ~/dev/recording-solution/go && go build -o ../bin/meetingpipeline .
```

## Test manually before switching launchd over

1. Stop the current agent so the two don't race:
   `launchctl unload ~/Library/LaunchAgents/com.jordan.meetingpipeline.plist`
   (The new binary also flocks `pipeline.lock`, but the *old Python* daemon
   doesn't participate in that lock — unload it first.)
2. Run the binary in a terminal: `~/dev/recording-solution/bin/meetingpipeline`
3. Drop a small test `.mp4` into `~/Recordings/Meetings-Raw/` and watch
   `tail -f ~/dev/recording-solution/pipeline.log`. The file is considered
   finished after 60s without growth (4 polls 15s apart), so expect at least a
   one-minute pause before "Recording finished (N MB); processing".
4. Confirm the folder appears in `~/Recordings/Meetings/{stem}/` with mp4, mp3,
   `transcript.txt`, `summary.md`, and is mirrored to iCloud.
5. Ctrl-C the binary, then install the updated plist (already pointing at
   `bin/meetingpipeline`) and reload:
   `cp com.jordan.meetingpipeline.plist.xml ~/Library/LaunchAgents/com.jordan.meetingpipeline.plist && launchctl load ~/Library/LaunchAgents/com.jordan.meetingpipeline.plist`

For a sandboxed run that touches none of the real dirs, every path is
overridable via env vars (production defaults otherwise): `MP_RAW_DIR`,
`MP_MEETINGS_DIR`, `MP_ICLOUD_DIR`, `MP_LOG_FILE`, `MP_LOCK_FILE`, `MP_PYTHON`,
`MP_SIDECAR`, `MP_OLLAMA_URL`, `MP_LLM_MODEL`, `MP_SETTLE_POLL_SECONDS`.

## Rollback

Point the plist's `ProgramArguments` back at the venv interpreter + script:

```xml
<key>ProgramArguments</key>
<array>
    <string>/Users/jordan/dev/recording-solution/venv/bin/python</string>
    <string>/Users/jordan/dev/recording-solution/meeting_pipeline.py</string>
</array>
```

(note: the venv lives at `venv/`, not `.venv/`), then re-copy to
`~/Library/LaunchAgents/` and `launchctl unload` + `load`.

## Memory note: NUM_WORKERS = 2

The Python daemon shared one in-process Whisper model; the Go daemon launches
one sidecar **per job**, and each sidecar loads its own ~3 GB `large-v3` int8
model (~30–60 s load time per job). With `NUM_WORKERS = 2`, two overlapping
meetings means **two concurrent ~3 GB sidecars**. If you see memory pressure
or swap during live recordings, drop `NUM_WORKERS` to `1` in `go/main.go` and
rebuild — detection/queueing stays responsive; jobs just run serially.
