from benchmark import keep
from os.fstat import stat
from memory import UnsafePointer, OwnedPointer
from collections import InlineArray

fn main() raises:
    var x = OwnedPointer(InlineArray[UInt8, size=500*1024*1024](uninitialized=True))
    var y = Span[origin=__origin_of(x)](ptr=x.unsafe_ptr(), length=6400)
    var z = rebind[dest_type=Span[origin=__origin_of(x), T=UInt8]](y[1:5000])
    print((String(bytes=z)))
