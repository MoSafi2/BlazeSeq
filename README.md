
# Blaze-Seq🔥 
[Include logo here]

## Fastq Parser for Efficient Sequence Analysis

Blaze-Seq offers a performant and versatile toolkit for parsing and analyzing FASTQ files.  

## Key Features:


## Getting started
### Installation


### Command line 

```console
blazeseq_cli [options] /path/to/file
```

### interative usage

Parse all records, fast error check.
```python
from blazeseq import RecordParser, CoordParser
parser = RecordParser(path="path/to/your/file.fastq")
parser.parse_all()
```
Lazy parse, stats can be collected about the records.

```python
from blazeseq import RecordParser, FullStats
parser = RecordParser(path="path/to/your/file.fastq")
stats = FullStats()
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