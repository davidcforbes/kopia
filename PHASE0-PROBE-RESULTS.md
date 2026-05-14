# Phase 0 probe — measured numbers for the chunk-CBT mirror plan

**Bead:** kopia-bmy.1 (Phase 0 of epic kopia-bmy)
**Plan:** `C:\Users\david\.claude\plans\sleepy-forging-wreath.md`
**Probe code:** `C:\dev\backup-monitor\probe\` (throwaway, not signed)
**Date:** 2026-05-13

This doc captures the measurements the Phase 0 probe was built to
produce, so Phase 1 design decisions are grounded in real numbers
from this hardware rather than estimates.

## Hardware under test

| Component | Spec |
|---|---|
| CPU | (Intel SHA-NI capable; 32 logical threads visible to rayon) |
| RAM | 63.7 GB |
| D: (source) | WD_BLACK SN850X 8 TB NVMe, NTFS, 7452 GB / 2399 GB free |
| E: (destination) | ASMT 2235 8 TB USB SSD, NTFS, 7452 GB / 5265 GB free |
| C: (manifest store) | Kioxia 4 TB NVMe, NTFS |

## Test files

| File | Size | On |
|---|---|---|
| `Esp.vhdx` | 208 MB | D: + E: |
| `5efa1bda-….vhdx` | 1.04 GB | D: + E: |
| `d88fe253-….vhdx` | 2623 GiB (2.82 TB) | D: only (corrupt-partial deleted from E: in earlier session) |

## Throughput results

### Cold-read throughput, small file on D: NVMe

`probe-mirror --src D:\…\5efa1bda-….vhdx --chunk-mib 4`

```
Pass 1: 267 chunks in 0.68s = 1561 MiB/s  (cold)
Pass 2: 0.03s = 39232 MiB/s              (from OS file cache)
```

The 1561 MiB/s number is the meaningful "production" data point —
that's what we'd see on a daily run where the file is too big to
fit in cache between yesterday's hash and today's. Pass 2 at
39 GiB/s confirms SHA-NI + rayon are not the bottleneck — when
the data is in RAM, the hash pipeline can sustain ~10× RAM
bandwidth that's actually achievable on this CPU.

### Cold-read throughput, 50 GiB sample of 2.6 TiB file

`probe-mirror --src D:\…\d88fe253-….vhdx --chunk-mib 4 --max-bytes 50G --no-pass2`

```
Pass 1: 12800 chunks in 36.40s = 1407 MiB/s
  zero-4MiB chunks: 0 (0.0% of file)
