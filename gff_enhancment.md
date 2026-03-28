# GFF3/GTF Parsing Enhancements — Implementation Plan

Addresses deviations found by comparing BlazeSeq against [noodles](https://github.com/zaeleus/noodles) (`noodles-gff` / `noodles-gtf`).

---

## Summary Table


| #   | Issue                                                                  | Severity | Primary Files                                          | API Break?  |
| --- | ---------------------------------------------------------------------- | -------- | ------------------------------------------------------ | ----------- |
|     |                                                                        |          |                                                        |             |
| 2   | `start=0` / `end=0` accepted; spec requires ≥ 1                        | Medium   | `gff/parser.mojo:272-278`, `gtf/parser.mojo:162-168`   | No          |
| 3   | GTF unquoted attribute values silently dropped                         | Medium   | `gtf/attributes.mojo:116-128`                          | No          |
| 4   | GTF duplicate-key attributes partially lost                            | Medium   | `gtf/attributes.mojo:30,45-54`, `gtf/record.mojo:186`  | Additive    |
| 5   | GTF backslash escapes in values not decoded                            | Low–Med  | `gtf/attributes.mojo:119-128`                          | No          |
| 6   | `##gff-version` checked by raw byte offset, not parsed                 | Low      | `gff/parser.mojo:100-104`                              | No          |
| 7   | `.` in GFF3 attribute column not positively recognized                 | Low      | `gff/attributes.mojo:176-180`                          | No          |
| 8   | seqid percent-decoding not applied                                     | Low      | `gff/record.mojo:156`, `gff/parser.mojo:123`           | Behavioural |
| 9   | `gene_id`/`transcript_id` absence defaults to empty string, no warning | Low      | `gtf/attributes.mojo:85-87`, `gtf/parser.mojo:199-226` | Additive    |
| 10  | `###` directive silently discarded                                     | Info     | `gff/parser.mojo:170-172`                              | No          |


**Scope:** Issues  2 affect both GFF3 and GTF. Issues 3–5, 9 affect GTF only. Issues 6–8, 10 affect GFF3 only.

---

### New error codes

None. Existing `raise_parse_error` infrastructure in `blazeseq/errors.mojo` is sufficient.

### Tests to add (`tests/gff/test_gff_parser_correctness.mojo`)

- `test_gff3_iter_propagates_parse_error` — feed a GFF3 line with fewer than 9 tab-separated fields via `MemoryReader`; wrap the for-loop in a try/except; assert the raised error message contains the field-count error string rather than silently stopping.
- `test_gtf_iter_propagates_parse_error` — same for GTF.
- `test_gff3_iter_stops_cleanly_at_eof` — regression: a well-formed single-line GFF3 file produces exactly one record and stops without error.

---

## Issue 2 — `start=0` / `end=0` Accepted

### Problem

`_parse_uint64_from_span` has no lower-bound check. GFF3 and GTF both require coordinates ≥ 1 (1-based spec). A record with `start=0` passes integer parsing and may trigger a confusing `start > end` error downstream rather than a clear coordinate error.

**BlazeSeq locations:**

- `blazeseq/gff/parser.mojo:272-279` — `_parse_gff3_row`, start/end parsing + existing `start > end` guard
- `blazeseq/gtf/parser.mojo:162-170` — `_parse_gtf_row`, same

**noodles equivalent:** `noodles-gff/src/record/fields/start.rs` — `Start` is a newtype over `Position` which is `NonZeroUsize`; construction from zero is rejected at the type level. Same for `noodles-gtf`.

### Fix

After parsing `start` and again after parsing `end` in both `_parse_gff3_row` and `_parse_gtf_row`, add a guard: if the value is 0, call `raise_parse_error(ctx, <COORD_ZERO message>)`. Place both zero checks before the existing `start > end` check so the zero-specific message fires first.

Add new error code constants:

- `Gff3ErrorCode.COORD_ZERO = Self(8)` — message `"GFF3: start/end coordinate must be >= 1 (1-based)"` — in `blazeseq/gff/parser.mojo`
- `GtfErrorCode.COORD_ZERO = Self(6)` — message `"GTF: start/end coordinate must be >= 1 (1-based)"` — in `blazeseq/gtf/parser.mojo`

### Tests to add

- `test_gff3_rejects_start_zero` — input line with `start=0`; assert parse error referencing `">= 1"`.
- `test_gff3_rejects_end_zero` — input with `end=0`; assert zero-coordinate error fires before `start > end`.
- `test_gtf_rejects_start_zero` — GTF equivalent.
- `test_gff3_accepts_start_one` — regression: `start=1` parses cleanly.

---

## Issue 3 — GTF Unquoted Attribute Values Silently Dropped

### Problem

`parse_gtf_attributes` (`blazeseq/gtf/attributes.mojo:116`) checks whether the character after the space separator is `"`. If it is not, the entire attribute pair is silently discarded. Real GTF files (and all AGAT fixtures) occasionally use unquoted values such as `exon_number 3`.

**BlazeSeq location:** `blazeseq/gtf/attributes.mojo:116-128` — the `if i < part_len and part[i] == ord('"')` gate with no `else` branch.

**noodles equivalent:** `noodles-gtf/src/record/attributes/field/value.rs` — `Value::parse()` accepts both quoted and unquoted tokens.

### Fix

Add an `else` branch after the quoted-value path. In the unquoted path, take the remaining bytes starting at position `i`, trim any trailing whitespace (`\r`, `\n`, space, tab), and treat the trimmed slice as the raw value. Record it into `gene_id`, `transcript_id`, or `_extras` using the same assignment logic as the quoted path.

No new error codes — unquoted values are accepted, not rejected.

### Tests to add

- `test_gtf_unquoted_attribute_value` — input `exon_number 3` (unquoted integer); assert `get_attribute("exon_number")` returns `"3"`.
- `test_gtf_unquoted_gene_id` — input `gene_id ENSG001` (unquoted); assert `Attributes.gene_id.to_string() == "ENSG001"`.
- `test_gtf_mixed_quoted_and_unquoted` — mix of quoted and unquoted in the same attribute column; assert all attributes resolve.

---

## Issue 4 — GTF Duplicate-Key Attributes Partially Lost

### Problem

`GtfAttributes._extras` (`blazeseq/gtf/attributes.mojo:30`) is `List[Tuple[BString, BString]]`. When the same key appears twice, two entries are appended — but `get()` (`gtf/attributes.mojo:45-54`) returns only the first match. The second value is unreachable.

**BlazeSeq locations:**

- `blazeseq/gtf/attributes.mojo:30` — `_extras` field
- `blazeseq/gtf/attributes.mojo:45-54` — `get()` method
- `blazeseq/gtf/record.mojo:186` — `get_attribute()` delegation

**noodles equivalent:** `noodles-gtf/src/record/attributes.rs` — `Attributes` is `Vec<Field>`; `iter()` exposes all pairs including duplicates; callers filter by key over the full iterator.

### Fix

**Part A — `get_all()` on `GtfAttributes`** (`gtf/attributes.mojo`):

Add a `get_all(key: String) -> List[BString]` method modelled on the existing `Gff3Attributes.get_all()` (`gff/attributes.mojo:63`):

- If `key == "gene_id"` return a single-element list of `self.gene_id`.
- If `key == "transcript_id"` return a single-element list of `self.transcript_id`.
- Otherwise, iterate `_extras` and collect all values whose key matches; return in encounter order.

**Part B — `get_all_attributes()` on `GtfRecord`** (`gtf/record.mojo`):

Add `get_all_attributes(ref self, key: String) -> List[BString]` delegating to `self.Attributes.get_all(key)`, mirroring `Gff3Record.get_all_attributes()` (`gff/record.mojo:215`).

`get()` remains unchanged — it still returns the first match — preserving backward compatibility.

### API note

Additive only. Flag `get_all_attributes()` in the changelog for callers who were using `get_attribute()` and silently receiving only the first value.

### Tests to add

- `test_gtf_duplicate_key_get_all` — input `tag "v1"; tag "v2"`; assert `get_all_attributes("tag")` returns length-2 list `["v1", "v2"]`.
- `test_gtf_get_returns_first_value` — same input; assert `get_attribute("tag")` still returns `"v1"` (backward compatibility).
- `test_gtf_get_all_mandatory_ids` — assert `get_all_attributes("gene_id")` returns a single-element list matching `Attributes.gene_id`.

---

## Issue 5 — GTF Backslash Escapes Not Decoded

### Problem

Value bytes extracted from between quotes are stored verbatim (`blazeseq/gtf/attributes.mojo:119-121`). A value such as `"it\"s a test"` is stored as `it\"s a test` rather than `it"s a test`.

**BlazeSeq location:** `blazeseq/gtf/attributes.mojo:119-128` — value extraction loop.

**noodles equivalent:** `noodles-gtf/src/record/attributes/field/value.rs` — the parser applies `str::replace` (or equivalent) for `\"→"`, `\\→\`, and `\n→newline` sequences.

### Fix

Add a private helper function `_gtf_unescape_value(span: Span[UInt8, _]) -> BString` to `gtf/attributes.mojo`. It processes bytes sequentially:

- On `\` (ASCII 92), peek at the next byte:
  - `"` (34) → emit `"` (34)
  - `\` (92) → emit `\` (92)
  - `n` (110) → emit newline (10)
  - `t` (116) → emit tab (9)
  - `r` (114) → emit carriage return (13)
  - Any other byte → emit both `\` and the following byte literally (lenient fallback)
  - Trailing `\` (last byte) → emit `\` literally
- All other bytes → emit as-is.

After extracting the value span (in both the quoted path and the unquoted path added by Issue 3), call `_gtf_unescape_value(value_span)` instead of `BString(value_span)`. Apply at all three recording sites: `gene_id`, `transcript_id`, and `_extras.append`.

### Tests to add

- `test_gtf_backslash_quote_in_value` — `note "it\"s a test"`; assert value is `it"s a test`.
- `test_gtf_backslash_newline_in_value` — `gene_id "ENSG\\n001"`; assert byte 4 is `\n` (ASCII 10).
- `test_gtf_backslash_tab_in_value` — `note "col1\\tcol2"`; assert value contains ASCII 9.
- `test_gtf_no_backslash_unaffected` — plain value without backslashes is unchanged (regression).

---

## Issue 6 — `##gff-version` Checked by Raw Byte Offset

### Problem

`_check_gff_version` (`blazeseq/gff/parser.mojo:100-104`) uses a hardcoded byte offset: `line[14] != ord('3')`. This is fragile — it fails on lines shorter than 15 bytes, does not handle sub-versions like `3.1.26`, and does not trim trailing whitespace.

**BlazeSeq location:** `blazeseq/gff/parser.mojo:100-104`.

**noodles equivalent:** `noodles-gff/src/directive/gff_version.rs` — `GffVersion::parse()` splits the value on `.` and parses each component as `u32`.

### Fix

Replace the function body with a token-based parse:

1. Skip the `"##gff-version"` prefix (13 bytes already consumed by the caller's `_starts_with` check).
2. Skip any space or tab bytes.
3. If no non-whitespace bytes remain, raise `Gff3ErrorCode.VERSION`.
4. Collect bytes until the next whitespace character or end of span — this is the version token.
5. The token's first byte must be `'3'` (ASCII 51). If not, raise `Gff3ErrorCode.VERSION`.
6. If the token has a second byte it must be `'.'` or end-of-token (reject `"31"` as invalid).

Correctly handles `"3"`, `"3.1"`, `"3.1.26"`. Rejects `"2"`, `"1.0"`, `""`.

`Gff3ErrorCode.VERSION` already exists with message `"GFF3: ##gff-version must be 3.x"` — no new code needed.

### Tests to add

- `test_gff3_version_3_accepted` — `"##gff-version 3\n"` followed by a valid data line; assert the record parses.
- `test_gff3_version_3_1_accepted` — `"##gff-version 3.1\n"`.
- `test_gff3_version_3_1_26_accepted` — `"##gff-version 3.1.26\n"`.
- `test_gff3_version_2_rejected` — `"##gff-version 2\n"`; assert error message contains `"3.x"`.
- `test_gff3_version_no_number_rejected` — `"##gff-version\n"` (no digit); assert parse error.
- `test_gff3_version_trailing_whitespace` — `"##gff-version 3   \n"`; assert accepted.

---

## Issue 7 — `.` in GFF3 Attribute Column Not Positively Recognized

### Problem

When column 9 is a literal `.` (meaning "no attributes" per spec), `parse_gff3_attributes` (`blazeseq/gff/attributes.mojo:176-218`) runs the full parsing loop, finds no `=` sign, silently skips the token, and returns an empty `Gff3Attributes`. The correct result is produced by accident.

**BlazeSeq location:** `blazeseq/gff/attributes.mojo:176-180` — early-exit guards.

**noodles equivalent:** `noodles-gff/src/record/fields/attributes.rs` — `Attributes::is_missing()` returns `true` when column 9 is a single `b"."` byte; parsing returns `Attributes::Missing`.

### Fix

Add an early-exit guard at the top of `parse_gff3_attributes`, after the existing `len(span) == 0` check: if `len(span) == 1` and `span[0] == ord('.')`, return `Gff3Attributes()` immediately. This makes the intent explicit and avoids running the loop on a single `.` byte.

Verify that `DelimitedView.get_span(8)` for column 9 already has trailing newlines trimmed (consistent with how `.` is handled for score and phase). If trailing `\n`/`\r` are present, the guard should check `len(span) == 2 and span[0] == ord('.') and span[1] in (\n, \r)` as well. Inspect actual span content at this site before implementing.

### Tests to add

- `test_gff3_dot_attributes_column` — input `"chr1\t.\tgene\t1\t100\t.\t.\t.\t.\n"`; assert `len(rec.Attributes) == 0` and `rec.get_attribute("ID")` returns `None`.
- `test_gff3_empty_attributes_column` — regression: truly empty column 9 (end of line) also produces empty attributes.

---

## Issue 8 — seqid Percent-Decoding Not Applied

### Problem

`Gff3View.to_record()` (`blazeseq/gff/record.mojo:156`) stores seqid as `BString(self._seqid)` — raw bytes. The GFF3 spec requires seqid to be URL-encoded when it contains reserved characters. `percent_decode_to_bstring` already exists in `gff/attributes.mojo:165` but is not applied to seqid.

**BlazeSeq locations:**

- `blazeseq/gff/record.mojo:156` — `Seqid=BString(self._seqid)` in `to_record()`
- `blazeseq/gff/parser.mojo:123` — `BString(rest[0:i])` in `_parse_sequence_region`

**noodles equivalent:** `noodles-gff/src/record/fields/reference_sequence_name.rs` — `ReferenceSequenceName` percent-decodes on construction using the `percent-encoding` crate.

### Fix

**Step 1:** Add `percent_decode_to_bstring` to the import from `blazeseq.gff.attributes` in `blazeseq/gff/record.mojo` (line 15–18 area).

**Step 2:** In `Gff3View.to_record()` (line 156), change `Seqid=BString(self._seqid)` to `Seqid=percent_decode_to_bstring(self._seqid)`.

**Step 3:** In `_parse_sequence_region` (`gff/parser.mojo:123`), change `var seqid = BString(rest[0:i])` to `var seqid = percent_decode_to_bstring(rest[0:i])`.

**Scope note:** Do NOT apply to GTF — the GTF2.2 spec does not define percent-encoding for any field.

`**Gff3View` note:** The raw `_seqid` span on `Gff3View` is intentionally left as-is (zero-copy). If callers need the decoded seqid from a view, consider adding a `decoded_seqid() -> String` method to `Gff3View` that calls `percent_decode` directly. This is optional.

### Changelog note

This is a behavioural change to the value returned by `Gff3Record.seqid()` for files with percent-encoded seqids. Flag in changelog.

### Tests to add

- `test_gff3_seqid_percent_decoded` — input seqid `chr1%2Fpatch`; after `to_record()`, assert `rec.seqid() == "chr1/patch"`.
- `test_gff3_seqid_no_percent_unchanged` — plain seqid `chr1` is unchanged.
- `test_gff3_sequence_region_seqid_decoded` — directive `##sequence-region chr1%2Fpatch 1 1000`; assert `parser.sequence_regions()[0].seqid.to_string() == "chr1/patch"`.
- Confirm existing `test_agat_decode_gff3urlescape_gene_synonym_percent_decoded` (in `test_agat_fixtures.mojo`) continues to pass, and extend it to also assert the seqid field if the fixture file contains an encoded seqid.

---

## Issue 9 — Missing `gene_id`/`transcript_id` Defaults to Empty String

### Problem

`parse_gtf_attributes` (`blazeseq/gtf/attributes.mojo:85-87`) initialises `gene_id` and `transcript_id` as empty `BString` before the parsing loop. If they are absent from the input, they remain empty with no warning. The GTF2.2 spec requires both in every non-comment feature line.

**BlazeSeq location:** `blazeseq/gtf/attributes.mojo:85-87` and `blazeseq/gtf/parser.mojo:199-226`.

**noodles equivalent:** `noodles-gtf/src/record/attributes.rs` — `gene_id()` and `transcript_id()` return `Option<&str>`; absence is `None` and is surfaced to the caller without a default.

### Fix

Implement optional strict-mode validation. Default behaviour (lenient) is unchanged.

**Part A — New error codes** (`gtf/parser.mojo`):

Add to `GtfErrorCode`:

- `MISSING_GENE_ID = Self(7)` — `"GTF: gene_id attribute is missing (required by GTF2.2)"`
- `MISSING_TRANSCRIPT_ID = Self(8)` — `"GTF: transcript_id attribute is missing (required by GTF2.2)"`

**Part B — `strict_mandatory_attrs` field on `GtfParser`** (`gtf/parser.mojo:199`):

Add a `_strict_mandatory_attrs: Bool` field to `GtfParser`, defaulting to `False`.

**Part C — Validation in `next_record()`** (`gtf/parser.mojo:225`):

After calling `self.next_view().to_record()`, and only when `self._strict_mandatory_attrs` is `True`, check emptiness of `rec.Attributes.gene_id` and `rec.Attributes.transcript_id` using the canonical emptiness check for `BString` (verify in `blazeseq/byte_string.mojo`). Raise `MISSING_GENE_ID` or `MISSING_TRANSCRIPT_ID` if empty.

**Part D — Constructor / builder**:

Provide a constructor overload or a `with_strict_mandatory_attrs()` factory method on `GtfParser` so callers can opt in without changing default behaviour.

### Tests to add

- `test_gtf_missing_gene_id_lenient` — input without `gene_id`; with default parser, assert record parses and `Attributes.gene_id.to_string() == ""`.
- `test_gtf_missing_gene_id_strict` — same input with strict parser; assert error message contains `"gene_id"` and `"missing"`.
- `test_gtf_missing_transcript_id_strict` — input without `transcript_id`; strict parser; assert error contains `"transcript_id"`.

---

## Issue 10 — `###` Directive Silently Discarded

### Problem

`Gff3LinePolicy.classify` (`blazeseq/gff/parser.mojo:170-172`) returns `LineAction.SKIP` for `###` lines. The GFF3 forward-reference flush boundary is silently ignored rather than being positively recognised.

**BlazeSeq location:** `blazeseq/gff/parser.mojo:170-172`.

**noodles equivalent:** `noodles-gff/src/reader/record/directive.rs` — `###` is parsed as `Directive::ForwardReferencesAreResolved` and yielded to the caller as a `LineBuf::Directive` variant. Callers that maintain a record graph can act on it.

### Fix

Change `###` classification from `LineAction.SKIP` to `LineAction.METADATA`. In the `METADATA` dispatch block in `Gff3Parser.next_view()` (`gff/parser.mojo:356-363`), add a branch for `###`:

```
if _starts_with(line, "###"):
    pass  # forward-reference flush — no-op for streaming parser
```

This makes the directive recognised rather than ignored by accident, and trivially enables future extension (e.g., a counter, a callback, or a directive record in the iterator).

### Tests to add

- `test_gff3_triple_hash_is_skipped` — input with `###` between two valid records; assert both records are returned without error and the `###` line does not stop iteration.
- `test_gff3_triple_hash_between_records` — same; assert record count is exactly 2.

---

## Cross-Cutting Concerns

### Error propagation audit (Issue 1 first)

After fixing Issue 1, all code using `for rec in parser.records()` (or `views()`) will now see parse errors instead of silent stops. Audit every for-loop call site in the test files — particularly the helper functions in `test_agat_fixtures.mojo` — to confirm they handle the new behaviour. The AGAT helpers use `while parser.has_more(): parser.next_record()` (not for-loops) and are unaffected; the for-loop helpers must be reviewed.

### `BString` emptiness check

Issues 9 and 4 need to test `BString` emptiness. Check `blazeseq/byte_string.mojo` for the canonical emptiness test before implementing — do not assume `__len__` exists; use `to_string() == ""` as a safe fallback.

### Behavioural change in Issue 8

`Gff3Record.seqid()` now returns a decoded string for files with percent-encoded seqids. This is a behavioural (not signature) change. Mark it explicitly in the changelog entry for this branch.

---

## Implementation Order

### Phase 1 — Critical

**Issue 1** first. All subsequent test additions depend on parse errors being visible to the caller. No dependencies on other issues.

### Phase 2 — Independent correctness fixes (can be parallelised)

- **Issue 2** — Coordinate ≥ 1 validation. Add `COORD_ZERO` codes and two post-parse guards.
- **Issue 7** — `.` attribute column recognition. Single early-exit guard in `parse_gff3_attributes`.
- **Issue 10** — `###` reclassification. Trivial one-line change plus a no-op handler.
- **Issue 6** — `##gff-version` token parse. Replace byte-offset check with proper token logic.

### Phase 3 — GTF attribute correctness (sequential within this phase)

1. **Issue 3** — Unquoted values. Adds the unquoted fallback branch in `parse_gtf_attributes`. Must come before Issue 5.
2. **Issue 5** — Backslash escapes. Add `_gtf_unescape_value` and apply in both branches from Issue 3.
3. **Issue 4** — `get_all()`. Storage is already correct; adds the retrieval API on top of the completed attribute parsing.

### Phase 4 — Encoding and warnings

- **Issue 8** — seqid percent-decode. Import `percent_decode_to_bstring` into `gff/record.mojo` and `gff/parser.mojo`.
- **Issue 9** — Missing mandatory attrs. Extends `GtfParser` struct (layout change); must come after Issues 3, 5, and 4 are stable.

