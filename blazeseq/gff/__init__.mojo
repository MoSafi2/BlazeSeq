"""GFF/GTF/GFF3 parsing and record types."""

from blazeseq.gff.record import (
    GffRecord,
    GffView,
    GffStrand,
    SequenceRegion,
    TargetAttribute,
    parse_target_attribute,
)
from blazeseq.gff.attributes import GffAttributes
from blazeseq.gff.parser import GtfParser, Gff3Parser
