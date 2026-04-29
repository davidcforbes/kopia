package snapshot_test

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/kopia/kopia/fs"
	"github.com/kopia/kopia/repo/manifest"
	"github.com/kopia/kopia/repo/object"
	"github.com/kopia/kopia/snapshot"
)

func makeManifest(t *testing.T) *snapshot.Manifest {
	t.Helper()

	start := time.Date(2026, 4, 28, 14, 48, 14, 0, time.UTC)
	end := start.Add(54 * time.Second)

	rootOID, err := object.ParseID("kdf70d354dcf95e12a2be02e9bf5386d1")
	if err != nil {
		t.Fatalf("ParseID: %v", err)
	}

	return &snapshot.Manifest{
		ID:        manifest.ID("f183d4ea86b46190826c793865cf7ce7"),
		Source:    snapshot.SourceInfo{Host: "host1", UserName: "alice", Path: `C:\dev`},
		StartTime: fs.UTCTimestampFromTime(start),
		EndTime:   fs.UTCTimestampFromTime(end),
		Stats: snapshot.Stats{
			TotalFileSize:       18 * 1024 * 1024 * 1024,
			TotalFileCount:      1234567,
			CachedFiles:         1230000,
			NonCachedFiles:      4567,
			TotalDirectoryCount: 89012,
			ExcludedFileCount:   42,
			ErrorCount:          0,
			IgnoredErrorCount:   3,
		},
		RootEntry: &snapshot.DirEntry{
			Name:     "dev",
			Type:     snapshot.EntryTypeDirectory,
			ObjectID: rootOID,
		},
	}
}

func TestNewSummary_Fields(t *testing.T) {
	m := makeManifest(t)
	s := snapshot.NewSummary(m, 1)

	if s == nil {
		t.Fatalf("NewSummary returned nil")
	}

	if got, want := s.Source, `alice@host1:C:\dev`; got != want {
		t.Errorf("Source = %q, want %q", got, want)
	}

	if got, want := s.Root, "kdf70d354dcf95e12a2be02e9bf5386d1"; got != want {
		t.Errorf("Root = %q, want %q", got, want)
	}

	if got, want := s.ID, "f183d4ea86b46190826c793865cf7ce7"; got != want {
		t.Errorf("ID = %q, want %q", got, want)
	}

	if got, want := s.DurationSeconds, int64(54); got != want {
		t.Errorf("DurationSeconds = %d, want %d", got, want)
	}

	if got, want := s.Files, int32(1234567); got != want {
		t.Errorf("Files = %d, want %d", got, want)
	}

	if got, want := s.Dirs, int32(89012); got != want {
		t.Errorf("Dirs = %d, want %d", got, want)
	}

	if got, want := s.Bytes, int64(18*1024*1024*1024); got != want {
		t.Errorf("Bytes = %d, want %d", got, want)
	}

	if got, want := s.CachedFiles, int32(1230000); got != want {
		t.Errorf("CachedFiles = %d, want %d", got, want)
	}

	if got, want := s.NonCachedFiles, int32(4567); got != want {
		t.Errorf("NonCachedFiles = %d, want %d", got, want)
	}

	if got, want := s.ExcludedFiles, int32(42); got != want {
		t.Errorf("ExcludedFiles = %d, want %d", got, want)
	}

	if got, want := s.Errors, int32(0); got != want {
		t.Errorf("Errors = %d, want %d", got, want)
	}

	if got, want := s.IgnoredErrors, int32(3); got != want {
		t.Errorf("IgnoredErrors = %d, want %d", got, want)
	}

	if got, want := s.RetentionDeleted, 1; got != want {
		t.Errorf("RetentionDeleted = %d, want %d", got, want)
	}

	if got, want := s.Incomplete, ""; got != want {
		t.Errorf("Incomplete = %q, want %q", got, want)
	}
}

func TestNewSummary_Incomplete(t *testing.T) {
	m := makeManifest(t)
	m.IncompleteReason = "canceled"

	s := snapshot.NewSummary(m, 0)
	if s.Incomplete != "canceled" {
		t.Errorf("Incomplete = %q, want %q", s.Incomplete, "canceled")
	}
}

func TestNewSummary_Nil(t *testing.T) {
	if got := snapshot.NewSummary(nil, 0); got != nil {
		t.Errorf("NewSummary(nil) = %+v, want nil", got)
	}
}

func TestLogString_RoundTrip(t *testing.T) {
	m := makeManifest(t)
	m.Source.Path = `C:\Program Files\With Space`
	m.IncompleteReason = "user canceled"

	s := snapshot.NewSummary(m, 2)
	line := s.LogString()

	if !strings.HasPrefix(line, "snapshot summary ") {
		t.Errorf("LogString missing prefix: %q", line)
	}

	wantSubstrings := []string{
		`source="alice@host1:C:\\Program Files\\With Space"`,
		"root=kdf70d354dcf95e12a2be02e9bf5386d1",
		"id=f183d4ea86b46190826c793865cf7ce7",
		"duration=54s",
		"files=1234567",
		"dirs=89012",
		"errors=0",
		"ignored_errors=3",
		"retention_deleted=2",
		`incomplete="user canceled"`,
	}
	for _, w := range wantSubstrings {
		if !strings.Contains(line, w) {
			t.Errorf("LogString missing %q\n  got: %s", w, line)
		}
	}

	if strings.Count(line, "\n") != 0 {
		t.Errorf("LogString contains newline (must be single-line): %q", line)
	}
}

func TestLogString_NilReceiver(t *testing.T) {
	var s *snapshot.SnapshotSummary

	if got := s.LogString(); got != "" {
		t.Errorf("nil.LogString() = %q, want empty", got)
	}
}

func TestSnapshotSummary_JSONRoundTrip(t *testing.T) {
	m := makeManifest(t)
	s := snapshot.NewSummary(m, 1)

	b, err := json.Marshal(s)
	if err != nil {
		t.Fatalf("Marshal: %v", err)
	}

	var got snapshot.SnapshotSummary
	if err := json.Unmarshal(b, &got); err != nil {
		t.Fatalf("Unmarshal: %v", err)
	}

	if got.Files != s.Files || got.Errors != s.Errors || got.RetentionDeleted != s.RetentionDeleted {
		t.Errorf("round trip mismatch:\n  before: %+v\n  after:  %+v", s, got)
	}
}
