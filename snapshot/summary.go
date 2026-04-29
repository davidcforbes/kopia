package snapshot

import (
	"fmt"
	"strings"
	"time"
)

// SnapshotSummary is a compact, machine-friendly summary of a completed
// snapshot run. It is emitted as one structured INFO log line and as a
// "summary" field in --json output so wrappers can verify a run without
// parsing debug logs.
type SnapshotSummary struct {
	Source           string `json:"source"`
	Root             string `json:"root"`
	ID               string `json:"id"`
	DurationSeconds  int64  `json:"durationSeconds"`
	Files            int32  `json:"files"`
	Dirs             int32  `json:"dirs"`
	Bytes            int64  `json:"bytes"`
	CachedFiles      int32  `json:"cachedFiles"`
	NonCachedFiles   int32  `json:"nonCachedFiles"`
	ExcludedFiles    int32  `json:"excludedFiles"`
	Errors           int32  `json:"errors"`
	IgnoredErrors    int32  `json:"ignoredErrors"`
	RetentionDeleted int    `json:"retentionDeleted"`
	Incomplete       string `json:"incomplete,omitempty"`
}

// NewSummary builds a SnapshotSummary from a completed manifest plus the
// number of snapshots deleted by retention policy in the same run.
func NewSummary(m *Manifest, retentionDeleted int) *SnapshotSummary {
	if m == nil {
		return nil
	}

	return &SnapshotSummary{
		Source:           m.Source.String(),
		Root:             m.RootObjectID().String(),
		ID:               string(m.ID),
		DurationSeconds:  int64(m.EndTime.Sub(m.StartTime).Truncate(time.Second).Seconds()),
		Files:            m.Stats.TotalFileCount,
		Dirs:             m.Stats.TotalDirectoryCount,
		Bytes:            m.Stats.TotalFileSize,
		CachedFiles:      m.Stats.CachedFiles,
		NonCachedFiles:   m.Stats.NonCachedFiles,
		ExcludedFiles:    m.Stats.ExcludedFileCount,
		Errors:           m.Stats.ErrorCount,
		IgnoredErrors:    m.Stats.IgnoredErrorCount,
		RetentionDeleted: retentionDeleted,
		Incomplete:       m.IncompleteReason,
	}
}

// LogString returns a single-line key=value rendering suitable for an INFO
// log line that wrappers can grep without jq. String fields that may
// contain spaces (source, incomplete) are quoted with %q; numeric and
// identifier fields are bare.
func (s *SnapshotSummary) LogString() string {
	if s == nil {
		return ""
	}

	var b strings.Builder

	b.WriteString("snapshot summary")
	fmt.Fprintf(&b, " source=%q", s.Source)
	fmt.Fprintf(&b, " root=%s", s.Root)
	fmt.Fprintf(&b, " id=%s", s.ID)
	fmt.Fprintf(&b, " duration=%ds", s.DurationSeconds)
	fmt.Fprintf(&b, " files=%d", s.Files)
	fmt.Fprintf(&b, " dirs=%d", s.Dirs)
	fmt.Fprintf(&b, " bytes=%d", s.Bytes)
	fmt.Fprintf(&b, " cached_files=%d", s.CachedFiles)
	fmt.Fprintf(&b, " non_cached_files=%d", s.NonCachedFiles)
	fmt.Fprintf(&b, " excluded_files=%d", s.ExcludedFiles)
	fmt.Fprintf(&b, " errors=%d", s.Errors)
	fmt.Fprintf(&b, " ignored_errors=%d", s.IgnoredErrors)
	fmt.Fprintf(&b, " retention_deleted=%d", s.RetentionDeleted)
	fmt.Fprintf(&b, " incomplete=%q", s.Incomplete)

	return b.String()
}
