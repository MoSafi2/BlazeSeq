"""Correctness tests for GtfParser and Gff3Parser."""

from blazeseq import (
    GtfParser, GtfRecord, GtfView, GtfStrand, GtfAttributes,
    Gff3Parser, Gff3Record, Gff3View, Gff3Strand, Gff3Attributes,
)
from blazeseq.io import MemoryReader
from std.collections.string import String
from std.testing import assert_equal, assert_true, TestSuite


# ---------------------------------------------------------------------------
# GTF parsing
# ---------------------------------------------------------------------------


def test_gtf_parse_one_record() raises:
    """Parse one GTF line and check core fields and attributes."""
    var data = "1\tEnsembl\tgene\t11869\t14409\t.\t+\t.\tgene_id \"ENSG00000223972\"; gene_name \"DDX11L1\";\n"
    var reader = MemoryReader(data)
    var parser = GtfParser[MemoryReader](reader^)
    assert_true(parser.has_more())
    var rec = parser.next_record()
    assert_equal(rec.seqid(), "1")
    assert_equal(rec.source(), "Ensembl")
    assert_equal(rec.feature_type(), "gene")
    assert_equal(rec.Start, 11869)
    assert_equal(rec.End, 14409)
    assert_true(not rec.Score)
    assert_true(rec.Strand)
    assert_equal(rec.Strand.value(), GtfStrand.Plus)
    assert_true(not rec.Phase)
    var gene_id = rec.get_attribute("gene_id")
    assert_true(gene_id)
    assert_equal(gene_id.value().to_string(), "ENSG00000223972")
    var gene_name = rec.get_attribute("gene_name")
    assert_true(gene_name)
    assert_equal(gene_name.value().to_string(), "DDX11L1")
    assert_true(not parser.has_more())


def test_gtf_skip_comment_lines() raises:
    """GTF parser skips lines starting with #."""
    var data = "# comment\n1\tx\tgene\t1\t100\t.\t-\t.\tgene_id \"g1\";\n"
    var reader = MemoryReader(data)
    var parser = GtfParser[MemoryReader](reader^)
    var rec = parser.next_record()
    assert_equal(rec.seqid(), "1")
    assert_equal(rec.Start, 1)
    assert_equal(rec.End, 100)
    assert_true(rec.Strand.value() == GtfStrand.Minus)
    assert_true(not parser.has_more())


def test_gtf_view_to_record() raises:
    """Zero-copy view can be converted to owned record."""
    var data = "chr1\tsrc\t exon\t100\t200\t0.95\t+\t0\tgene_id \"g1\"; transcript_id \"t1\";\n"
    var reader = MemoryReader(data)
    var parser = GtfParser[MemoryReader](reader^)
    var view = parser.next_view()
    assert_equal(String(view.seqid()), "chr1")
    assert_equal(view.start, 100)
    assert_equal(view.end, 200)
    assert_true(view.score)
    assert_equal(view.score.value(), 0.95)
    assert_true(view.phase)
    assert_equal(view.phase.value(), 0)
    var rec = view.to_record()
    assert_equal(rec.seqid(), "chr1")
    assert_equal(rec.get_attribute("gene_id").value().to_string(), "g1")
    assert_equal(rec.get_attribute("transcript_id").value().to_string(), "t1")


def test_gtf_mandatory_gene_transcript_id() raises:
    """GtfRecord exposes gene_id and transcript_id as direct fields."""
    var data = "chr1\t.\tCDS\t1\t2\t.\t.\t0\tgene_id \"ENSG001\"; transcript_id \"ENST001\";\n"
    var reader = MemoryReader(data)
    var parser = GtfParser[MemoryReader](reader^)
    var rec = parser.next_record()
    assert_equal(rec.Attributes.gene_id.to_string(), "ENSG001")
    assert_equal(rec.Attributes.transcript_id.to_string(), "ENST001")


# ---------------------------------------------------------------------------
# GFF3 parsing
# ---------------------------------------------------------------------------


