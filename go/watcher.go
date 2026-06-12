package main

// fsnotify watcher on the raw recordings directory. The watch is
// non-recursive (fsnotify only watches the directory itself), so events for
// files inside subdirectories never fire here; non-mp4 creations are filtered
// by the extension check.
//
// The event loop does almost nothing: it filters, de-dupes, and hands the
// path to the work queue. All the slow work happens on a worker goroutine,
// so the watcher stays free to notice the next file immediately.

import (
	"os"
	"strings"
	"sync"

	"github.com/fsnotify/fsnotify"
)

// inflightSet tracks files currently queued or in flight, so a duplicate
// fsnotify event for a path we're already handling is dropped at enqueue time
// rather than racing down to the mkdir lock. The mkdir claim remains the
// *authoritative* guard (it also defends against a second process); this set
// is just an early, cheap filter within this process.
type inflightSet struct {
	mu sync.Mutex
	m  map[string]struct{}
}

func newInflightSet() *inflightSet {
	return &inflightSet{m: make(map[string]struct{})}
}

// tryAdd returns false if the path is already in flight.
func (s *inflightSet) tryAdd(path string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.m[path]; ok {
		return false
	}
	s.m[path] = struct{}{}
	return true
}

func (s *inflightSet) remove(path string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.m, path)
}

func runWatcher(cfg *config, log *Logger, queue chan<- string, inflight *inflightSet) error {
	w, err := fsnotify.NewWatcher()
	if err != nil {
		return err
	}
	defer w.Close()
	if err := w.Add(cfg.rawDir); err != nil {
		return err
	}

	for {
		select {
		case ev, ok := <-w.Events:
			if !ok {
				return nil
			}
			// Only react to .mp4 files dropped directly into the raw dir by OBS.
			if !ev.Has(fsnotify.Create) || !strings.HasSuffix(ev.Name, ".mp4") {
				continue
			}
			// A directory named *.mp4 would be a Create event too; skip it
			// (the Python handler's e.is_directory check).
			if fi, statErr := os.Stat(ev.Name); statErr == nil && fi.IsDir() {
				continue
			}
			if !inflight.tryAdd(ev.Name) {
				// Duplicate event for a file we've already queued / are
				// processing. Dropping it here avoids a redundant settle wait;
				// the mkdir claim would catch it later anyway.
				continue
			}
			queue <- ev.Name
		case werr, ok := <-w.Errors:
			if !ok {
				return nil
			}
			log.Error("Watcher error: %s", werr)
		}
	}
}
