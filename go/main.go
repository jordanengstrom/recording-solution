// Meeting pipeline daemon (Go rewrite of meeting_pipeline.py).
//
// The Go binary owns watching, settling, locking, FFmpeg, Ollama, iCloud
// mirroring and logging. Transcription stays in Python: faster-whisper has no
// Go equivalent and its hallucination guards are load-bearing, so each worker
// shells out to transcribe.py (see worker.go).
//
// meeting_pipeline.py remains in the repo untouched as the rollback path.
package main

import (
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"syscall"
	"time"
)

// NUM_WORKERS is deliberately conservative. Transcription is CPU-only int8
// inference that already saturates multiple cores per job, so running many
// jobs at once just thrashes the cores and helps nothing. 1 keeps behaviour
// identical to the old serial pipeline (just with a responsive watcher);
// 2 lets a short meeting slip past a long one. Above ~2 is almost never worth
// it on one machine. NOTE: unlike the Python version (one shared model), each
// concurrent job here is its own sidecar process loading its own ~3 GB model.
const NUM_WORKERS = 2

// config holds every path and knob. Production values are the defaults;
// each can be overridden by an MP_* environment variable so the daemon can be
// pointed at a sandbox (temp dirs, stub sidecar, mock Ollama) for testing.
type config struct {
	rawDir      string // OBS writes here; the watcher observes this dir
	meetingsDir string // organized per-meeting folders live here
	icloudDir   string
	logFile     string
	lockFile    string
	python      string // venv interpreter for the transcription sidecar
	sidecar     string // transcribe.py
	ollamaURL   string
	llmModel    string // local model served by Ollama on :11434

	settlePoll   time.Duration // seconds between size samples
	settleChecks int           // consecutive unchanged samples required
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func loadConfig() *config {
	home, err := os.UserHomeDir()
	if err != nil {
		fmt.Fprintf(os.Stderr, "meetingpipeline: cannot determine home directory: %v\n", err)
		os.Exit(1)
	}
	proj := filepath.Join(home, "dev", "recording-solution")

	cfg := &config{
		rawDir:       envOr("MP_RAW_DIR", filepath.Join(home, "Recordings", "Meetings-Raw")),
		meetingsDir:  envOr("MP_MEETINGS_DIR", filepath.Join(home, "Recordings", "Meetings")),
		icloudDir:    envOr("MP_ICLOUD_DIR", filepath.Join(home, "Library", "Mobile Documents", "com~apple~CloudDocs", "Meetings")),
		logFile:      envOr("MP_LOG_FILE", filepath.Join(proj, "pipeline.log")),
		lockFile:     envOr("MP_LOCK_FILE", filepath.Join(proj, "pipeline.lock")),
		python:       envOr("MP_PYTHON", filepath.Join(proj, "venv", "bin", "python")),
		sidecar:      envOr("MP_SIDECAR", filepath.Join(proj, "transcribe.py")),
		ollamaURL:    envOr("MP_OLLAMA_URL", "http://127.0.0.1:11434/api/chat"),
		llmModel:     envOr("MP_LLM_MODEL", "qwen2.5:7b"),
		settlePoll:   15 * time.Second,
		settleChecks: 4, // 4 unchanged samples 15s apart = 60s of no growth
	}
	if v := os.Getenv("MP_SETTLE_POLL_SECONDS"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			cfg.settlePoll = time.Duration(n) * time.Second
		}
	}
	return cfg
}

// acquireSingletonLock takes an exclusive flock on cfg.lockFile so a manual
// run can't race the launchd agent (two daemons would fight over the same
// fsnotify events; the mkdir claim would save the data but double the noise).
// The fd is held open, never closed: the kernel drops the lock when the
// process exits, however it exits.
func acquireSingletonLock(cfg *config) *os.File {
	f, err := os.OpenFile(cfg.lockFile, os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		fmt.Fprintf(os.Stderr, "meetingpipeline: cannot open lock file %s: %v\n", cfg.lockFile, err)
		os.Exit(1)
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		fmt.Fprintf(os.Stderr, "meetingpipeline: another instance already holds %s; exiting\n", cfg.lockFile)
		os.Exit(1)
	}
	return f
}

func main() {
	cfg := loadConfig()
	lockFile := acquireSingletonLock(cfg)
	defer lockFile.Close()

	log, err := NewLogger(cfg.logFile)
	if err != nil {
		fmt.Fprintf(os.Stderr, "meetingpipeline: cannot open log file %s: %v\n", cfg.logFile, err)
		os.Exit(1)
	}

	plural := "s"
	if NUM_WORKERS == 1 {
		plural = ""
	}
	log.Info("Meeting pipeline watcher starting. Watching %s (%d worker%s)", cfg.rawDir, NUM_WORKERS, plural)

	// Buffered channel so the watcher can enqueue promptly even while every
	// worker is busy; 128 pending recordings is far beyond anything realistic.
	queue := make(chan string, 128)
	inflight := newInflightSet()

	// Start the worker pool before the watcher so no enqueued file waits on
	// a not-yet-running consumer (same ordering as the Python original).
	for n := 0; n < NUM_WORKERS; n++ {
		go worker(cfg, log, queue, inflight)
	}

	go func() {
		if err := runWatcher(cfg, log, queue, inflight); err != nil {
			log.Error("Watcher terminated: %s", err)
			os.Exit(1)
		}
	}()

	// Block until launchd (or a human) tells us to stop.
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	<-sig
}