def test_gff3_parse_one_record() raises:
    """Parse one GFF3 line with key=value attributes."""
    var data = "##gff-version 3\nchr1\tsource\tgene\t1000\t2000\t.\t+\t.\tID=gene1;Name=MyGene;\n"
    var reader = MemoryReader(data)
    var parser = Gff3Parser[MemoryReader](reader^)
    assert_true(parser.has_more())
    var rec = parser.next_record()
    assert_equal(rec.seqid(), "chr1")
    assert_equal(rec.source(), "source")
    assert_equal(rec.feature_type(), "gene")
    assert_equal(rec.Start, 1000)
    assert_equal(rec.End, 2000)
    var id_attr = rec.get_attribute("ID")
    assert_true(id_attr)
    assert_equal(id_attr.value().to_string(), "gene1")
    var name_attr = rec.get_attribute("Name")
    assert_true(name_attr)
    assert_equal(name_attr.value().to_string(), "MyGene")
    assert_true(not parser.has_more())


def test_gff3_multi_value_attribute() raises:
    """GFF3 Parent=id1,id2 parses as multiple values."""
    var data = "##gff-version 3\nchr1\t.\texon\t1\t50\t.\t.\t.\tID=ex1;Parent=tr1,tr2;\n"
    var reader = MemoryReader(data)
    var parser = Gff3Parser[MemoryReader](reader^)
    var rec = parser.next_record()
    var parents = rec.Attributes.get_all("Parent")
    assert_equal(len(parents), 2)
    assert_equal(parents[0].to_string(), "tr1")
    assert_equal(parents[1].to_string(), "tr2")


def test_gff3_stops_at_fasta() raises:
    """GFF3 parser stops at ##FASTA; only one feature is returned, next read raises."""
    var data = "##gff-version 3\nchr1\t.\tgene\t1\t100\t.\t.\t.\tID=g1;\n##FASTA\n>seq1\nACGT\n"
    var reader = MemoryReader(data)
    var parser = Gff3Parser[MemoryReader](reader^)
    var rec = parser.next_record()
    assert_equal(rec.get_attribute("ID").value().to_string(), "g1")
    var count: Int = 1
    try:
        _ = parser.next_record()
        count += 1
    except:
        pass
    assert_equal(count, 1, "exactly one record before ##FASTA")


def test_gff3_typed_attribute_accessors() raises:
    """Gff3Attributes typed accessors for GFF3 reserved attributes."""
    var data = "##gff-version 3\nchr1\t.\texon\t1\t50\t.\t.\t.\tID=ex1;Name=MyExon;Parent=tr1,tr2;Note=test\n"
    var reader = MemoryReader(data)
    var parser = Gff3Parser[MemoryReader](reader^)
    var rec = parser.next_record()
    assert_equal(rec.Attributes.id().value().to_string(), "ex1")
    assert_equal(rec.Attributes.name().value().to_string(), "MyExon")
    var parents = rec.Attributes.parent()
    assert_equal(len(parents), 2)
    assert_equal(parents[0].to_string(), "tr1")
    assert_equal(parents[1].to_string(), "tr2")
    assert_equal(rec.Attributes.note().value().to_string(), "test")
    assert_true(not rec.Attributes.is_circular())


# ---------------------------------------------------------------------------
# Attribute parsing (via full record)
# ---------------------------------------------------------------------------


def test_parse_gtf_attributes() raises:
    """GTF attribute string parses to key-value pairs via full line."""
    var data = "chr1\t.\tgene\t1\t2\t.\t.\t.\tgene_id \"ENSG001\"; transcript_id \"ENST001\";\n"
    var reader = MemoryReader(data)
    var parser = GtfParser[MemoryReader](reader^)
    var rec = parser.next_record()
    assert_equal(len(rec.Attributes), 2)
    var gid = rec.get_attribute("gene_id")
    assert_true(gid)
    assert_equal(gid.value().to_string(), "ENSG001")
    var tid = rec.get_attribute("transcript_id")
    assert_true(tid)
    assert_equal(tid.value().to_string(), "ENST001")


def test_parse_gff3_attributes() raises:
    """GFF3 key=value and multi-value parse via full line."""
    var data = "##gff-version 3\nchr1\t.\texon\t1\t50\t.\t.\t.\tID=ex1;Name=Exon1;Parent=tr1,tr2\n"
    var reader = MemoryReader(data)
    var parser = Gff3Parser[MemoryReader](reader^)
    var rec = parser.next_record()
    assert_equal(len(rec.Attributes), 3)
    assert_equal(rec.get_attribute("ID").value().to_string(), "ex1")
    assert_equal(rec.get_attribute("Name").value().to_string(), "Exon1")
    var parents = rec.Attributes.get_all("Parent")
    assert_equal(len(parents), 2)
    assert_equal(parents[0].to_string(), "tr1")
    assert_equal(parents[1].to_string(), "tr2")


