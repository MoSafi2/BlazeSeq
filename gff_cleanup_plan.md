# GFF3 / GTF / BED Code Cleanup Plan

Senior-engineer review of `blazeseq/gff/`, `blazeseq/gtf/`, and `blazeseq/bed/`.
Items are grouped by category and ordered by impact within each group.

---

## Category A — Performance (hot path)

### A1. `_parse_uint64_from_span` triplicated across three parsers

**Location:**
- `gff/parser.mojo:220-232` — returns `Gff3ErrorCode`
- `gtf/parser.mojo:110-122` — returns `GtfErrorCode`
- `bed/parser.mojo:88-98` — returns `BedErrorCode`

The three implementations are byte-for-byte identical except for the error code type returned. Every change to integer parsing (e.g. overflow guard) must be made three times.

**Fix:** Extract the core loop into a single function in `blazeseq/utils.mojo` that fills a `UInt64` by reference and returns a tri-state: OK / empty / invalid. Each parser's local wrapper translates the tri-state into its own error code type. No callers change.

---

### A2. `_parse_score_span` duplicated in GFF3 and GTF

**Location:**
- `gff/parser.mojo:235-241`
- `gtf/parser.mojo:125-131`

The two functions are identical: check empty, check single `.`, call `atof`. Score parsing is format-agnostic.

**Fix:** Move to `blazeseq/utils.mojo` as `parse_score_span`, or into `blazeseq/io/delimited.mojo` alongside the other field utilities. Both parsers import and call it directly.

---

### A3. `_parse_phase_span` duplicated in GFF3 and GTF

**Location:**
- `gff/parser.mojo:268-284` — returns `Gff3ErrorCode`
- `gtf/parser.mojo:155-171` — returns `GtfErrorCode`

Same logic: handle `.` as None, parse integer, reject > 2. The only difference is the error code type — same situation as A1.

**Fix:** Same pattern as A1: shared core function in `utils.mojo`, local wrappers translate the tri-state.

---

### A4. `percent_decode` builds a `String` byte-by-byte via `chr()` — O(n²)

**Location:** `gff/attributes.mojo:146-162`

The inner loop does `out += chr(Int(span[i]))` for every byte. In Mojo, string `+=` in a loop reallocates on every iteration, making this O(n²) in the length of the input. For a 1 KB attribute value this is ~500 redundant copies; for `##sequence-region` seqids with encoded characters it fires repeatedly per record.

**Fix:** Replace the accumulator with a `List[UInt8]`. Push bytes directly into the list (including decoded percent-sequences), then construct `BString` from the list in one shot at the end. This makes `percent_decode_to_bstring` also simpler — it can build the `List[UInt8]` directly without the intermediate `String`.

---

### A5. `_gtf_unescape_value` builds a `String` byte-by-byte via `chr()` — O(n²)

**Location:** `gtf/attributes.mojo:95-130`

Same problem as A4. For the common case (no backslash) the function calls `chr(Int(b))` on every byte, each of which allocates a one-character String. A 200-character attribute value triggers 200 string allocations.

**Fix:** Same approach as A4 — accumulate into `List[UInt8]`, construct `BString` once at the end.

