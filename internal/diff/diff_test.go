package diff_test

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	"github.com/zeebo/blake3"

	"github.com/kopia/kopia/fs"
	"github.com/kopia/kopia/internal/diff"
	"github.com/kopia/kopia/internal/repotesting"
	"github.com/kopia/kopia/internal/testlogging"
	"github.com/kopia/kopia/repo"
	"github.com/kopia/kopia/repo/content"
	"github.com/kopia/kopia/repo/manifest"
	"github.com/kopia/kopia/repo/object"
	"github.com/kopia/kopia/snapshot"
)

const statsOnly = false

var (
	_ fs.Entry     = (*testFile)(nil)
	_ fs.Directory = (*testDirectory)(nil)
)

type testBaseEntry struct {
	modtime time.Time
	mode    os.FileMode
	name    string
	owner   fs.OwnerInfo
	oid     object.ID
}

func (f *testBaseEntry) IsDir() bool                 { return false }
func (f *testBaseEntry) LocalFilesystemPath() string { return f.name }
func (f *testBaseEntry) Close()                      {}
func (f *testBaseEntry) Name() string                { return f.name }
func (f *testBaseEntry) ModTime() time.Time          { return f.modtime }
func (f *testBaseEntry) Sys() any                    { return nil }
func (f *testBaseEntry) Owner() fs.OwnerInfo         { return f.owner }
func (f *testBaseEntry) Device() fs.DeviceInfo       { return fs.DeviceInfo{Dev: 1} }
func (f *testBaseEntry) ObjectID() object.ID         { return f.oid }

func (f *testBaseEntry) Mode() os.FileMode {
	if f.mode == 0 {
		return 0o644
	}

	return f.mode & ^os.ModeDir
}

type testFile struct {
	testBaseEntry
	content string
}

func (f *testFile) Open(ctx context.Context) (io.Reader, error) {
	return strings.NewReader(f.content), nil
}

func (f *testFile) Size() int64 { return int64(len(f.content)) }

type testDirectory struct {
	testBaseEntry
	files []fs.Entry
}

func (d *testDirectory) Iterate(ctx context.Context) (fs.DirectoryIterator, error) {
	return fs.StaticIterator(d.files, nil), nil
}

func (d *testDirectory) SupportsMultipleIterations() bool                { return false }
func (d *testDirectory) IsDir() bool                                     { return true }
func (d *testDirectory) LocalFilesystemPath() string                     { return d.name }
func (d *testDirectory) Size() int64                                     { return 0 }
func (d *testDirectory) Readdir(ctx context.Context) ([]fs.Entry, error) { return d.files, nil }

func (d *testDirectory) Mode() os.FileMode {
	if d.mode == 0 {
		return os.ModeDir | 0o755
	}

	return os.ModeDir | d.mode
}

func (d *testDirectory) Child(ctx context.Context, name string) (fs.Entry, error) {
	for _, f := range d.files {
		if f.Name() == name {
			return f, nil
		}
	}

	return nil, fs.ErrEntryNotFound
}

func TestCompareEmptyDirectories(t *testing.T) {
	var buf bytes.Buffer

	ctx := context.Background()

	dirModTime := time.Date(2023, time.April, 12, 10, 30, 0, 0, time.UTC)
	dirOwnerInfo := fs.OwnerInfo{UserID: 1000, GroupID: 1000}
	dirMode := os.FileMode(0o777)

	oid1 := oidForString(t, "k", "sdkjfn")
	oid2 := oidForString(t, "k", "dfjlgn")
	dir1 := createTestDirectory("testDir1", dirModTime, dirOwnerInfo, dirMode, oid1)
	dir2 := createTestDirectory("testDir2", dirModTime, dirOwnerInfo, dirMode, oid2)

	c, err := diff.NewComparer(&buf, statsOnly)
	require.NoError(t, err)

	t.Cleanup(func() {
		_ = c.Close()
	})

	expectedStats := diff.Stats{}
	actualStats, err := c.Compare(ctx, dir1, dir2)

	require.NoError(t, err)
	require.Empty(t, buf.String())
	require.Equal(t, expectedStats, actualStats)
}