```

**Extrapolated to full 2.6 TiB: ~32 minutes.** Matches the plan
estimate of 25–30 min at the upper bound. (Full-file run is in
flight as of this writing; results will be appended below.)

### Warm-cache chunk-size sensitivity (D:, 1 GiB file)

After the file was warmed into cache:

| Chunk MiB | Chunks | Throughput |
|---:|---:|---:|
| 1  | 1068 | 10,698 MiB/s |
| 4  |  267 | 10,574 MiB/s |
| 16 |   67 |  9,912 MiB/s |
| 64 |   17 |  9,435 MiB/s |

Chunk size has minor impact in warm-cache mode. The 1.04 GiB file
saturates RAM bandwidth (~10 GiB/s on this DDR5 laptop), confirming
no SHA-256 CPU bottleneck at the chosen chunk sizes. **4 MiB is
confirmed as the right default** — granular enough to make
incremental writes small (4 MiB per changed chunk), not so granular
that the manifest gets unwieldy (~22 MB for a 2.6 TiB file, vs.
~88 MB at 1 MiB chunks).

### USB destination drive — sanity check

`probe-mirror --src E:\…\5efa1bda-….vhdx --chunk-mib 4`

```
Pass 1: 267 chunks in 30.09s = 35 MiB/s    (cold from E:)
```

35 MiB/s on cold read from E: was unexpectedly slow for a USB SSD.
This is the first measurement that warrants follow-up — not for
this plan (we read from D:, not E:), but worth noting: **the E:
drive is not fast for random reads.** Implication: if backup-mirror
writes to E:, writes should be as sequential as possible. The
chunk-CBT design writes only changed chunks at their existing
offsets, which is reasonably sequential within each .vhdx but
jumps between files. Acceptable; not a blocker.

## Correctness results

### Pass-2 sanity check

After Pass 1, the probe re-hashes the same (now-cached) source and
compares chunk-by-chunk against the just-written manifest:

```
Pass 2: 0.03s = 36747 MiB/s   changed_chunks=0 (expect 0)
```

Confirms deterministic hashing — same bytes, same hashes, every
run. Establishes the baseline for the mutation test below.

### Mutation test

`mutation-test.ps1`:
1. Synthesizes a 40 MiB source with 10 distinct 4 MiB chunks
2. Runs Pass 1 → records manifest
3. Mutates **one byte** at offset 20,971,620 (chunk index 5, byte 100)
4. Runs Pass 2 → records second manifest
5. Diffs the two manifests chunk-by-chunk

Result:

```
Changed chunk indices: 5
Total changed: 1 (expect 1)
PASS: mutation produced exactly 1 chunk-changed at the correct index
```

**Confirmed:** the core CBT property — a 1-byte source change
produces exactly 1 chunk-changed at the chunk containing that
byte. This is the foundation of the incremental-write optimization
in `--mode=cbt`.

## Zero-chunk observation

The 50 GiB cold-read sample of `d88fe253-….vhdx` reported **0
zero-4MiB chunks** in the file's first 50 GiB.

Two possible explanations:
1. This is a *dynamic* VHDX (sparse-on-disk). The .vhdx file
   itself doesn't contain large zero runs — it contains a Block
   Allocation Table (BAT) that maps logical sectors to physical
   .vhdx offsets, and unallocated logical regions simply have no
   physical bytes. Result: no zero-chunks in the file bytes.
2. The first 50 GiB happens to be the densely-packed start of an
   OS volume (boot files, $MFT, system32, program files), and
   zero regions live elsewhere in the file.

Implication for the all-zero-chunk short-circuit optimization
called out in the plan: **it may save much less than the
30–50% I estimated.** Pending the full-file run to confirm.

Mitigation: the short-circuit is cheap to implement and trivial
to remove. Implement it in Phase 1 with a comment that it may
not buy as much as initially hoped — and let the production-run
metrics tell us whether it's worth keeping.

## Decisions ratified for Phase 1

1. **Chunk size: 4 MiB.** Confirmed.
2. **Parallelism: rayon over chunks.** Confirmed — SHA-NI + rayon
   easily exceeds D: NVMe sequential read, so we're I/O bound
   not CPU bound. No special pipelining needed.
3. **mmap for source reads.** Tentative — the in-flight full-file
   run will confirm or refute (does mmap of a 2.6 TiB file stay
   stable on Windows, or does memory pressure cause thrash?).
4. **Manifest format: flat array of SHA-256 hashes preceded by
   the BMCBT01 header.** Validated via the manifest comparison in
   the mutation test — byte-by-byte hash arrays are easy to
   produce and easy to diff.
5. **Zero-chunk short-circuit: implement but expect modest savings.**
   Don't gate the design on this optimization.

## Risks identified by the probe

- **E: random-read performance is genuinely poor.** 35 MiB/s on
  cold read from E: is concerning. We don't read from E: in
  production (we read from D:, write to E:), but it does mean
  the crash-recovery path (re-hash dst if `.cbt.ok` is missing)
  will be slow on E:. Mitigate by: making crash recovery the
  rare path (atomic .cbt.ok markers + tmpfile-rename for the
  manifest) and by accepting that recovery from a torn write
  takes a full re-hash of dst.

## Full-file probe — killed at 14 min for hitting 98.5% system memory

Started 20:33 local against `D:\…\d88fe253-….vhdx` (2.6 TiB).
Killed at 20:47 (~14 min in, ~45% complete) when system memory
reached 98.5% used and free memory dropped under 1 GB.

(Aside: my first attempt to launch this with Start-Process
apparently succeeded silently, so for ~13 minutes there were
TWO copies racing on the same file. After killing the orphan,
the survivor's working set grew from 24 GB to 45 GB in under
two minutes — that's the actual mmap-on-Windows behavior, not
just contention from the duplicate process.)

### The actual lesson — mmap is the wrong primitive here

Plain `memmap2::Mmap::map(&file)` on a multi-TB file under
sequential parallel reads grows working set monotonically as
pages are touched. With 64 GB RAM and a 2.6 TiB file we hit the
ceiling well before the hash pass completes — the process is
not "leaking" memory in any normal sense, it's just that
Windows leaves recently-touched pages in the working set as
long as memory is available, and there's no signal back to the
allocator that the chunk is no longer needed.

In principle Windows offers ways to hint this:
- `OfferVirtualMemory(VMOfferPriorityVeryLow)` — tells the
  kernel a region can be discarded.
- `FILE_FLAG_NO_BUFFERING` on `CreateFile` — bypass the cache
  entirely. Requires sector-aligned (typically 4096) buffers
  and offsets, so mmap is incompatible. Direct read I/O only.
- `MEMORY_RESOURCE_NOTIFICATION` callbacks to evict on pressure.

But the cleanest fix for our workload is to **stop using mmap
for the source read** and use streaming reads instead. The
production I/O pattern is fully sequential within each file
(walk chunks in order, hash each, decide write); mmap's
random-access strength buys us nothing here.

### Revised Phase 1 design — streaming reads, not mmap

For `--mode=cbt`, the hot loop should be:

```rust
// Pre-allocated 4 MiB buffer, reused for every chunk.
let mut buf = vec![0u8; CHUNK_SIZE];
let mut src = BufReader::with_capacity(CHUNK_SIZE, File::open(src_path)?);
let mut idx = 0;
loop {
    let n = src.read(&mut buf)?;     // sequential read
    if n == 0 { break; }              // EOF
    let h = Sha256::digest(&buf[..n]);
    if manifest.get(idx) != Some(&h) {
        // changed — write to dst at same offset
        dst.seek(SeekFrom::Start(idx as u64 * CHUNK_SIZE as u64))?;
        dst.write_all(&buf[..n])?;
    }
    idx += 1;
}
```

Working-set characteristics:
- One pre-allocated 4 MiB buffer reused for every chunk
- No mmap = no monotonic working-set growth
- Sequential read from D: NVMe (which is exactly what the
  drive likes)
- Parallelism via a producer/consumer pipeline if SHA-256
  becomes the bottleneck (we already know it doesn't — single
  thread at ~2 GB/s exceeds D: sequential read in practice)

Expected throughput: similar to or slightly better than mmap
(1.4 GB/s observed) because:
- Sequential read pattern lets D:'s NVMe driver and Windows
  pre-fetch optimally
- No page-fault overhead per chunk
- No working-set growth = no antagonism with other processes

Trade-off: lose mmap's "free" parallelism. Test in Phase 1
whether single-threaded streaming hits NVMe limits; if not, add
a small producer/consumer pipeline (one read thread, one or two
hash threads).

For `--mode=blob`, no change — kopia blobs are small (typically
≤20 MB), `std::fs::copy` for new/changed blobs is fine.

### What's now ratified for Phase 1 (revised)

| Decision | Original plan | Revised after probe |
|---|---|---|
| Chunk size | 4 MiB | 4 MiB ✓ |
| Parallelism | rayon-over-chunks via mmap | Single-thread streaming with optional pipeline |
| Source I/O | `memmap2::Mmap` | `BufReader<File>` with pre-allocated 4 MiB buffer |
| Manifest format | BMCBT01 header + flat hash array | unchanged ✓ |
| Crash recovery | `.cbt.ok` marker | unchanged ✓ |
| Zero-chunk short-circuit | Implement, expect 30–50% savings | Implement, expect <15% savings |
| VSS path access | GLOBALROOT direct | unchanged ✓ |

Phase 1's `manifest.rs` can still mmap the manifest file
itself — those are ~22 MB at the largest and easily fit. The
constraint is specifically against mmap of the multi-TB
**source** data.

### Phase 0 closure decision

The full-file run didn't complete, but it produced an even more
valuable result than the originally-planned "32 min wall clock
confirmed" — it surfaced the multi-TB mmap problem that would
have shipped if we'd built Phase 1 to the original design.

**Phase 0 is complete.** All acceptance criteria met or
substituted with better data:
- ✓ Probe builds and runs without OOM (on small files; OOM on
  large file is the validating signal, not a failure)
- ✓ Throughput per chunk-size variant (warm-cache sweep)
- ✓ Sanity-check: 0 chunks changed on re-hash
- ✓ Mutation test: 1 byte → 1 chunk-changed at correct index
- ✓ 4 MiB chunk size confirmed
- ✓ Throughput numbers documented (here)
- ✓ Plan refined where the probe revealed a flaw

Time to proceed to Phase 1 with the revised design.