**Note:** If the input contains no `%`-encoded characters (for `percent_decode`) or no `\` escapes (for `_gtf_unescape_value`), the common fast path should short-circuit: scan the span first; if no trigger byte is found, build `BString(span)` directly with zero additional allocation.

---

### A6. Attribute key lookups allocate a `String` per comparison

**Location:**
- `gff/attributes.mojo:57` — `self._pairs[i][0].to_string() == key` in `get()`
- `gff/attributes.mojo:67` — same in `get_all()`
- `gtf/attributes.mojo:54` — `self._extras[i][0].to_string() == key` in `get()`
- `gtf/attributes.mojo:68` — same in `get_all()`

Each iteration of the linear scan allocates a heap `String` from the stored `BString` key. For an attribute column with 10 pairs, `get("ID")` performs 10 allocations even when the key is not found.

**Fix:** Compare bytes directly. `BString` has `as_span()`. Compare `key.as_bytes()` (or the `String`'s underlying bytes) against `self._pairs[i][0].as_span()` byte-by-byte, with an early exit on length mismatch. No allocation needed.

---

### A7. `parse_gtf_attributes` allocates `String` to compare key against `"gene_id"` / `"transcript_id"`

**Location:** `gtf/attributes.mojo:214-218`

```mojo
var key_str = StringSlice(unsafe_from_utf8=key_span)
if String(key_str) == "gene_id":
```

This allocates a `String` for every attribute key on every record just to decide whether it is `gene_id` or `transcript_id`. These are the two most common keys.

**Fix:** Compare bytes in `key_span` directly. Check `len(key_span) == 7` and then compare the 7 bytes against the ASCII bytes of `"gene_id"`. Similarly for `"transcript_id"` (13 bytes). Zero allocation on the hot path.

---

### A8. `_parse_gff3_row` allocates `String` to compare feature type with `"CDS"`

**Location:** `gff/parser.mojo:321-323`

```mojo
var ftype_str = StringSlice(unsafe_from_utf8=ftype)
if String(ftype_str) == "CDS" and not phase:
```

Allocates a `String` on every GFF3 data row to enforce the CDS-requires-phase rule.

**Fix:** Inline byte comparison: `len(ftype) == 3 and ftype[0] == ord('C') and ftype[1] == ord('D') and ftype[2] == ord('S')`. The `_starts_with` helper already exists in the same file and could be extended or used directly.

---

### A9. `_parse_item_rgb` builds a `List[String]` for a three-element parse

**Location:** `bed/parser.mojo:139-173`

To parse `"255,128,0"` the function: allocates a `List[String]`, calls `StringSlice.strip()` on each element (allocation), calls `atol()` three times, then bounds-checks. Total: ~6 allocations for a 9-byte parse.

**Fix:** Parse the three integers directly from the byte span in one pass. Scan to the first comma, parse the integer; scan to the second comma, parse; parse the remainder. No list, no String allocations. Validate range inline.

---

## Category B — Dead Code and Correctness

### B1. `BedView.to_record()` has an unreachable `elif` branch for blocks without `block_count`

**Location:** `bed/record.mojo:253-255`

```mojo
elif self._block_sizes_span and self._block_starts_span:
    block_sizes = _parse_comma_sep_int64_list(...)
    block_starts = _parse_comma_sep_int64_list(...)
```

`_block_sizes_span` and `_block_starts_span` are set only when `n >= 12` in `_parse_bed_optional_fields` (`bed/parser.mojo:422-423`), and `block_count` is also set at the same time. A `BedView` can never have the spans set without `block_count`. This `elif` never executes.

**Fix:** Remove the branch. Add a comment explaining the invariant (spans only present when `block_count` is set).

---

### B2. All six iterator `__next__` methods still print-and-swallow parse errors

**Location:**
- `gff/parser.mojo:444-445` (`_Gff3ParserViewIter.__next__`)
- `gff/parser.mojo:474-476` (`_Gff3ParserRecordIter.__next__`)
- `gtf/parser.mojo:314-315` (`_GtfParserViewIter.__next__`)
- `gtf/parser.mojo:344-346` (`_GtfParserRecordIter.__next__`)
- `bed/parser.mojo:530-533` (`_BedParserViewIter.__next__`)
- `bed/parser.mojo:561-564` (`_BedParserRecordIter.__next__`)

All six have the same comment `# propagate parse errors to the caller` but then immediately raise `StopIteration` instead of re-raising the error. Parse errors are silently lost. This is already tracked in `gff_enhancment.md` (Issue 1) — it is called out here because it affects all three parsers, not just GFF3/GTF.

**Fix:** In the `else` branch (non-EOF error): `raise e`. Remove `print(msg)`.

---

### B3. `GtfAttributes.write_to` does not re-escape values — round-trip break

**Location:** `gtf/attributes.mojo:75-88`

Since Issue 5 introduced backslash-escape decoding in `parse_gtf_attributes`, a value like `it"s a test` (decoded from `it\"s a test`) is now stored unescaped. When `write_to` emits it, it writes `gene_id "it"s a test"` — syntactically invalid GTF.

**Fix:** Add a `_gtf_escape_value(s: String) -> String` function (the inverse of `_gtf_unescape_value`) that re-escapes `"` as `\"` and `\` as `\\`. Call it in `write_to` for every attribute value. Apply the same O(n) approach: scan for characters that need escaping; if none, write the raw string; otherwise build the escaped version.

---

### B4. `GtfAttributes.__len__` always counts `gene_id` and `transcript_id` as present

**Location:** `gtf/attributes.mojo:72-73`

```mojo
def __len__(self) -> Int:
    return 2 + len(self._extras)