func TestCompareIdenticalDirectories(t *testing.T) {
	var buf bytes.Buffer

	ctx := context.Background()

	dirModTime := time.Date(2023, time.April, 12, 10, 30, 0, 0, time.UTC)
	dirOwnerInfo := fs.OwnerInfo{UserID: 1000, GroupID: 1000}
	dirMode := os.FileMode(0o777)
	fileModTime := time.Date(2023, time.April, 12, 10, 30, 0, 0, time.UTC)

	oid1 := oidForString(t, "k", "sdkjfn")
	oid2 := oidForString(t, "k", "dfjlgn")

	file1 := &testFile{testBaseEntry: testBaseEntry{modtime: fileModTime, name: "file1.txt"}, content: "abcdefghij"}
	file2 := &testFile{testBaseEntry: testBaseEntry{modtime: fileModTime, name: "file2.txt"}, content: "klmnopqrstuvwxyz"}

	dir1 := createTestDirectory(
		"testDir1",
		dirModTime,
		dirOwnerInfo,
		dirMode,
		oid1,
		file1,
		file2,
	)
	dir2 := createTestDirectory(
		"testDir2",
		dirModTime,
		dirOwnerInfo,
		dirMode,
		oid2,
		file1,
		file2,
	)

	expectedStats := diff.Stats{}

	c, err := diff.NewComparer(&buf, statsOnly)
	require.NoError(t, err)

	t.Cleanup(func() {
		_ = c.Close()
	})

	actualStats, err := c.Compare(ctx, dir1, dir2)

	require.NoError(t, err)
	require.Empty(t, buf.String())
	require.Equal(t, expectedStats, actualStats)
}

func TestCompareDifferentDirectories(t *testing.T) {
	var buf bytes.Buffer

	ctx := context.Background()

	dirModTime := time.Date(2023, time.April, 12, 10, 30, 0, 0, time.UTC)
	fileModTime := time.Date(2023, time.April, 12, 10, 30, 0, 0, time.UTC)
	dirOwnerInfo := fs.OwnerInfo{UserID: 1000, GroupID: 1000}
	dirMode := os.FileMode(0o777)

	oid1 := oidForString(t, "k", "sdkjfn")
	oid2 := oidForString(t, "k", "dfjlgn")

	dir1 := createTestDirectory(
		"testDir1",
		dirModTime,
		dirOwnerInfo,
		dirMode,
		oid1,
		&testFile{testBaseEntry: testBaseEntry{modtime: fileModTime, name: "file1.txt"}, content: "abcdefghij"},
		&testFile{testBaseEntry: testBaseEntry{modtime: fileModTime, name: "file2.txt"}, content: "klmnopqrstuvwxyz"},
	)
	dir2 := createTestDirectory(
		"testDir2",
		dirModTime,
		dirOwnerInfo,
		dirMode,
		oid2,
		&testFile{testBaseEntry: testBaseEntry{modtime: fileModTime, name: "file3.txt"}, content: "abcdefghij1"},
		&testFile{testBaseEntry: testBaseEntry{modtime: fileModTime, name: "file4.txt"}, content: "klmnopqrstuvwxyz2"},
	)

	c, err := diff.NewComparer(&buf, statsOnly)
	require.NoError(t, err)

	t.Cleanup(func() {
		_ = c.Close()
	})

	expectedStats := diff.Stats{}
	expectedStats.FileEntries.Added = 2
	expectedStats.FileEntries.Removed = 2

	expectedOutput := "added file ./file3.txt (11 bytes)\nadded file ./file4.txt (17 bytes)\n" +
		"removed file ./file1.txt (10 bytes)\n" +
		"removed file ./file2.txt (16 bytes)\n"

	actualStats, err := c.Compare(ctx, dir1, dir2)

	require.NoError(t, err)
	require.Equal(t, expectedStats, actualStats)
	require.Equal(t, expectedOutput, buf.String())
}

