from benchmark import keep
from os.fstat import stat
from memory import UnsafePointer
from collections import InlineArray

fn main() raises:
    var x = InlineArray[UInt8, size=64000](67)
    print(x[50])
    var y = Span[origin=__origin_of(x)](ptr=x.unsafe_ptr(), length=6400)
    var z = rebind[dest_type=Span[origin=__origin_of(x), T=UInt8]](y[1:50])
    print((String(bytes=z)))
