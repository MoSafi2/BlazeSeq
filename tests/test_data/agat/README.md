# AGAT test fixtures (GFF / GTF)

Test files are copied from the [AGAT](https://github.com/NBISweden/AGAT) integration suite under [`t/`](https://github.com/NBISweden/AGAT/tree/master/t).

## Pinned revision

- **Commit:** `3a747183886eb8c9050225d32553fe6b6635b6de` (`master` as of vendor import)
- **Upstream tree:** [NBISweden/AGAT @ `t/`](https://github.com/NBISweden/AGAT/tree/master/t)

Refresh by shallow-cloning that repo at this commit (or updating the pin) and recopying the paths listed below.

## License / attribution

AGAT is distributed under the **GNU General Public License v3** (see the upstream repository). These files are **third-party test vectors** used for parser interoperability; they are not BlazeSeq code.

## Layout and role

| Directory | Source in AGAT | Contents |
|-----------|----------------|----------|
| `gff_syntax/in/` | [`t/gff_syntax/in`](https://github.com/NBISweden/AGAT/tree/master/t/gff_syntax/in) | Numbered `*_test.gff` inputs (gene / mRNA / exon / CDS graphs, missing parents, RefSeq quirks, spread isoforms, etc.). Case-by-case descriptions: [AGAT `t/gff_syntax/README`](https://github.com/NBISweden/AGAT/blob/master/t/gff_syntax/README). |
| `gff_other/in/` | [`t/gff_other/in`](https://github.com/NBISweden/AGAT/tree/master/t/gff_other/in) | Issue-driven `.gff` and `.gtf` samples (e.g. URLEscape decode, GitHub issues). **Not included:** `zip_and_fasta.gff.gz` (compressed; needs a gzip reader path in tests). |
| `script_sp/in/` | [`t/script_sp/in`](https://github.com/NBISweden/AGAT/tree/master/t/script_sp/in) | `test_kraken.gtf` for extra GTF coverage. |

## What BlazeSeq tests do **not** cover

AGAT’s own `.t` tests run Perl drivers and CLI tools (e.g. `agat_convert_sp_gxf2gxf.pl`), then **diff** normalized output under `t/.../out/`. BlazeSeq only checks **line-oriented parsing**: nine tab-separated columns and attribute syntax understood by `Gff3Parser` / `GtfParser` in this repository. We do **not** compare to AGAT’s “correct” `out/*.gff` files.

## Deferred / known mismatches

- **`t/gff_version/`** (not vendored): often **GFF1**-style column 9 text; expects different attribute rules than GFF3 `key=value`.
- **Compressed fixtures** (`zip_and_fasta.gff.gz`): omitted until tests use `GZFile` / `RapidgzipReader` consistently for GFF.
- **`gff_other` tabix case**: large/tabix-oriented inputs are not part of this tree.
- Some inputs use attribute shapes that a strict GFF3 attribute parser may reject; see `KNOWN_GFF3_FAILURES` in [`tests/gff/test_agat_fixtures.mojo`](../../gff/test_agat_fixtures.mojo).