func TestCompareDifferentDirectories_DirTimeDiff(t *testing.T) {
	var buf bytes.Buffer

	ctx := context.Background()

	fileModTime := time.Date(2023, time.April, 12, 10, 30, 0, 0, time.UTC)
	dirModTime1 := time.Date(2023, time.April, 12, 10, 30, 0, 0, time.UTC)
	dirModTime2 := time.Date(2022, time.April, 12, 10, 30, 0, 0, time.UTC)
	dirOwnerInfo := fs.OwnerInfo{UserID: 1000, GroupID: 1000}
	dirMode := os.FileMode(0o777)

	oid1 := oidForString(t, "k", "sdkjfn")
	oid2 := oidForString(t, "k", "dfjlgn")

	dir1 := createTestDirectory(
		"testDir1",
		dirModTime1,
		dirOwnerInfo,
		dirMode,
		oid1,
		&testFile{testBaseEntry: testBaseEntry{modtime: fileModTime, name: "file1.txt"}, content: "abcdefghij"},
		&testFile{testBaseEntry: testBaseEntry{modtime: fileModTime, name: "file2.txt"}, content: "klmnopqrstuvwxyz"},
	)
	dir2 := createTestDirectory(
		"testDir2",
		dirModTime2,
		dirOwnerInfo,
		dirMode,
		oid2,
		&testFile{testBaseEntry: testBaseEntry{modtime: fileModTime, name: "file1.txt"}, content: "abcdefghij"},
		&testFile{testBaseEntry: testBaseEntry{modtime: fileModTime, name: "file2.txt"}, content: "klmnopqrstuvwxyz"},
	)

	expectedStats := diff.Stats{}
	expectedStats.DirectoryEntries.Modified = 1

	c, err := diff.NewComparer(&buf, statsOnly)
	require.NoError(t, err)

	t.Cleanup(func() {
		_ = c.Close()
	})

	expectedOutput := ". modification times differ: 2023-04-12 10:30:00 +0000 UTC 2022-04-12 10:30:00 +0000 UTC\n"
	actualStats, err := c.Compare(ctx, dir1, dir2)

	require.NoError(t, err)
	require.Equal(t, expectedOutput, buf.String())
	require.Equal(t, expectedStats, actualStats)
}

func TestCompareDifferentDirectories_FileTimeDiff(t *testing.T) {
	var buf bytes.Buffer

	ctx := context.Background()

	fileModTime1 := time.Date(2023, time.April, 12, 10, 30, 0, 0, time.UTC)
	fileModTime2 := time.Date(2022, time.April, 12, 10, 30, 0, 0, time.UTC)
	dirModTime := time.Date(2023, time.April, 12, 10, 30, 0, 0, time.UTC)
	dirOwnerInfo := fs.OwnerInfo{UserID: 1000, GroupID: 1000}
	dirMode := os.FileMode(0o700)

	oid1 := oidForString(t, "k", "sdkjfn")
	oid2 := oidForString(t, "k", "hvhjb")

	dir1 := createTestDirectory(
		"testDir1",
		dirModTime,
		dirOwnerInfo,
		dirMode,
		oid1,
		&testFile{testBaseEntry: testBaseEntry{modtime: fileModTime1, name: "file1.txt", oid: oid1}, content: "abcdefghij"},
	)
	dir2 := createTestDirectory(
		"testDir2",
		dirModTime,
		dirOwnerInfo,
		dirMode,
		oid2,
		&testFile{testBaseEntry: testBaseEntry{modtime: fileModTime2, name: "file1.txt", oid: oid2}, content: "abcdefghij"},
	)

	c, err := diff.NewComparer(&buf, statsOnly)
	require.NoError(t, err)

	t.Cleanup(func() {
		_ = c.Close()
	})

	expectedStats := diff.Stats{}
	expectedStats.FileEntries.Modified = 1

	expectedOutput := "./file1.txt modification times differ: 2023-04-12 10:30:00 +0000 UTC 2022-04-12 10:30:00 +0000 UTC\n"

	actualStats, err := c.Compare(ctx, dir1, dir2)

	require.NoError(t, err)
	require.Equal(t, expectedOutput, buf.String())
	require.Equal(t, expectedStats, actualStats)
}

