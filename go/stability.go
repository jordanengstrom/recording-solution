package main

// File-stability settling.
//
// OBS fires the create event when it *opens* the file at the START of
// recording, so the file then grows for the entire meeting, which has no
// fixed upper bound — a long all-hands can run for hours. A Finder drag or a
// cross-volume cp likewise leaves the file growing after the event fires.
//
// So we poll the size and call the file done after settleChecks consecutive
// unchanged samples (4 samples 15s apart = 60s of no growth). Any change
// resets the counter, so there is deliberately NO absolute ceiling: as long
// as the recording keeps growing we keep waiting, and a multi-hour live
// recording is fine.

import (
	"os"
	"time"
)

// waitUntilStable blocks until path stops growing. It returns true when the
// size is unchanged across cfg.settleChecks consecutive polls, or false if
// the file disappears mid-wait (a duplicate-event source that was already
// claimed and cleaned up, or an aborted copy).
func waitUntilStable(cfg *config, path string) bool {
	var lastSize int64 = -1
	stableFor := 0

	for {
		st, err := os.Stat(path)
		if err != nil {
			return false // vanished — duplicate-event artifact, caller logs and aborts
		}
		if st.Size() == lastSize {
			stableFor++
			if stableFor >= cfg.settleChecks {
				return true
			}
		} else {
			stableFor = 0 // still growing (or first sample) — reset the clock
			lastSize = st.Size()
		}
		time.Sleep(cfg.settlePoll)
	}
}
