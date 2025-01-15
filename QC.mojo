from blazeseq.parser import RecordParser
from blazeseq.stats import FullStats
from time import perf_counter_ns
from sys import argv


fn main() raises:
    args = argv()
    var parser = RecordParser[validate_ascii=False, validate_quality=False](
        String(args[1])
    )
    var stats = FullStats()

    var n = 0

    t0 = perf_counter_ns()
    while True:
        try:
            var record = parser.next()
            stats.tally(record)
            n += 1
        except:
            t1 = perf_counter_ns()
            stats.make_html("test.html")
            t2 = perf_counter_ns()
            print(n)
            print("Total tally time: ", (t1 - t0) / 1e9, "s")
            print("Total Plot time", (t2 - t1) / 1e9, "s")
            break