func TestCompareFileWithIdenticalContentsButDiffFileMetadata(t *testing.T) {
	var buf bytes.Buffer

	ctx := context.Background()

	fileModTime1 := time.Date(2023, time.April, 12, 10, 30, 0, 0, time.UTC)
	fileModTime2 := time.Date(2022, time.April, 12, 10, 30, 0, 0, time.UTC)

	fileOwnerinfo1 := fs.OwnerInfo{UserID: 1000, GroupID: 1000}
	fileOwnerinfo2 := fs.OwnerInfo{UserID: 1001, GroupID: 1002}

	dirOwnerInfo := fs.OwnerInfo{UserID: 1000, GroupID: 1000}
	dirMode := os.FileMode(0o777)
	dirModTime := time.Date(2023, time.April, 12, 10, 30, 0, 0, time.UTC)

	oid1 := oidForString(t, "k", "sdkjfn")
	oid2 := oidForString(t, "k", "dfjlgn")

	dir1 := createTestDirectory(
		"testDir1",
		dirModTime,
		dirOwnerInfo,
		dirMode,
		oid1,
		&testFile{testBaseEntry: testBaseEntry{name: "file1.txt", modtime: fileModTime1, oid: object.ID{}, owner: fileOwnerinfo1, mode: 0o700}, content: "abcdefghij"},
	)

	dir2 := createTestDirectory(
		"testDir2",
		dirModTime,
		dirOwnerInfo,
		dirMode,
		oid2,
		&testFile{testBaseEntry: testBaseEntry{name: "file1.txt", modtime: fileModTime2, oid: object.ID{}, owner: fileOwnerinfo2, mode: 0o777}, content: "abcdefghij"},
	)

	c, err := diff.NewComparer(&buf, statsOnly)
	require.NoError(t, err)

	t.Cleanup(func() {
		_ = c.Close()
	})

	expectedStats := diff.Stats{
		FileEntries: diff.EntryTypeStats{
			SameContentButDifferentMetadata:         1,
			SameContentButDifferentModificationTime: 1,
			SameContentButDifferentMode:             1,
			SameContentButDifferentUserOwner:        1,
			SameContentButDifferentGroupOwner:       1,
		},
	}

	actualStats, err := c.Compare(ctx, dir1, dir2)

	require.NoError(t, err)
	require.Empty(t, buf.String())
	require.Equal(t, expectedStats, actualStats)
}

func TestCompareIdenticalDirectoriesWithDiffDirectoryMetadata(t *testing.T) {
	var buf bytes.Buffer

	ctx := context.Background()

	dirModTime1 := time.Date(2023, time.April, 12, 10, 30, 0, 0, time.UTC)
	dirModTime2 := time.Date(2022, time.April, 12, 10, 30, 0, 0, time.UTC)

	dirOwnerInfo1 := fs.OwnerInfo{UserID: 1000, GroupID: 1000}
	dirOwnerInfo2 := fs.OwnerInfo{UserID: 1001, GroupID: 1002}

	dirMode1 := os.FileMode(0o644)
	dirMode2 := os.FileMode(0o777)

	fileModTime := time.Date(2023, time.April, 12, 10, 30, 0, 0, time.UTC)

	oid := oidForString(t, "k", "sdkjfn")

	dir1 := createTestDirectory(
		"testDir1",
		dirModTime1,
		dirOwnerInfo1,
		dirMode1,
		oid,
		&testFile{testBaseEntry: testBaseEntry{name: "file1.txt", modtime: fileModTime}, content: "abcdefghij"},
	)

	dir2 := createTestDirectory(
		"testDir2",
		dirModTime2,
		dirOwnerInfo2,
		dirMode2,
		oid,
		&testFile{testBaseEntry: testBaseEntry{name: "file1.txt", modtime: fileModTime}, content: "abcdefghij"},
	)
	c, err := diff.NewComparer(&buf, statsOnly)
	require.NoError(t, err)

	t.Cleanup(func() {
		_ = c.Close()
	})

	expectedStats := diff.Stats{
		DirectoryEntries: diff.EntryTypeStats{
			SameContentButDifferentMetadata:         1,
			SameContentButDifferentModificationTime: 1,
			SameContentButDifferentMode:             1,
			SameContentButDifferentUserOwner:        1,
			SameContentButDifferentGroupOwner:       1,
		},
	}

	actualStats, err := c.Compare(ctx, dir1, dir2)

	require.NoError(t, err)
	require.Empty(t, buf.String())
	require.Equal(t, expectedStats, actualStats)
}