def test_percent_decode() raises:
    """RFC 3986 percent-encoding in GFF3 attributes decodes correctly."""
    var data = "##gff-version 3\nchr1\t.\tgene\t1\t10\t.\t.\t.\tName=foo%20bar%3B\n"
    var reader = MemoryReader(data)
    var parser = Gff3Parser[MemoryReader](reader^)
    var rec = parser.next_record()
    var name_attr = rec.get_attribute("Name")
    assert_true(name_attr)
    assert_equal(name_attr.value().to_string(), "foo bar;")


# ---------------------------------------------------------------------------
# Coordinates
# ---------------------------------------------------------------------------


def test_gff_interval() raises:
    """Gff3Record interval() returns 1-based closed [start, end]."""
    var data = "chr1\t.\tgene\t10\t20\t.\t+\t.\tID=g1;\n"
    var reader = MemoryReader(data)
    var parser = Gff3Parser[MemoryReader](reader^)
    var rec = parser.next_record()
    var iv = rec.interval()
    assert_equal(iv.start().get(), 10)
    assert_equal(iv.end().get(), 20)
    assert_equal(iv.length(), 11)


# ---------------------------------------------------------------------------
# Issue 1 — Iterator error propagation
# ---------------------------------------------------------------------------


def test_gff3_iter_propagates_parse_error() raises:
    """A for-loop over records with a bad field count raises, not silently stops."""
    var data = "##gff-version 3\nchr1\tsource\tgene\t1\t100\t.\t+\t.\n"  # 8 fields, not 9
    var reader = MemoryReader(data)
    var parser = Gff3Parser[MemoryReader](reader^)
    var saw_error = False
    try:
        for _ in parser:
            pass
    except e:
        var msg = String(e)
        assert_true(msg.find("9 fields") != -1 or msg.find("field") != -1)
        saw_error = True
    assert_true(saw_error, "expected a parse error from the for-loop iterator")


def test_gtf_iter_propagates_parse_error() raises:
    """A for-loop over GTF records with a bad field count raises, not silently stops."""
    var data = "chr1\tsource\tgene\t1\t100\t.\t+\n"  # 7 fields, not 9
    var reader = MemoryReader(data)
    var parser = GtfParser[MemoryReader](reader^)
    var saw_error = False
    try:
        for _ in parser:
            pass
    except e:
        var msg = String(e)
        assert_true(msg.find("9 fields") != -1 or msg.find("field") != -1)
        saw_error = True
    assert_true(saw_error, "expected a parse error from the for-loop iterator")


def test_gff3_iter_stops_cleanly_at_eof() raises:
    """A well-formed single-line GFF3 file yields exactly one record."""
    var data = "##gff-version 3\nchr1\t.\tgene\t1\t100\t.\t.\t.\tID=g1;\n"
    var reader = MemoryReader(data)
    var parser = Gff3Parser[MemoryReader](reader^)
    var count = 0
    for _ in parser:
        count += 1
    assert_equal(count, 1)


# ---------------------------------------------------------------------------
# Issue 2 — Coordinate >= 1 validation
# ---------------------------------------------------------------------------


def test_gff3_rejects_start_zero() raises:
    """GFF3 parser rejects start=0 with a >= 1 error."""
    var data = "##gff-version 3\nchr1\t.\tgene\t0\t100\t.\t.\t.\tID=g1;\n"
    var reader = MemoryReader(data)
    var parser = Gff3Parser[MemoryReader](reader^)
    var saw_error = False
    try:
        _ = parser.next_record()
    except e:
        assert_true(String(e).find(">= 1") != -1)
        saw_error = True
    assert_true(saw_error)


def test_gff3_rejects_end_zero() raises:
    """GFF3 parser rejects end=0 with a >= 1 error before a start>end error."""
    var data = "##gff-version 3\nchr1\t.\tgene\t1\t0\t.\t.\t.\tID=g1;\n"
    var reader = MemoryReader(data)
    var parser = Gff3Parser[MemoryReader](reader^)
    var saw_error = False
    try:
        _ = parser.next_record()
    except e:
        assert_true(String(e).find(">= 1") != -1)
        saw_error = True
    assert_true(saw_error)


def test_gff3_accepts_start_one() raises:
    """start=1 parses cleanly."""
    var data = "##gff-version 3\nchr1\t.\tgene\t1\t100\t.\t.\t.\tID=g1;\n"
    var reader = MemoryReader(data)
    var parser = Gff3Parser[MemoryReader](reader^)
    var rec = parser.next_record()
    assert_equal(rec.Start, 1)


