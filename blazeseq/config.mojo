from blazeseq.helpers import _seq_to_hash
from collections import Dict


# TODO: Move those to a config file
##############
fn hash_list() -> List[UInt64]:
    var li: List[UInt64] = List[UInt64](
        _seq_to_hash("AGATCGGAAGAG"),
        _seq_to_hash("TGGAATTCTCGG"),
        _seq_to_hash("GATCGTCGGACT"),
        _seq_to_hash("CTGTCTCTTATA"),
        _seq_to_hash("AAAAAAAAAAAA"),
        _seq_to_hash("GGGGGGGGGGGG"),
    )
    return li


# TODO: Check how to unpack this variadic
def hash_names() -> (
    ListLiteral[
        StringLiteral,
        StringLiteral,
        StringLiteral,
        StringLiteral,
        StringLiteral,
        StringLiteral,
    ]
):
    var names = [
        "Illumina Universal Adapter",
        "Illumina Small RNA 3' Adapter",
        "Illumina Small RNA 5' Adapter",
        "Nextera Transposase Sequence",
        "PolyA",
        "PolyG",
    ]

    return names


def get_hashes() -> Dict[String, String]:
    var hashes = Dict[String, String]()
    hashes["Illumina Universal Adapter"] = "AGATCGGAAGAG"
    hashes["Illumina Small RNA 3' Adapter"] = "TGGAATTCTCGG"
    hashes["Illumina Small RNA 5' Adapter"] = "GATCGTCGGACT"
    hashes["Nextera Transposase Sequence"] = "CTGTCTCTTATA"
    hashes["PolyA"] = "AAAAAAAAAAAA"
    hashes["PolyG"] = "GGGGGGGGGGGG"
    return hashes
