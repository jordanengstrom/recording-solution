package main

// Single-file logger that mirrors the Python TrailingWindowFileHandler:
// it keeps only entries newer than trimWindow, trimming the file in place on
// startup and then periodically during normal operation (every trimInterval).
// Multi-line records (e.g. stack traces) are treated as continuations of the
// preceding timestamped line and inherit its keep/drop decision, so we never
// orphan a traceback from its header.
//
// The line format matches Python logging's
// "%(asctime)s [%(levelname)s] %(message)s" exactly
// ("2006-01-02 15:04:05,000 [INFO] ...") so existing greps keep working.

import (
	"fmt"
	"os"
	"strings"
	"sync"
	"time"
)

const (
	logTimeFormat = "2006-01-02 15:04:05" // also the parse format for trimming
	tsLen         = len(logTimeFormat)    // length of the timestamp prefix
	trimWindow    = 14 * 24 * time.Hour
	trimInterval  = 6 * time.Hour
)

type Logger struct {
	mu        sync.Mutex
	path      string
	f         *os.File
	lastCheck time.Time
}

func NewLogger(path string) (*Logger, error) {
	l := &Logger{path: path}
	if err := l.open(); err != nil {
		return nil, err
	}
	l.mu.Lock()
	l.trimLocked() // prune any backlog at startup
	l.mu.Unlock()
	return l, nil
}

func (l *Logger) open() error {
	f, err := os.OpenFile(l.path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	l.f = f
	return nil
}

func (l *Logger) Info(format string, args ...any)  { l.emit("INFO", format, args...) }
func (l *Logger) Error(format string, args ...any) { l.emit("ERROR", format, args...) }

func (l *Logger) emit(level, format string, args ...any) {
	now := time.Now()
	line := fmt.Sprintf("%s,%03d [%s] %s\n",
		now.Format(logTimeFormat), now.Nanosecond()/1e6, level, fmt.Sprintf(format, args...))

	l.mu.Lock()
	defer l.mu.Unlock()
	l.f.WriteString(line)
	if now.Sub(l.lastCheck) >= trimInterval {
		l.trimLocked()
	}
}

// trimLocked rewrites the log keeping only lines newer than the cutoff.
// Lines that don't start with a parseable timestamp inherit the keep/drop
// decision of the preceding timestamped line. Caller must hold l.mu.
func (l *Logger) trimLocked() {
	l.lastCheck = time.Now()
	data, err := os.ReadFile(l.path)
	if err != nil {
		return // nothing to trim (or unreadable — leave it alone)
	}
	cutoff := time.Now().Add(-trimWindow)

	var kept strings.Builder
	keep := false
	for _, line := range strings.SplitAfter(string(data), "\n") {
		if line == "" {
			continue
		}
		if len(line) >= tsLen {
			if ts, perr := time.ParseInLocation(logTimeFormat, line[:tsLen], time.Local); perr == nil {
				keep = !ts.Before(cutoff)
			}
			// unparseable prefix: continuation line — keep stays as-is
		}
		if keep {
			kept.WriteString(line)
		}
	}

	if kept.Len() == len(data) {
		return // nothing dropped; skip the rewrite
	}
	l.f.Close()
	if err := os.WriteFile(l.path, []byte(kept.String()), 0o644); err == nil {
		l.open()
	} else {
		l.open() // reopen in append mode regardless so logging keeps working
	}
}
