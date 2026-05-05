package server

import (
	"context"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/kopia/kopia/internal/clock"
	"github.com/kopia/kopia/internal/uitask"
)

// StartHeartbeatLoop launches a goroutine that emits a structured heartbeat
// line every interval to the given file (or to stderr when path is empty).
// Returns immediately; the goroutine exits when ctx is cancelled.
//
// Format (single line, ASCII, key=value, grep-friendly):
//
//	[heartbeat] <RFC3339> uptime=<seconds>s tasks=<N> [task=<kind>:<desc>,progress=<text>,duration=<seconds>s]*
//
// On internal error (failed to enumerate tasks, write failure), emits
//
//	[heartbeat] <RFC3339> server=error msg="<reason>"
//
// rather than dropping the tick — the freshness signal is the load-bearing
// invariant for downstream consumers (wrapper stall guard, watchdog,
// backup-monitor.exe), so even a sick server should still produce a tick.
func (s *Server) StartHeartbeatLoop(ctx context.Context, interval time.Duration, path string) {
	if interval <= 0 {
		return
	}

	startedAt := clock.Now()

	go func() {
		ticker := time.NewTicker(interval)
		defer ticker.Stop()

		// Fire one tick immediately so consumers don't have to wait
		// `interval` seconds for the first signal after a server restart.
		s.emitHeartbeat(startedAt, path)

		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				s.emitHeartbeat(startedAt, path)
			}
		}
	}()
}

func (s *Server) emitHeartbeat(startedAt time.Time, path string) {
	now := clock.Now()
	uptime := int64(now.Sub(startedAt).Seconds())

	var line string
	tasks, err := s.snapshotActiveTasks()
	if err != nil {
		line = fmt.Sprintf("[heartbeat] %s server=error uptime=%ds msg=%q\n",
			now.Format(time.RFC3339), uptime, err.Error())
	} else {
		var b strings.Builder
		fmt.Fprintf(&b, "[heartbeat] %s uptime=%ds tasks=%d",
			now.Format(time.RFC3339), uptime, len(tasks))
		for _, t := range tasks {
			dur := int64(now.Sub(t.StartTime).Seconds())
			progress := t.ProgressInfo
			if progress == "" {
				progress = "-"
			}
			fmt.Fprintf(&b, " task=%s:%s,progress=%q,duration=%ds",
				t.Kind, t.Description, progress, dur)
		}
		b.WriteByte('\n')
		line = b.String()
	}

	writeHeartbeatLine(path, line)
}

// snapshotActiveTasks returns just the running tasks from the uitask manager.
// Finished ones are excluded — the heartbeat is about live activity, not history.
func (s *Server) snapshotActiveTasks() ([]uitask.Info, error) {
	all := s.taskmgr.ListTasks()
	out := all[:0]
	for _, t := range all {
		if t.Status == uitask.StatusRunning {
			out = append(out, t)
		}
	}
	return out, nil
}

// writeHeartbeatLine appends one line to the heartbeat file (creating it if
// needed), or writes to stderr if path is empty. Each call opens-writes-closes
// to play nice with external log-rotation tooling.
func writeHeartbeatLine(path, line string) {
	if path == "" {
		_, _ = os.Stderr.WriteString(line)
		return
	}
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		// Fall back to stderr so the tick is never silent.
		_, _ = os.Stderr.WriteString(line)
		return
	}
	_, _ = f.WriteString(line)
	_ = f.Close()
}
