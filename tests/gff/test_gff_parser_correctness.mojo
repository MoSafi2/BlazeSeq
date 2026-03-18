"""Correctness tests for GtfParser and Gff3Parser."""

from blazeseq import GtfParser, Gff3Parser, GffRecord, GffView, GffStrand
from blazeseq.io import MemoryReader
from std.collections.string import String
from std.testing import assert_equal, assert_true, TestSuite


# ---------------------------------------------------------------------------
# GTF parsing
# ---------------------------------------------------------------------------


fn test_gtf_parse_one_record() raises:
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
    assert_equal(rec.Strand.value(), GffStrand.Plus)
    assert_true(not rec.Phase)
    var gene_id = rec.get_attribute("gene_id")
    assert_true(gene_id)
    assert_equal(gene_id.value().to_string(), "ENSG00000223972")
    var gene_name = rec.get_attribute("gene_name")
    assert_true(gene_name)
    assert_equal(gene_name.value().to_string(), "DDX11L1")
    assert_true(not parser.has_more())


fn test_gtf_skip_comment_lines() raises:
    """GTF parser skips lines starting with #."""
    var data = "# comment\n1\tx\tgene\t1\t100\t.\t-\t.\tgene_id \"g1\";\n"
    var reader = MemoryReader(data)
    var parser = GtfParser[MemoryReader](reader^)
    var rec = parser.next_record()
    assert_equal(rec.seqid(), "1")
    assert_equal(rec.Start, 1)
    assert_equal(rec.End, 100)
    assert_true(rec.Strand.value() == GffStrand.Minus)
    assert_true(not parser.has_more())


fn test_gtf_view_to_record() raises:
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


# ---------------------------------------------------------------------------
# GFF3 parsing
# ---------------------------------------------------------------------------


fn test_gff3_parse_one_record() raises:
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


fn test_gff3_multi_value_attribute() raises:
    """GFF3 Parent=id1,id2 parses as multiple values."""
    var data = "##gff-version 3\nchr1\t.\texon\t1\t50\t.\t.\t.\tID=ex1;Parent=tr1,tr2;\n"
    var reader = MemoryReader(data)
    var parser = Gff3Parser[MemoryReader](reader^)
    var rec = parser.next_record()
    var parents = rec.Attributes.get_all("Parent")
    assert_equal(len(parents), 2)
    assert_equal(parents[0].to_string(), "tr1")
    assert_equal(parents[1].to_string(), "tr2")


fn test_gff3_stops_at_fasta() raises:
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


# ---------------------------------------------------------------------------
# Attribute parsing (via full record)
# ---------------------------------------------------------------------------


fn test_parse_gtf_attributes() raises:
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


fn test_parse_gff3_attributes() raises:
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


fn test_percent_decode() raises:
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


fn test_gff_interval() raises:
    """GffRecord interval() returns 1-based closed [start, end]."""
    var data = "chr1\t.\tgene\t10\t20\t.\t+\t.\tID=g1;\n"
    var reader = MemoryReader(data)
    var parser = Gff3Parser[MemoryReader](reader^)
    var rec = parser.next_record()
    var iv = rec.interval()
    assert_equal(iv.start().get(), 10)
    assert_equal(iv.end().get(), 20)
    assert_equal(iv.length(), 11)


fn main() raises:
    var suite = TestSuite.discover_tests[__functions_in_module()]().run()