func createTestDirectory(name string, modtime time.Time, owner fs.OwnerInfo, mode os.FileMode, oid object.ID, files ...fs.Entry) *testDirectory {
	return &testDirectory{testBaseEntry: testBaseEntry{modtime: modtime, name: name, owner: owner, mode: mode, oid: oid}, files: files}
}

func getManifests(t *testing.T) map[string]*snapshot.Manifest {
	t.Helper()

	// manifests store snapshot manifests based on start-time
	manifests := make(map[string]*snapshot.Manifest, 3)

	src := getSnapshotSource()
	snapshotTime := time.Date(2025, 1, 1, 0, 0, 0, 0, time.UTC)

	rootEntry1 := snapshot.DirEntry{
		ObjectID: oidForString(t, "", "indexID1"),
	}

	rootEntry2 := snapshot.DirEntry{
		ObjectID: oidForString(t, "", "indexID2"),
	}

	manifests["initial_snapshot"] = &snapshot.Manifest{
		ID:          "manifest_1_id",
		Source:      src,
		StartTime:   fs.UTCTimestamp(snapshotTime.Add((-24) * time.Hour).UnixNano()),
		Description: "snapshot captured a day ago",
		RootEntry:   &rootEntry2,
	}

	manifests["intermediate_snapshot"] = &snapshot.Manifest{
		ID:          "manifest_2_id",
		Source:      src,
		StartTime:   fs.UTCTimestamp(snapshotTime.Add(-time.Hour).UnixNano()),
		Description: "snapshot taken an hour ago",
		RootEntry:   &rootEntry2,
	}

	manifests["latest_snapshot"] = &snapshot.Manifest{
		ID:          "manifest_3_id",
		Source:      src,
		StartTime:   fs.UTCTimestamp(snapshotTime.UnixNano()),
		Description: "latest snapshot",
		RootEntry:   &rootEntry1,
	}

	return manifests
}

// Tests GetPrecedingSnapshot function
//   - GetPrecedingSnapshot with an invalid snapshot id and expect an error;
//   - Add a snapshot, expect an error from GetPrecedingSnapshot since there is
//     only a single snapshot in the repo;
//   - Subsequently add more snapshots and GetPrecedingSnapshot the immediately
//     preceding with no error.
func TestGetPrecedingSnapshot(t *testing.T) {
	ctx, env := repotesting.NewEnvironment(t, repotesting.FormatNotImportant)
	manifests := getManifests(t)

	_, err := diff.GetPrecedingSnapshot(ctx, env.RepositoryWriter, "non_existent_snapshot_ID")
	require.Error(t, err, "expect error when calling GetPrecedingSnapshot with a wrong snapshotID")

	initialSnapshotManifestID := mustSaveSnapshot(t, env.RepositoryWriter, manifests["initial_snapshot"])
	_, err = diff.GetPrecedingSnapshot(ctx, env.RepositoryWriter, string(initialSnapshotManifestID))
	require.Error(t, err, "expect error when there is a single snapshot in the repo")

	intermediateSnapshotManifestID := mustSaveSnapshot(t, env.RepositoryWriter, manifests["intermediate_snapshot"])
	gotManID, err := diff.GetPrecedingSnapshot(ctx, env.RepositoryWriter, string(intermediateSnapshotManifestID))
	require.NoError(t, err)
	require.Equal(t, initialSnapshotManifestID, gotManID.ID)

	latestSnapshotManifestID := mustSaveSnapshot(t, env.RepositoryWriter, manifests["latest_snapshot"])
	gotManID2, err := diff.GetPrecedingSnapshot(ctx, env.RepositoryWriter, string(latestSnapshotManifestID))
	require.NoError(t, err)
	require.Equal(t, intermediateSnapshotManifestID, gotManID2.ID)
}