```

This always returns at least 2, even when both mandatory fields are empty strings (i.e., absent from the GTF file). Callers using `len(attrs) == 0` to check "no attributes" will get a wrong answer.

**Fix:** Count only non-empty mandatory fields. Change to count `gene_id` as 1 only if `len(gene_id) > 0`, same for `transcript_id`. Or, since `__len__` represents "number of attribute pairs," document clearly that it always includes mandatory fields regardless of whether they were present in the source. Pick one semantic and enforce it.

---

## Category C — API and Design

### C1. `Gff3Parser.next_view()` reaches into `self._rows.lines.next_line()` — leaky abstraction

**Location:** `gff/parser.mojo:378`

```mojo
var line = self._rows.lines.next_line()
```

`GtfParser.next_view()` (`gtf/parser.mojo:260`) and `BedParser.next_view()` (`bed/parser.mojo:460`) both call `self._rows.next_view()` — the public method on `DelimitedReader`. `Gff3Parser` bypasses this and accesses the internal `lines` field directly. This exposes the `DelimitedReader` internals and skips any logic in `DelimitedReader.next_view()`.

The reason GFF3 does this is that it needs the raw line to inspect directives before splitting on tabs. The proper fix is to give `DelimitedReader` a `next_line()` method that returns the raw line without splitting, while keeping `next_view()` for split access. GFF3 calls `next_line()`, GTF and BED call `next_view()`.

---

### C2. `ParseContext(0, 0, 0)` used for directive parsing in `Gff3Parser.next_view()`

**Location:** `gff/parser.mojo:388`

When a `##gff-version` or `##sequence-region` directive has a parse error, the error is raised with `ParseContext(0, 0, 0)` — zero file offset, zero line number, zero column. The actual line number is tracked in `self._rows` and accessible via `self._parse_context()`.

**Fix:** Replace `var ctx = ParseContext(0, 0, 0)` with `var ctx = self._parse_context()`. One-line change, meaningful error messages for directive failures.

---

### C3. `_parse_uint64_from_bstring` in `gff/record.mojo` duplicates `_parse_uint64_from_span`

**Location:** `gff/record.mojo:287-298`

Used only in `parse_target_attribute`, this function re-implements the same decimal integer loop that already exists in `gff/parser.mojo:220-232`. `BString` has `as_span()`, so the same `_parse_uint64_from_span` could be called. After A1 extracts the shared core to `utils.mojo`, this function should be deleted and replaced with the shared version.

---

### C4. `parse_target_attribute` collects all tokens into `List[BString]` before accessing them

**Location:** `gff/record.mojo:306-320`

The function tokenizes by splitting on spaces into a `List[BString]`, then accesses `tokens[0]`, `tokens[1]`, `tokens[2]`, `tokens[3]`. This means up to 4 `BString` allocations (each copying span bytes) and a list allocation just to hold 4 elements that are immediately consumed.

**Fix:** Parse tokens sequentially in a single pass without the intermediate list. Track the start of each token, find its end, parse it immediately, and advance. This halves the allocations and removes the list.

---

### C5. `sequence_regions()` returns a defensive copy of the full list

**Location:** `gff/parser.mojo:363-366`

```mojo
def sequence_regions(ref self) -> List[SequenceRegion]:
    return self._seq_regions.copy()
```

For a file with many `##sequence-region` directives, this copies the entire list on every call. Most callers just iterate or read without mutating.

**Fix:** Provide a `ref` accessor: `def sequence_regions(ref self) -> ref [origin_of(self)] List[SequenceRegion]`. The existing copy-returning version can be kept as `copy_sequence_regions()` if callers genuinely need ownership. This is a minor API addition, not a breaking change.

---

### C6. `_BedRequiredParsed` and `_BedOptionalFields` are one-use intermediate structs

**Location:** `bed/parser.mojo:181-240`

Both structs exist solely to return multiple values from `_parse_bed_required` and `_parse_bed_optional_fields` back to `next_view`. They are never used anywhere else. The extra struct definitions, initialisers, and field copies add ~60 lines of code and obscure the flow.

Mojo supports multiple return values via tuples. Alternatively, `_parse_bed_required` and `_parse_bed_optional_fields` can be inlined into a single `_parse_bed_row` function that returns `BedView` directly — exactly the pattern used in `_parse_gff3_row` and `_parse_gtf_row`. This would reduce `BedParser.next_view()` to the same clean 4-line shape the other parsers use and eliminate both intermediate structs.

---

### C7. `_starts_with` defined only in `gff/parser.mojo`; re-implemented manually in `BedLinePolicy`

**Location:**
- Defined: `gff/parser.mojo:91-101`
- Duplicated manually: `bed/parser.mojo:272-292` (manual byte-by-byte for "track" and "browser")

`BedLinePolicy.classify` does the same byte-by-byte prefix check that `_starts_with` provides, just inline without calling the helper. When the helper is eventually moved to `utils.mojo` (see A1), `BedLinePolicy` should use it too.

---

## Category D — Minor / Style

### D1. Missing `@always_inline` on `BedView` accessor methods

**Location:** `bed/record.mojo`

`Gff3View` (`gff/record.mojo:124-138`) and `GtfView` (`gtf/record.mojo:98-113`) mark all string-returning accessors `@always_inline`. `BedView` marks only `chrom()` (`bed/record.mojo:171`) but not `name()` (line 212), `item_rgb()` (line 217), or `other_fields()` (line 222). The inconsistency is minor but `name()` is a trivially inlineable optional-unwrap.

