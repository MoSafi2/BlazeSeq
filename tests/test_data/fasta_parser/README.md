# FASTA test data (Biopython SeqIO)

Test files from the [Biopython Tests/Fasta](https://github.com/biopython/biopython/tree/master/Tests/Fasta) directory, used for correctness testing of the FASTA parser.

## File types

| Type    | Files | Description |
|---------|--------|--------------|
| SeqIO   | f001, f002, f003.fa, fa01 | Common FASTA files used by Bio.SeqIO and Bio.AlignIO |
| Protein | aster.pro, aster_blast.pro, aster_no_wrap.pro, aster_pearson.pro, loveliesbleeding.pro, rose.pro, rosemary.pro | Protein sequences (.pro) |
| Nucleotide | centaurea.nu, elderberry.nu, lavender.nu, lupine.nu, phlox.nu, sweetpea.nu, wisteria.nu | Nucleotide sequences (.nu) |

Note: `aster_blast.pro` and `aster_pearson.pro` contain comment lines before the first `>` header; the parser expects standard FASTA (first line is a header). Tests use only files that start with a `>` line.