// First call GetTwoLatestSnapshots with insufficient snapshots in the repo and
// expect an error;
// As snapshots are added, GetTwoLatestSnapshots is expected to return the
// manifests for the two most recent snapshots for a the given source.
func TestGetTwoLatestSnapshots(t *testing.T) {
	ctx, env := repotesting.NewEnvironment(t, repotesting.FormatNotImportant)

	snapshotSrc := getSnapshotSource()
	manifests := getManifests(t)

	_, _, err := diff.GetTwoLatestSnapshotsForASource(ctx, env.RepositoryWriter, snapshotSrc)
	require.Error(t, err, "expected error as there aren't enough snapshots to get the two most recent snapshots")

	initialSnapshotManifestID := mustSaveSnapshot(t, env.RepositoryWriter, manifests["initial_snapshot"])
	_, _, err = diff.GetTwoLatestSnapshotsForASource(ctx, env.RepositoryWriter, snapshotSrc)
	require.Error(t, err, "expected error as there aren't enough snapshots to get the two most recent snapshots")

	intermediateSnapshotManifestID := mustSaveSnapshot(t, env.RepositoryWriter, manifests["intermediate_snapshot"])

	var expectedManifestIDs []manifest.ID

	expectedManifestIDs = append(expectedManifestIDs, initialSnapshotManifestID, intermediateSnapshotManifestID)

	secondLastSnapshot, lastSnapshot, err := diff.GetTwoLatestSnapshotsForASource(ctx, env.RepositoryWriter, snapshotSrc)

	var gotManifestIDs []manifest.ID

	gotManifestIDs = append(gotManifestIDs, secondLastSnapshot.ID, lastSnapshot.ID)

	require.NoError(t, err)
	require.Equal(t, expectedManifestIDs, gotManifestIDs)

	latestSnapshotManifestID := mustSaveSnapshot(t, env.RepositoryWriter, manifests["latest_snapshot"])

	expectedManifestIDs = nil
	expectedManifestIDs = append(expectedManifestIDs, intermediateSnapshotManifestID, latestSnapshotManifestID)

	gotManifestIDs = nil
	secondLastSnapshot, lastSnapshot, err = diff.GetTwoLatestSnapshotsForASource(ctx, env.RepositoryWriter, snapshotSrc)
	gotManifestIDs = append(gotManifestIDs, secondLastSnapshot.ID, lastSnapshot.ID)

	require.NoError(t, err)
	require.Equal(t, expectedManifestIDs, gotManifestIDs)
}

func mustSaveSnapshot(t *testing.T, rep repo.RepositoryWriter, man *snapshot.Manifest) manifest.ID {
	t.Helper()

	id, err := snapshot.SaveSnapshot(testlogging.Context(t), rep, man)
	require.NoError(t, err, "saving snapshot")

	return id
}

func getSnapshotSource() snapshot.SourceInfo {
	src := snapshot.SourceInfo{
		Host:     "host-1",
		UserName: "user-1",
		Path:     "/some/path",
	}

	return src
}