def test_gtf_rejects_start_zero() raises:
    """GTF parser rejects start=0 with a >= 1 error."""
    var data = "chr1\t.\tgene\t0\t100\t.\t+\t.\tgene_id \"g1\";\n"
    var reader = MemoryReader(data)
    var parser = GtfParser[MemoryReader](reader^)
    var saw_error = False
    try:
        _ = parser.next_record()
    except e:
        assert_true(String(e).find(">= 1") != -1)
        saw_error = True
    assert_true(saw_error)


def test_gtf_rejects_end_zero() raises:
    """GTF parser rejects end=0 with a >= 1 error."""
    var data = "chr1\t.\tgene\t1\t0\t.\t+\t.\tgene_id \"g1\";\n"
    var reader = MemoryReader(data)
    var parser = GtfParser[MemoryReader](reader^)
    var saw_error = False
    try:
        _ = parser.next_record()
    except e:
        assert_true(String(e).find(">= 1") != -1)
        saw_error = True
    assert_true(saw_error)


# ---------------------------------------------------------------------------
# Issue 3 — GTF unquoted attribute values
# ---------------------------------------------------------------------------


def test_gtf_unquoted_attribute_value() raises:
    """Unquoted integer value like 'exon_number 3' is parsed correctly."""
    var data = "chr1\t.\texon\t1\t100\t.\t+\t.\tgene_id \"g1\"; exon_number 3;\n"
    var reader = MemoryReader(data)
    var parser = GtfParser[MemoryReader](reader^)
    var rec = parser.next_record()
    var v = rec.get_attribute("exon_number")
    assert_true(v)
    assert_equal(v.value().to_string(), "3")


def test_gtf_unquoted_gene_id() raises:
    """Unquoted gene_id value is treated as the gene_id."""
    var data = "chr1\t.\tgene\t1\t100\t.\t+\t.\tgene_id ENSG001;\n"
    var reader = MemoryReader(data)
    var parser = GtfParser[MemoryReader](reader^)
    var rec = parser.next_record()
    assert_equal(rec.Attributes.gene_id.to_string(), "ENSG001")


def test_gtf_mixed_quoted_and_unquoted() raises:
    """Mix of quoted and unquoted attributes in the same column all resolve."""
    var data = "chr1\t.\tgene\t1\t100\t.\t+\t.\tgene_id \"ENSG001\"; exon_number 5; transcript_id \"ENST001\";\n"
    var reader = MemoryReader(data)
    var parser = GtfParser[MemoryReader](reader^)
    var rec = parser.next_record()
    assert_equal(rec.Attributes.gene_id.to_string(), "ENSG001")
    assert_equal(rec.Attributes.transcript_id.to_string(), "ENST001")
    assert_equal(rec.get_attribute("exon_number").value().to_string(), "5")


# ---------------------------------------------------------------------------
# Issue 4 — GTF duplicate-key attributes
# ---------------------------------------------------------------------------


def test_gtf_duplicate_key_get_all() raises:
    """get_all_attributes returns all values for a duplicate key."""
    var data = "chr1\t.\tgene\t1\t100\t.\t+\t.\tgene_id \"g1\"; tag \"v1\"; tag \"v2\";\n"
    var reader = MemoryReader(data)
    var parser = GtfParser[MemoryReader](reader^)
    var rec = parser.next_record()
    var tags = rec.get_all_attributes("tag")
    assert_equal(len(tags), 2)
    assert_equal(tags[0].to_string(), "v1")
    assert_equal(tags[1].to_string(), "v2")


def test_gtf_get_returns_first_value() raises:
    """get_attribute still returns the first value for a duplicate key."""
    var data = "chr1\t.\tgene\t1\t100\t.\t+\t.\tgene_id \"g1\"; tag \"v1\"; tag \"v2\";\n"
    var reader = MemoryReader(data)
    var parser = GtfParser[MemoryReader](reader^)
    var rec = parser.next_record()
    assert_equal(rec.get_attribute("tag").value().to_string(), "v1")


def test_gtf_get_all_mandatory_ids() raises:
    """get_all_attributes for gene_id returns a single-element list."""
    var data = "chr1\t.\tgene\t1\t100\t.\t+\t.\tgene_id \"ENSG001\"; transcript_id \"ENST001\";\n"
    var reader = MemoryReader(data)
    var parser = GtfParser[MemoryReader](reader^)
    var rec = parser.next_record()
    var ids = rec.get_all_attributes("gene_id")
    assert_equal(len(ids), 1)
    assert_equal(ids[0].to_string(), "ENSG001")


