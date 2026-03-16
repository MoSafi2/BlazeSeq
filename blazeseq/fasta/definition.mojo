from blazeseq.byte_string import BString


@fieldwise_init
struct Definition(Copyable, Movable):
    """Definition of a FASTA/FASTQ record.

    The FASTA/FASTQ definition line is the first line after '>' or '@':
    the first whitespace-separated token is the identifier (Id), the rest
    is the optional description.

    Attributes:
        Id: The identifier of the record.
        Description: The description of the record (optional; None if absent).
    """

    var Id: BString
    var Description: Optional[BString]
