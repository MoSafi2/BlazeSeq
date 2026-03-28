# BED Parser Enhancement Plan

## Current State: BlazeSeq BED Implementation

### Files
- `blazeseq/bed/parser.mojo` — streaming parser (~502 lines)
- `blazeseq/bed/record.mojo` — `BedView`, `BedRecord`, `Strand`, `ItemRgb` (~429 lines)
- `blazeseq/bed/__init__.mojo` — public exports
- `tests/bed/test_bed_parser_correctness.mojo` — correctness tests

### What Works Well
- Zero-copy `BedView` / owned `BedRecord` dual API
- Full BED3–9 and BED12 support
- Rich error reporting via `ParseContext` (line, column, file offset)
- Format-local `BedErrorCode` enum keeping error paths allocation-free
- Strict block geometry validation for BED12
- 1-based coordinate exposure via `Position`/`Interval` with correct 0-based storage
- Generic over any `Reader` (file, memory, gzip, etc.)

### Current Limitations
| Area | Gap |
|---|---|
| Extra fields | No support for columns beyond field 12 (custom/BED12+ columns) |
| Track/browser lines | Lines starting with `track` or `browser` crash or are skipped incorrectly |
| BED10 / BED11 | Explicitly rejected; no documented rationale |
| Strand semantics | `Unknown` (`.`) conflated with missing strand; noodles separates absent vs. explicit-dot |
| Score type | Stored as `Int` (platform-width); spec mandates 0–1000 range, `UInt16` is sufficient |
| Writer | No dedicated `BedWriter` type; only `Writable` on `BedRecord` |
| Async / parallel I/O | No batch / async read path |
| Block overlap validation | Blocks are not checked for overlaps with each other |

---

## Reference: Noodles BED Implementation (Rust)

### Design Choices Worth Adopting
| Feature | Noodles Approach | Relevance for BlazeSeq |
|---|---|---|
| Const-generic record type | `Record<const N: usize>` selects BED variant at compile time | Mojo also supports parameterized types; could eliminate `num_fields` runtime switch |
| `other_fields` bucket | `OtherFields` stores arbitrary extra columns as raw bytes | Needed for BigBed-compatible custom tracks and multi-tool pipelines |
| `RecordBuf` vs `Record` | Borrowed view vs. owned buffer—same pattern as BlazeSeq `BedView`/`BedRecord` | Already aligned; no change needed |
| Strand: only `Forward`/`Reverse` | No `Unknown` variant; missing strand = `None` | Cleaner semantics; see Enhancement 3 |
| Score as `u16` | Matches spec range (0–1000) | Tighter type; prevents silent overflow |
| Dedicated `Writer<N, W>` | Symmetric with `Reader` | BlazeSeq should add `BedWriter` |

### What Noodles Does Not Have (BlazeSeq advantage)
- Zero-alloc view iterator (`views()`)
- Rich `ParseContext` error messages with line/column
- Block geometry validation
- Automatic gzip/bgzf reader plugging (generic `R: Reader`)
- UCSC track/browser line skip handling (proposed below)

---

## Proposed Enhancements

### 1. Extra / Custom Fields (`other_fields`)
**Priority: High**

Many real-world BED files carry extra columns (e.g., p-value, fold-change, ENCODE signal columns). Without this, BlazeSeq silently drops them on read and cannot round-trip such files.

**Changes:**
- Add `_other_fields: List[Span[Byte, O]]` to `BedView` and `List[BString]` to `BedRecord`
- Accumulate any columns after field 12 into this list during parsing
- Expose via `other_fields()` accessor returning a slice of raw spans / strings
- Update `write_to()` to emit extra fields tab-delimited after standard fields

**Validation:** None required—extra fields are opaque bytes.

---

### 2. Track and Browser Line Handling
**Priority: High**

UCSC-format BED files commonly begin with `track name=... description=...` and `browser position chr1:1-1000` header lines. The current `BedLinePolicy` only skips `#` comments and blank lines. A `track` or `browser` line fed to the field parser will either raise `FIELD_COUNT` or misparse as a record.

