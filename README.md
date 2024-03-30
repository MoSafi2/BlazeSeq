
# Blaze-Seq🔥 
[Include logo here]

## Fastq Parser for Efficient Sequence Analysis

Blaze-Seq offers a performant and versatile toolkit for parsing and analyzing FASTQ files.  

## Key Features:
* Multiple parsing modes 


## Installation
You can get `blaze-seq` as a `mojopkg` or a `binary` for the CLI tool from the releases page.  
You can also clone and compile the repository yourself.

```bash
git clone [add repo]
cd [repo]
mojo build blazeseq/cli.mojo -o blazeseq_cli //CLI tool
mojo pkg blazeseq //mojo pkg
```


## Getting started
### Command line 

```bash
blazeseq_cli [options] /path/to/file
```
use `blazeseq_cli --help` for full list of options

### interative usage examples

* Parse all records, fast error check.
```mojo
from blazeseq import RecordParser, CoordParser
fn main():
    parser = RecordParser[validate_ascii = True, validate_quality = True](path="path/to/your/file.fastq", schema = "schema)
    # Only validates read headers and Ids length matching
    # parser = CoordParser(path="path/to/your/file.fastq") 
    parser.parse_all()
```


* Get total number of reads and base pairs (fast mode)
```mojo
from blazeseq import CoordParser
fn main():
    var total_reads = 0
    var total_base_pairs = 0
    parser = CoordParser("path/to/your/file.fastq")
    while True:
        try:
            var read = parser.next()
            total_reads += 1
            total_base_pairs += len(read)
        except:
            print(total_reads, total_base_pairs)
            break

```


* Lazy parse, collect record statistics, for now only the `FullStats` option is present (under active development).

```mojo
from blazeseq import RecordParser, FullStats
fn main() raises:
    var parser = RecordParser(path="data/8_Swamp_S1B_MATK_2019_minq7.fastq")
    var stats = FullStats()
    while True:
        try:
            var record = parser.next()
            stats.tally(record)
        except:
            print(stats)
            break
```


## Performance

## Roadmap

## Contribution

## Liscence