package main

// Worker pool: each worker drains the queue forever. A failure on one
// recording is logged and the worker moves on to the next rather than dying;
// the raw .mp4 always stays in place as a safety net for retries. The
// in-flight bookkeeping is cleared in a defer so a failed/duplicate file can
// be retried by a later event.

import (
	"bufio"
	"bytes"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime/debug"
	"strings"
)

// subprocessError carries a child process's stderr so the worker can log it
// the way the Python version logged CalledProcessError.stderr.
type subprocessError struct {
	cmd    string
	err    error
	stderr string
}

func (e *subprocessError) Error() string {
	return fmt.Sprintf("%s: %v", e.cmd, e.err)
}

func worker(cfg *config, log *Logger, queue <-chan string, inflight *inflightSet) {
	for mp4Raw := range queue {
		func() {
			defer inflight.remove(mp4Raw)
			// A panic in one job must not kill the daemon; log it with a
			// stack like Python's traceback.format_exc() and keep draining.
			defer func() {
				if r := recover(); r != nil {
					log.Error("Pipeline failed for %s:\n%v\n%s", mp4Raw, r, debug.Stack())
				}
			}()
			if err := process(cfg, log, mp4Raw); err != nil {
				var se *subprocessError
				if errors.As(err, &se) {
					log.Error("Subprocess failed for %s: %s", mp4Raw, se)
					log.Error("stderr:\n%s", se.stderr)
				} else {
					log.Error("Pipeline failed for %s:\n%s", mp4Raw, err)
				}
			}
		}()
	}
}

// process runs the full pipeline for one recording.
func process(cfg *config, log *Logger, mp4Raw string) error {
	name := filepath.Base(mp4Raw)
	stem := strings.TrimSuffix(name, filepath.Ext(name))
	log.Info("New recording detected: %s", name)

	// Wait out the whole recording instead of a fixed sleep (see stability.go).
	// A vanished source (duplicate event, aborted copy) returns false and we
	// bail cleanly.
	if !waitUntilStable(cfg, mp4Raw) {
		log.Info("Source %s vanished before it settled; skipping (likely duplicate event)", name)
		return nil
	}
	st, err := os.Stat(mp4Raw)
	if err != nil {
		return fmt.Errorf("stat after settle: %w", err)
	}
	log.Info("Recording finished (%d MB); processing", st.Size()/(1<<20))

	// --- Stage 1: create the per-meeting folder and copy the .mp4 in ---
	// os.Mkdir is atomic at the filesystem level, so it doubles as a lock:
	// whichever invocation creates the directory first owns this recording.
	// A racing duplicate (even from another process) gets EEXIST and exits
	// clean. The original .mp4 stays in the raw dir as a safety net.
	meetingDir := filepath.Join(cfg.meetingsDir, stem)
	if err := os.MkdirAll(cfg.meetingsDir, 0o755); err != nil {
		return fmt.Errorf("creating meetings root: %w", err)
	}
	if err := os.Mkdir(meetingDir, 0o755); err != nil {
		if os.IsExist(err) {
			log.Info("Meeting folder %s already claimed; skipping", stem)
			return nil
		}
		return fmt.Errorf("creating meeting folder: %w", err)
	}
	log.Info("Created meeting folder: %s", meetingDir)

	mp4 := filepath.Join(meetingDir, name)
	log.Info("Copying recording into meeting folder")
	if err := copyFile(mp4Raw, mp4); err != nil {
		return fmt.Errorf("copying recording: %w", err)
	}

	mp3 := filepath.Join(meetingDir, stem+".mp3")
	transcriptTxt := filepath.Join(meetingDir, "transcript.txt")
	summaryMd := filepath.Join(meetingDir, "summary.md")

	// --- Stage 2: extract audio, transcribe, summarize ---
	log.Info("Extracting audio with FFmpeg")
	if err := runFFmpeg(mp4, mp3); err != nil {
		return err
	}

	log.Info("Transcribing with faster-whisper")
	charCount, segCount, err := runSidecar(cfg, log, mp3, transcriptTxt)
	if err != nil {
		return err
	}
	log.Info("Transcript ready (%d chars, %d segments)", charCount, segCount)

	if charCount == 0 || segCount == 0 {
		// Nothing for the LLM to chew on — don't waste a 16k-context call on
		// an empty string (an all-silence recording is valid, e.g. a mis-fire).
		log.Info("Transcript is empty (no speech detected); skipping summarization")
		if err := os.WriteFile(summaryMd, []byte("No speech was detected in this recording; nothing to summarize.\n"), 0o644); err != nil {
			return fmt.Errorf("writing empty summary: %w", err)
		}
	} else {
		transcriptBytes, err := os.ReadFile(transcriptTxt)
		if err != nil {
			return fmt.Errorf("reading transcript: %w", err)
		}
		// The sidecar writes one segment per line plus a trailing newline;
		// summarize the bare text like the Python version did.
		transcript := strings.TrimSuffix(string(transcriptBytes), "\n")

		log.Info("Summarizing with Ollama (%s)", cfg.llmModel)
		summary, err := summarize(cfg, transcript)
		if err != nil {
			return fmt.Errorf("summarizing: %w", err)
		}
		if err := os.WriteFile(summaryMd, []byte(summary), 0o644); err != nil {
			return fmt.Errorf("writing summary: %w", err)
		}
	}

	// --- Stage 3: mirror the completed meeting folder to iCloud ---
	log.Info("Copying meeting folder to iCloud")
	out := filepath.Join(cfg.icloudDir, stem)
	if _, err := os.Stat(out); err == nil {
		log.Info("Existing iCloud folder found, replacing: %s", out)
		if err := os.RemoveAll(out); err != nil {
			return fmt.Errorf("removing stale iCloud folder: %w", err)
		}
	}
	if err := copyTree(meetingDir, out); err != nil {
		return fmt.Errorf("copying to iCloud: %w", err)
	}
	log.Info("Done -> %s", out)
	return nil
}