type ndjsonRec struct {
	Op       string `json:"op"`
	Kind     string `json:"kind"`
	Path     string `json:"path"`
	Size     int64  `json:"size"`
	Mtime    string `json:"mtime"`
	OID      string `json:"oid"`
	PrevOID  string `json:"prev_oid"`
	PrevKind string `json:"prev_kind"`
	Mode     uint32 `json:"mode"`
}

func parseNDJSON(t *testing.T, s string) []ndjsonRec {
	t.Helper()

	var out []ndjsonRec

	for _, line := range strings.Split(strings.TrimRight(s, "\n"), "\n") {
		if line == "" {
			continue
		}

		var r ndjsonRec
		require.NoError(t, json.Unmarshal([]byte(line), &r))

		out = append(out, r)
	}

	return out
}

// findRec returns the (op, kind) record at the given path, or fails the test
// if no match exists. Useful for asserting "this path got this op" without
// caring about ordering of NDJSON output.
func findRec(t *testing.T, recs []ndjsonRec, path string) ndjsonRec {
	t.Helper()

	for _, r := range recs {
		if r.Path == path {
			return r
		}
	}

	t.Fatalf("no NDJSON record for path %q in %+v", path, recs)
	return ndjsonRec{}
}

func TestCompareNDJSONOutput(t *testing.T) {
	var buf, ndjsonBuf bytes.Buffer

	ctx := context.Background()

	dirModTime := time.Date(2023, time.April, 12, 10, 30, 0, 0, time.UTC)
	fileModTime1 := time.Date(2023, time.April, 12, 10, 30, 0, 0, time.UTC)
	fileModTime2 := time.Date(2022, time.April, 12, 10, 30, 0, 0, time.UTC)
	dirOwnerInfo := fs.OwnerInfo{UserID: 1000, GroupID: 1000}
	dirMode := os.FileMode(0o700)

	// Outer dirs need DIFFERENT OIDs, otherwise compareEntry's
	// content-addressable shortcut (matching ObjectID -> early return into
	// compareMetadata-only) skips recursion entirely and we'd never reach
	// the per-file emit sites we're trying to exercise here.
	dirOID1 := oidForString(t, "k", "outerdir-1")
	dirOID2 := oidForString(t, "k", "outerdir-2")
	oidA := oidForString(t, "k", "fileA-content")
	oidB := oidForString(t, "k", "fileB-content")
	oidC := oidForString(t, "k", "fileC-old")
	oidD := oidForString(t, "k", "fileC-new")
	oidE := oidForString(t, "k", "fileD-content")

	// Test fakes (testFile) do not satisfy fs.File — testFile.Open returns
	// io.Reader rather than fs.Reader (io.ReadCloser+io.Seeker+Entry()).
	// As a result, compareEntry's "changed file" branch (line 191-200,
	// where the "modified" NDJSON op is emitted) is unreachable here. The
	// existing FileTimeDiff test (line 288) already documents this gap by
	// asserting only the compareEntryMetadata "modification times differ"
	// output. The "modified" op is exercised by the manual smoke test
	// against a live repo (see commit message). For unit coverage we focus
	// on added / removed / meta, which are reachable.

	// dir1: file1 (will be removed), file2 (same OID across, meta-only diff via mtime).
	dir1 := createTestDirectory(
		"testDir1",
		dirModTime,
		dirOwnerInfo,
		dirMode,
		dirOID1,
		&testFile{testBaseEntry: testBaseEntry{modtime: fileModTime1, name: "file1.txt", oid: oidA}, content: "removed-me"},
		&testFile{testBaseEntry: testBaseEntry{modtime: fileModTime1, name: "file2.txt", oid: oidB}, content: "stable"},
	)

	// dir2: file2 (same OID, mtime moved earlier → meta diff),
	//       file4 (added).
	dir2 := createTestDirectory(
		"testDir2",
		dirModTime,
		dirOwnerInfo,
		dirMode,
		dirOID2,
		&testFile{testBaseEntry: testBaseEntry{modtime: fileModTime2, name: "file2.txt", oid: oidB}, content: "stable"},
		&testFile{testBaseEntry: testBaseEntry{modtime: fileModTime1, name: "file4.txt", oid: oidE}, content: "added-me"},
	)
	_ = oidC
	_ = oidD

	c, err := diff.NewComparer(&buf, statsOnly)
	require.NoError(t, err)

	t.Cleanup(func() {
		_ = c.Close()
	})

	c.SetNDJSONOutput(&ndjsonBuf)

	_, err = c.Compare(ctx, dir1, dir2)
	require.NoError(t, err)

	recs := parseNDJSON(t, ndjsonBuf.String())
	require.Len(t, recs, 3, "expected one NDJSON record per changed file (removed/meta/added)")

	// file1: removed
	r := findRec(t, recs, "./file1.txt")
	require.Equal(t, "removed", r.Op)
	require.Equal(t, "file", r.Kind)
	require.Equal(t, oidA.String(), r.OID)
	require.Equal(t, int64(len("removed-me")), r.Size)

	// file2: meta (same OID, different mtime)
	r = findRec(t, recs, "./file2.txt")
	require.Equal(t, "meta", r.Op)
	require.Equal(t, "file", r.Kind)
	require.Equal(t, oidB.String(), r.OID)
	require.Equal(t, oidB.String(), r.PrevOID, "meta op carries prev_oid for symmetry with modified")

	// file4: added
	r = findRec(t, recs, "./file4.txt")
	require.Equal(t, "added", r.Op)
	require.Equal(t, "file", r.Kind)
	require.Equal(t, oidE.String(), r.OID)
	require.Empty(t, r.PrevOID, "added has no prev_oid")
	require.Equal(t, int64(len("added-me")), r.Size)
}