# ---------------------------------------------------------------------------
# Issue 5 — GTF backslash escapes
# ---------------------------------------------------------------------------


def test_gtf_backslash_quote_in_value() raises:
    """Escaped quote inside a quoted value is decoded."""
    var data = "chr1\t.\tgene\t1\t100\t.\t+\t.\tgene_id \"g1\"; note \"it\\\"s a test\";\n"
    var reader = MemoryReader(data)
    var parser = GtfParser[MemoryReader](reader^)
    var rec = parser.next_record()
    assert_equal(rec.get_attribute("note").value().to_string(), "it\"s a test")


def test_gtf_no_backslash_unaffected() raises:
    """A plain value with no backslashes is stored unchanged."""
    var data = "chr1\t.\tgene\t1\t100\t.\t+\t.\tgene_id \"ENSG001\"; transcript_id \"ENST001\";\n"
    var reader = MemoryReader(data)
    var parser = GtfParser[MemoryReader](reader^)
    var rec = parser.next_record()
    assert_equal(rec.Attributes.gene_id.to_string(), "ENSG001")


# ---------------------------------------------------------------------------
# Issue 6 — ##gff-version token parse
# ---------------------------------------------------------------------------


def test_gff3_version_3_accepted() raises:
    """##gff-version 3 is valid."""
    var data = "##gff-version 3\nchr1\t.\tgene\t1\t100\t.\t.\t.\tID=g1;\n"
    var reader = MemoryReader(data)
    var parser = Gff3Parser[MemoryReader](reader^)
    var rec = parser.next_record()
    assert_equal(rec.seqid(), "chr1")


def test_gff3_version_3_1_accepted() raises:
    """##gff-version 3.1 is valid."""
    var data = "##gff-version 3.1\nchr1\t.\tgene\t1\t100\t.\t.\t.\tID=g1;\n"
    var reader = MemoryReader(data)
    var parser = Gff3Parser[MemoryReader](reader^)
    var rec = parser.next_record()
    assert_equal(rec.seqid(), "chr1")


def test_gff3_version_3_1_26_accepted() raises:
    """##gff-version 3.1.26 is valid."""
    var data = "##gff-version 3.1.26\nchr1\t.\tgene\t1\t100\t.\t.\t.\tID=g1;\n"
    var reader = MemoryReader(data)
    var parser = Gff3Parser[MemoryReader](reader^)
    var rec = parser.next_record()
    assert_equal(rec.seqid(), "chr1")


def test_gff3_version_2_rejected() raises:
    """##gff-version 2 raises an error."""
    var data = "##gff-version 2\nchr1\t.\tgene\t1\t100\t.\t.\t.\tID=g1;\n"
    var reader = MemoryReader(data)
    var saw_error = False
    try:
        var parser = Gff3Parser[MemoryReader](reader^)
        _ = parser.next_record()
    except e:
        assert_true(String(e).find("3.x") != -1)
        saw_error = True
    assert_true(saw_error)


def test_gff3_version_trailing_whitespace() raises:
    """##gff-version 3 with trailing spaces is accepted."""
    var data = "##gff-version 3   \nchr1\t.\tgene\t1\t100\t.\t.\t.\tID=g1;\n"
    var reader = MemoryReader(data)
    var parser = Gff3Parser[MemoryReader](reader^)
    var rec = parser.next_record()
    assert_equal(rec.seqid(), "chr1")


# ---------------------------------------------------------------------------
# Issue 7 — Explicit dot-column recognition
# ---------------------------------------------------------------------------


def test_gff3_dot_attributes_column() raises:
    """A literal '.' in column 9 produces empty attributes."""
    var data = "chr1\t.\tgene\t1\t100\t.\t.\t.\t.\n"
    var reader = MemoryReader(data)
    var parser = Gff3Parser[MemoryReader](reader^)
    var rec = parser.next_record()
    assert_equal(len(rec.Attributes), 0)
    assert_true(not rec.get_attribute("ID"))


# ---------------------------------------------------------------------------
# Issue 8 — seqid percent-decoding
# ---------------------------------------------------------------------------


def test_gff3_seqid_percent_decoded() raises:
    """Percent-encoded seqid is decoded in the owned record."""
    var data = "##gff-version 3\nchr1%2Fpatch\t.\tgene\t1\t100\t.\t.\t.\tID=g1;\n"
    var reader = MemoryReader(data)
    var parser = Gff3Parser[MemoryReader](reader^)
    var rec = parser.next_record()
    assert_equal(rec.seqid(), "chr1/patch")