// runFFmpeg extracts the audio track; stderr is captured so a failure can be
// logged with ffmpeg's own diagnostics, like the Python CalledProcessError path.
func runFFmpeg(mp4, mp3 string) error {
	cmd := exec.Command("ffmpeg", "-i", mp4, "-vn", "-q:a", "2", mp3)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return &subprocessError{cmd: "ffmpeg", err: err, stderr: stderr.String()}
	}
	return nil
}

// runSidecar invokes the Python transcription sidecar. Its stderr (progress
// lines, and the model-load / language-detection notes) is streamed into the
// main log at INFO as it happens, so a long transcription stays observable.
// On success the sidecar's stdout is a single "OK <chars> <segments>" line.
func runSidecar(cfg *config, log *Logger, mp3, transcriptTxt string) (charCount, segCount int, err error) {
	cmd := exec.Command(cfg.python, cfg.sidecar, mp3, transcriptTxt)

	stderrPipe, err := cmd.StderrPipe()
	if err != nil {
		return 0, 0, fmt.Errorf("sidecar stderr pipe: %w", err)
	}
	stdoutPipe, err := cmd.StdoutPipe()
	if err != nil {
		return 0, 0, fmt.Errorf("sidecar stdout pipe: %w", err)
	}
	if err := cmd.Start(); err != nil {
		return 0, 0, fmt.Errorf("starting sidecar: %w", err)
	}

	done := make(chan struct{})
	go func() {
		defer close(done)
		sc := bufio.NewScanner(stderrPipe)
		sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
		for sc.Scan() {
			log.Info("%s", sc.Text())
		}
	}()

	stdout, _ := io.ReadAll(stdoutPipe)
	<-done // drain stderr fully before Wait closes the pipes
	if err := cmd.Wait(); err != nil {
		// The traceback already went to the log via the stderr stream above.
		return 0, 0, fmt.Errorf("transcription sidecar: %w", err)
	}

	// Parse the final "OK <char_count> <segment_count>" line.
	last := ""
	for _, line := range strings.Split(strings.TrimSpace(string(stdout)), "\n") {
		if line != "" {
			last = line
		}
	}
	if _, err := fmt.Sscanf(last, "OK %d %d", &charCount, &segCount); err != nil {
		return 0, 0, fmt.Errorf("unexpected sidecar output %q: %w", last, err)
	}
	return charCount, segCount, nil
}

// copyFile copies src to dst preserving mode and mtime (shutil.copy2 analog).
func copyFile(src, dst string) error {
	info, err := os.Stat(src)
	if err != nil {
		return err
	}
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.OpenFile(dst, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, info.Mode().Perm())
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	if err := out.Close(); err != nil {
		return err
	}
	return os.Chtimes(dst, info.ModTime(), info.ModTime())
}

// copyTree mirrors a directory recursively (shutil.copytree analog).
// The destination must not exist yet.
func copyTree(src, dst string) error {
	return filepath.WalkDir(src, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(src, path)
		if err != nil {
			return err
		}
		target := filepath.Join(dst, rel)
		if d.IsDir() {
			return os.MkdirAll(target, 0o755)
		}
		return copyFile(path, target)
	})
}