---

### D2. `ItemRgb.write_to` makes 5 separate `writer.write()` calls

**Location:** `bed/record.mojo:78-83`

```mojo
writer.write(String(self.r))
writer.write(",")
writer.write(String(self.g))
writer.write(",")
writer.write(String(self.b))
```

Can be collapsed into one write using string interpolation: `writer.write(t"{self.r},{self.g},{self.b}")`. Matches the style already used in `_write_item_rgb_field` at line 474.

---

### D3. `_strand_to_char` in `bed/record.mojo` returns a heap-allocated `String` for a single character

**Location:** `bed/record.mojo:301-309`

Called only from `_write_strand_field`, which immediately passes the return value to `writer.write(t"\t{c}")`. Returns a new `String` on the heap for `"+"`, `"-"`, or `"."`. Could be replaced by writing directly into the writer from `_write_strand_field`, eliminating the helper entirely and the allocation.

---

### D4. `GtfRecord.write_to` and `Gff3Record.write_to` allocate `String` for integer fields

**Location:**
- `gff/record.mojo:228` — `writer.write(String(self.Start))`
- `gtf/record.mojo:201` — `writer.write(String(self.Start))`

`UInt64` is `Writable` in Mojo, so `writer.write(self.Start)` should work directly without the `String()` wrapper. Same for `self.End`, `self.Phase.value()`, and `self.Score.value()`. Remove the redundant `String()` casts in both `write_to` methods.

---

## Summary Table

| # | Category | Location | Impact | API Break? |
|---|----------|----------|--------|:----------:|
| A1 | Perf | `gff/gtf/bed parser.mojo` | High — shared hot-path function | No |
| A2 | Perf | `gff/gtf parser.mojo` | Medium | No |
| A3 | Perf | `gff/gtf parser.mojo` | Medium | No |
| A4 | Perf | `gff/attributes.mojo` | High — O(n²) → O(n) per attribute column | No |
| A5 | Perf | `gtf/attributes.mojo` | High — O(n²) → O(n) per attribute column | No |
| A6 | Perf | `gff/gtf attributes.mojo` | Medium — allocation per key lookup | No |
| A7 | Perf | `gtf/attributes.mojo` | Medium — allocation per record on hot path | No |
| A8 | Perf | `gff/parser.mojo` | Low — one allocation per GFF3 row | No |
| A9 | Perf | `bed/parser.mojo` | Low — ~6 allocs → 0 for RGB parse | No |
| B1 | Dead code | `bed/record.mojo:253-255` | Low — remove dead branch | No |
| B2 | Correctness | All 6 iterator `__next__` | High — errors are silently lost | No |
| B3 | Correctness | `gtf/attributes.mojo:75-88` | Medium — round-trip break for escaped values | No |
| B4 | Correctness | `gtf/attributes.mojo:72-73` | Low — misleading `__len__` | No |
| C1 | Design | `gff/parser.mojo:378` | Medium — leaky abstraction | No |
| C2 | Design | `gff/parser.mojo:388` | Low — zero ParseContext for directives | No |
| C3 | Design | `gff/record.mojo:287-298` | Low — delete after A1 | No |
| C4 | Design | `gff/record.mojo:306-320` | Low — 4 allocs → 1 in `parse_target_attribute` | No |
| C5 | Design | `gff/parser.mojo:363-366` | Low — unnecessary copy | Additive |
| C6 | Design | `bed/parser.mojo:181-240` | Medium — remove two dead intermediate structs | No |
| C7 | Design | `bed/parser.mojo:272-292` | Low — consolidate `_starts_with` | No |
| D1 | Style | `bed/record.mojo` | Low — inline consistency | No |
| D2 | Style | `bed/record.mojo:78-83` | Low | No |
| D3 | Style | `bed/record.mojo:301-309` | Low — remove helper + allocation | No |
| D4 | Style | `gff/gtf record.mojo` | Low — remove redundant String() casts | No |

---

## Suggested Implementation Order

**Phase 1 — Correctness (do first; nothing else should land before these)**
- B2 (iterator error swallowing) — prerequisite for all testing
- B3 (GTF write_to escaping)
- B4 (GtfAttributes `__len__`)

**Phase 2 — High-impact perf (independent, can be parallelised)**
- A4 + A5 (O(n²) → O(n) string building in decode/unescape)
- A1 + A2 + A3 (shared parsing utilities, enables C3 deletion)

**Phase 3 — Medium perf and design cleanup**
- A6 + A7 + A8 (eliminate allocation-per-comparison on hot path)
- C6 (remove intermediate BED structs)
- C2 (ParseContext fix — trivial one-liner)

**Phase 4 — Minor / low-risk**
- A9, B1, C1, C4, C5, C7, D1–D4
