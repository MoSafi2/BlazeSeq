# FASTQ Parser Test Data

Test files from the [BioJava](https://github.com/biojava/biojava) / BioPerl / Biopython FASTQ test suites, used for BlazeSeq parser correctness tests. Multi-line FASTQ tests are excluded (BlazeSeq does not support multi-line FASTQ).

Each file is exercised by a dedicated test in `tests/test_fastq_parser_correctness.mojo`. The **Ideal error** column is derived from the FASTQ specification (four-line record: @id, sequence, +, quality) and the failure implied by the file name; **Current error** is what BlazeSeq reports.

| File name | Description | Ideal error | Current error |
|-----------|-------------|-------------|---------------|
| empty.fastq | Empty file; no records | Unexpected end of file; no valid FASTQ record found | EOF |
| error_diff_ids.fastq | Plus line header differs from sequence ID line | Plus line identifier does not match sequence identifier (optional per spec but inconsistent) | EOF |
| error_double_qual.fastq | Duplicate quality line (second record starts with quality) | Expected sequence identifier line (line must start with @) | Sequence id line does not start with '@' |
| error_double_seq.fastq | Duplicate sequence line | Invalid record structure: expected separator line (+) before quality | Quality and sequence line do not match in length |
| error_long_qual.fastq | Quality line longer than sequence | Quality line length must equal sequence length | Quality and sequence line do not match in length |
| error_no_qual.fastq | Missing quality line (empty after plus line) | Missing or empty quality line; quality length must equal sequence length | Quality and sequence line do not match in length |
| error_qual_del.fastq | DEL character in quality string | Quality string contains invalid character for encoding (DEL) | Corrupt quality score according to provided schema |
| error_qual_escape.fastq | Escape character in quality string | Quality string contains invalid character for encoding | Corrupt quality score according to provided schema |
| error_qual_null.fastq | Null byte in quality string | Quality string contains invalid character (null) | Corrupt quality score according to provided schema |
| error_qual_space.fastq | Space in quality string | Quality string must not contain whitespace | Corrupt quality score according to provided schema |
| error_qual_tab.fastq | Tab in quality string | Quality string must not contain whitespace | Corrupt quality score according to provided schema |
| error_qual_unit_sep.fastq | Unit separator in quality string | Quality string contains invalid character for encoding | Corrupt quality score according to provided schema |
| error_qual_vtab.fastq | Vertical tab in quality string | Quality string must not contain whitespace | Corrupt quality score according to provided schema |
| error_short_qual.fastq | Quality line shorter than sequence | Quality line length must equal sequence length | Quality and sequence line do not match in length |
| error_spaces.fastq | Spaces in sequence or invalid quality | Sequence or quality line contains invalid character (whitespace) | Corrupt quality score according to provided schema |
| error_tabs.fastq | Tabs in sequence line | Sequence line must not contain whitespace | Corrupt quality score according to provided schema |
| error_trunc_at_plus.fastq | Truncated at plus line | Truncated FASTQ record: expected separator (+) and quality line | Quality and sequence line do not match in length |
| error_trunc_at_qual.fastq | Truncated in quality line | Truncated FASTQ record: quality line shorter than sequence | Quality and sequence line do not match in length |
| error_trunc_at_seq.fastq | Truncated at sequence line | Truncated FASTQ record: incomplete record at end of file | Quality and sequence line do not match in length |
| error_trunc_in_plus.fastq | Truncated within plus line | Truncated FASTQ record: expected quality line after + | Quality and sequence line do not match in length |
| error_trunc_in_qual.fastq | Truncated within quality line | Truncated FASTQ record: quality line shorter than sequence | Quality and sequence line do not match in length |
| error_trunc_in_seq.fastq | Truncated within sequence line | Truncated FASTQ record: incomplete record at end of file | Quality and sequence line do not match in length |
| error_trunc_in_title.fastq | Truncated in title/ID line | Truncated FASTQ record: incomplete identifier or missing sequence line | Quality and sequence line do not match in length |
| example.fastq | Valid generic/Sanger example (multiple records) | — | Parses successfully |
| example_dos.fastq | Same as example.fastq with CRLF line endings | — | Parses successfully |
| zero_length.fastq | Quality line shorter than sequence (or zero-length read) | Quality line length must equal sequence length | Quality and sequence line do not match in length |
| illumina_example.fastq | Valid Illumina 1.3 example | — | Parses successfully |
| illumina_faked.fastq | Valid Illumina 1.3 faked data | — | Parses successfully |
| illumina_full_range_as_illumina.fastq | Full quality range as Illumina 1.3 | — | Parses successfully |
| illumina_full_range_as_sanger.fastq | Full range encoded as Sanger | — | Parses successfully |
| illumina_full_range_as_solexa.fastq | Full range encoded as Solexa | — | Parses successfully |
| illumina_full_range_original_illumina.fastq | Original Illumina full range | — | Parses successfully |
| illumina-invalid-description.fastq | Description line does not start with @ | Sequence identifier line must start with @ | Sequence id line does not start with '@' |
| illumina-invalid-repeat-description.fastq | Invalid repeat in description | Invalid or malformed sequence description; or unexpected end of file | EOF |
| longreads_as_illumina.fastq | Long reads as Illumina 1.3 | — | Parses successfully |
| longreads_as_sanger.fastq | Long reads as Sanger | — | Parses successfully |
| longreads_as_solexa.fastq | Long reads as Solexa | — | Parses successfully |
| misc_dna_as_illumina.fastq | Misc DNA as Illumina 1.3 | — | Parses successfully |
| misc_dna_as_sanger.fastq | Misc DNA as Sanger | — | Parses successfully |
| misc_dna_as_solexa.fastq | Misc DNA as Solexa | — | Parses successfully |
| misc_dna_original_sanger.fastq | Misc DNA original Sanger | — | Parses successfully |
| misc_rna_as_illumina.fastq | Misc RNA as Illumina 1.3 | — | Parses successfully |
| misc_rna_as_sanger.fastq | Misc RNA as Sanger | — | Parses successfully |
| misc_rna_as_solexa.fastq | Misc RNA as Solexa | — | Parses successfully |
| misc_rna_original_sanger.fastq | Misc RNA original Sanger | — | Parses successfully |
| sanger_93.fastq | Valid Sanger Phred 93 | — | Parses successfully |
| sanger_faked.fastq | Valid Sanger faked data | — | Parses successfully |
| sanger_full_range_as_illumina.fastq | Sanger full range as Illumina 1.3 | — | Parses successfully |
| sanger_full_range_as_sanger.fastq | Sanger full range as Sanger | — | Parses successfully |
| sanger_full_range_as_solexa.fastq | Sanger full range as Solexa | — | Parses successfully |
| sanger_full_range_original_sanger.fastq | Sanger full range original | — | Parses successfully |
| sanger-invalid-description.fastq | Description line does not start with @ | Sequence identifier line must start with @ | Sequence id line does not start with '@' |
| sanger-invalid-repeat-description.fastq | Invalid repeat in description | Invalid or malformed sequence description; or unexpected end of file | EOF |
| solexa_example.fastq | Valid Solexa example | — | Parses successfully |
| solexa_faked.fastq | Valid Solexa faked data | — | Parses successfully |
| solexa_full_range_as_illumina.fastq | Solexa full range as Illumina 1.3 | — | Parses successfully |
| solexa_full_range_as_sanger.fastq | Solexa full range as Sanger | — | Parses successfully |
| solexa_full_range_as_solexa.fastq | Solexa full range as Solexa | — | Parses successfully |
| solexa_full_range_original_solexa.fastq | Solexa full range original | — | Parses successfully |
| solexa-invalid-description.fastq | First line not @ (invalid description) | Sequence identifier line must start with @ | Sequence id line does not start with '@' |
| solexa-invalid-repeat-description.fastq | Invalid repeat in description | Invalid or malformed sequence description; or unexpected end of file | EOF |
| test1_sanger.fastq | Valid test 1 Sanger | — | Parses successfully |
| test2_solexa.fastq | Valid test 2 Solexa | — | Parses successfully |
| test3_illumina.fastq | Valid test 3 Illumina 1.3 | — | Parses successfully |
| wrapping_as_illumina.fastq | Wrapped lines as Illumina 1.3 | — | Parses successfully |
| wrapping_as_sanger.fastq | Wrapped lines as Sanger | — | Parses successfully |
| wrapping_as_solexa.fastq | Wrapped lines as Solexa | — | Parses successfully |

## Multi-line (disabled)

The following files contain multi-line (wrapped) sequence or quality lines. BlazeSeq does not support multi-line FASTQ. Test data is present; corresponding tests in `test_fastq_parser_correctness.mojo` are commented out until multi-line support exists.

| File | Description |
|------|-------------|
| tricky.fastq | Multi-line sequence/quality; edge cases |
| longreads_original_sanger.fastq | Long reads, wrapped lines, Sanger |
| wrapping_original_sanger.fastq | Wrapped sequence/quality, Sanger |

## Compressed (RapidgzipReader)

Compressed FASTQ files are parsed with `RapidgzipReader` in correctness tests.

| File | Description |
|------|-------------|
| example.fastq.gz | example.fastq gzip-compressed |
| example.fastq.bgz | example.fastq block gzip (if supported) |
| example_dos.fastq.bgz | example_dos.fastq block gzip (if supported) |

## Updating the "Current error" column

To refresh the *Current error* values (e.g. after parser changes), run the parser on each invalid file and record the exception message. The correctness tests in `tests/test_fastq_parser_correctness.mojo` accept the ideal error or alternatives (EOF, length mismatch, sequence id line, plus/separator line) where the parser may report a related error.