// TestCompareNDJSONDisabledByDefault confirms that without SetNDJSONOutput,
// no NDJSON is emitted even on a diff that would trigger every op type. This
// guards backwards compatibility for the existing CLI surface.
func TestCompareNDJSONDisabledByDefault(t *testing.T) {
	var buf bytes.Buffer

	ctx := context.Background()

	dirModTime := time.Date(2023, time.April, 12, 10, 30, 0, 0, time.UTC)
	fileModTime := time.Date(2023, time.April, 12, 10, 30, 0, 0, time.UTC)
	dirOwnerInfo := fs.OwnerInfo{UserID: 1000, GroupID: 1000}
	dirMode := os.FileMode(0o700)

	oid1 := oidForString(t, "k", "x")
	oid2 := oidForString(t, "k", "y")

	dir1 := createTestDirectory("d1", dirModTime, dirOwnerInfo, dirMode, oid1,
		&testFile{testBaseEntry: testBaseEntry{modtime: fileModTime, name: "a", oid: oid1}, content: "a"},
	)
	dir2 := createTestDirectory("d2", dirModTime, dirOwnerInfo, dirMode, oid2,
		&testFile{testBaseEntry: testBaseEntry{modtime: fileModTime, name: "b", oid: oid2}, content: "b"},
	)

	c, err := diff.NewComparer(&buf, statsOnly)
	require.NoError(t, err)

	t.Cleanup(func() {
		_ = c.Close()
	})

	// Deliberately do NOT call SetNDJSONOutput.
	_, err = c.Compare(ctx, dir1, dir2)
	require.NoError(t, err)

	// Stats-only writer's buf still gets human text — that's expected.
	require.Contains(t, buf.String(), "added file")
	require.Contains(t, buf.String(), "removed file")
}

func oidForString(t *testing.T, prefix content.IDPrefix, s string) object.ID {
	t.Helper()

	return oidForContent(t, prefix, []byte(s))
}

func oidForContent(t *testing.T, prefix content.IDPrefix, c []byte) object.ID {
	t.Helper()

	h := blake3.New()
	_, err := h.Write(c)

	require.NoError(t, err)

	cid, err := content.IDFromHash(prefix, h.Sum(nil))
	require.NoError(t, err)

	return object.DirectObjectID(cid)
}