**Changes:**
- Extend `BedLinePolicy.classify()` to recognise lines whose first token is literally `track` or `browser` and return `Skip`
- Optionally: store the most-recently-seen `track` line as `parser.track_line -> Optional[String]` for downstream consumers
- Add test data with UCSC-style headers

---

### 3. Strand Semantics — Separate `None` from `Unknown`
**Priority: Medium**

Currently `Strand.Unknown` maps to the `.` character, which in UCSC's own spec means "strand is not applicable / unknown". But the *absence* of the strand field (BED5 and below) also results in no `Strand`. These two states are currently indistinguishable to callers.

**Changes:**
- Keep `Strand` as `Plus | Minus | Unknown` (`.` in field 6 means the feature has no strand preference)
- In `BedView`/`BedRecord`, make `strand` field `Optional[Strand]` where `None` means the field was absent (BED5 or fewer) and `Unknown` means the field was `.`
- Update `_parse_strand()` accordingly

---

### 4. Score Type — `UInt16` instead of `Int`
**Priority: Low**

The BED spec constrains score to [0, 1000]. Using platform-width `Int` wastes 6 bytes per record in a packed context. Noodles uses `u16`.

**Changes:**
- Change `score: Int` → `score: UInt16` in `BedView` and `BedRecord`
- Update `_parse_score()` return type
- Retain the [0, 1000] range check (SCORE_RANGE error code)

---

### 5. Dedicated `BedWriter` Type
**Priority: Medium**

BlazeSeq has `BedRecord.write_to()` for single-record serialisation, but no `BedWriter` type analogous to `BedParser`. This means:
- No buffered / bulk writing
- No symmetric Reader ↔ Writer API contract

**Changes:**
- Add `blazeseq/bed/writer.mojo`
- `BedWriter[W: Writer]` wraps a `W` and exposes:
  - `write_record(rec: BedRecord)` — writes one tab-delimited line
  - `write_view(view: BedView)` — zero-copy path
- Export from `blazeseq/bed/__init__.mojo`
- Add round-trip tests: parse → write → re-parse, assert equality

---

### 6. Block Overlap Validation (BED12)
**Priority: Low**

The current validator checks:
- `blockStarts[0] == 0`
- Last block ends at `chromEnd`
- `blockSizes` / `blockStarts` lengths match `blockCount`

It does **not** check that blocks are non-overlapping and sorted. Overlapping blocks are illegal per spec but can arise from buggy upstream tools.

**Changes:**
- In `_parse_bed_required()`, after reading all blocks, iterate pairs `(blockStarts[i] + blockSizes[i]) <= blockStarts[i+1]`
- Raise `BLOCK_INVALID` with message "BED: blocks must be non-overlapping and sorted"

---

### 7. BED10 / BED11 — Document or Support
**Priority: Low**

BED10 and BED11 are rejected with `FIELD_COUNT`. These are rarely produced but the UCSC spec does not forbid them—they simply have no additional semantic meaning over BED9. The rejection is undocumented.

**Options (choose one):**
- **A — Accept silently**: treat 10- and 11-column files as BED9 (ignore extra standard fields, store in `other_fields`)
- **B — Document clearly**: add a comment in `_parse_bed_required()` and the public docs explaining the spec rationale
- **Recommended: A**, since it falls out naturally once `other_fields` (Enhancement 1) is implemented

---

## Implementation Order

| # | Enhancement | Effort | Impact |
|---|---|---|---|
| 2 | Track/browser line skip | Small | High — many real files break today |
| 1 | Extra fields (`other_fields`) | Medium | High — round-trip fidelity |
| 5 | `BedWriter` | Medium | Medium — API completeness |
| 3 | Strand `None` vs `Unknown` | Small | Medium — semantic correctness |
| 4 | Score `UInt16` | Trivial | Low — type hygiene |
| 6 | Block overlap check | Small | Low — edge case hardening |
| 7 | BED10/11 handling | Trivial | Low — falls out from #1 |