def test_gff3_seqid_no_percent_unchanged() raises:
    """A plain seqid without percent-encoding is unchanged."""
    var data = "##gff-version 3\nchr1\t.\tgene\t1\t100\t.\t.\t.\tID=g1;\n"
    var reader = MemoryReader(data)
    var parser = Gff3Parser[MemoryReader](reader^)
    var rec = parser.next_record()
    assert_equal(rec.seqid(), "chr1")


def test_gff3_sequence_region_seqid_decoded() raises:
    """Percent-encoded seqid in ##sequence-region is decoded."""
    var data = "##gff-version 3\n##sequence-region chr1%2Fpatch 1 1000\nchr1%2Fpatch\t.\tgene\t1\t100\t.\t.\t.\tID=g1;\n"
    var reader = MemoryReader(data)
    var parser = Gff3Parser[MemoryReader](reader^)
    _ = parser.next_record()
    var regions = parser.sequence_regions()
    assert_equal(len(regions), 1)
    assert_equal(regions[0].seqid.to_string(), "chr1/patch")


# ---------------------------------------------------------------------------
# Issue 9 — GTF strict mandatory attribute mode
# ---------------------------------------------------------------------------


def test_gtf_missing_gene_id_lenient() raises:
    """Default (lenient) parser silently accepts a missing gene_id."""
    var data = "chr1\t.\tgene\t1\t100\t.\t+\t.\ttranscript_id \"ENST001\";\n"
    var reader = MemoryReader(data)
    var parser = GtfParser[MemoryReader](reader^)
    var rec = parser.next_record()
    assert_equal(rec.Attributes.gene_id.to_string(), "")


def test_gtf_missing_gene_id_strict() raises:
    """Strict parser raises when gene_id is absent."""
    var data = "chr1\t.\tgene\t1\t100\t.\t+\t.\ttranscript_id \"ENST001\";\n"
    var reader = MemoryReader(data)
    var parser = GtfParser[MemoryReader](reader^, strict_mandatory_attrs=True)
    var saw_error = False
    try:
        _ = parser.next_record()
    except e:
        assert_true(String(e).find("gene_id") != -1)
        assert_true(String(e).find("missing") != -1)
        saw_error = True
    assert_true(saw_error)


def test_gtf_missing_transcript_id_strict() raises:
    """Strict parser raises when transcript_id is absent."""
    var data = "chr1\t.\tgene\t1\t100\t.\t+\t.\tgene_id \"ENSG001\";\n"
    var reader = MemoryReader(data)
    var parser = GtfParser[MemoryReader](reader^, strict_mandatory_attrs=True)
    var saw_error = False
    try:
        _ = parser.next_record()
    except e:
        assert_true(String(e).find("transcript_id") != -1)
        assert_true(String(e).find("missing") != -1)
        saw_error = True
    assert_true(saw_error)


# ---------------------------------------------------------------------------
# Issue 10 — ### directive
# ---------------------------------------------------------------------------


def test_gff3_triple_hash_is_skipped() raises:
    """A ### line between two valid records does not stop iteration."""
    var data = "##gff-version 3\nchr1\t.\tgene\t1\t100\t.\t.\t.\tID=g1;\n###\nchr1\t.\tgene\t200\t300\t.\t.\t.\tID=g2;\n"
    var reader = MemoryReader(data)
    var parser = Gff3Parser[MemoryReader](reader^)
    var count = 0
    for _ in parser:
        count += 1
    assert_equal(count, 2)


def test_gff3_triple_hash_between_records() raises:
    """Exactly two records are returned when ### appears between them."""
    var data = "##gff-version 3\nchr1\t.\tgene\t1\t100\t.\t.\t.\tID=g1;\n###\nchr1\t.\tgene\t200\t300\t.\t.\t.\tID=g2;\n"
    var reader = MemoryReader(data)
    var parser = Gff3Parser[MemoryReader](reader^)
    var r1 = parser.next_record()
    var r2 = parser.next_record()
    assert_equal(r1.get_attribute("ID").value().to_string(), "g1")
    assert_equal(r2.get_attribute("ID").value().to_string(), "g2")
    assert_true(not parser.has_more())


def main() raises:
    var suite = TestSuite.discover_tests[__functions_in_module()]().run()
