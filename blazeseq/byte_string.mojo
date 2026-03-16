# Adapted from: https://github.com/BioRadOpenSource/ish/blob/main/ishlib/vendor/kseq.mojo
# Adapted from Kseq crystal implementation by ssstadick

from std.memory import memcpy, UnsafePointer, Span, alloc
from std.collections.string import StringSlice, String
from blazeseq.utils import memchr


struct BString(Copyable, Equatable, Movable, Sized, Writable):
    """ByteString is a mutable sequence of bytes. it does not ensure any encoding of the bytes.
    """

    # TODO: add address_space
    var size: UInt32
    var cap: UInt32
    var ptr: UnsafePointer[UInt8, MutExternalOrigin]

    fn __init__(out self, capacity: UInt = 0):
        self.ptr = alloc[UInt8](0)
        self.size = 0
        self.cap = 0
        if capacity > 0:
            self.resize(UInt32(capacity))

    fn __init__(out self, s: String):
        self.ptr = alloc[UInt8](len(s))
        memcpy(dest=self.ptr, src=s.unsafe_ptr(), count=len(s))
        self.size = UInt32(len(s))
        self.cap = UInt32(len(s))

    fn __init__(out self, s: Span[UInt8, _]):
        self.ptr = alloc[UInt8](len(s))
        memcpy(dest=self.ptr, src=s.unsafe_ptr(), count=len(s))
        self.size = UInt32(len(s))
        self.cap = UInt32(len(s))

    fn __init__(out self, s: StringSlice[_]):
        self.ptr = alloc[UInt8](len(s))
        memcpy(dest=self.ptr, src=s.unsafe_ptr(), count=len(s))
        self.size = UInt32(len(s))
        self.cap = UInt32(len(s))

    @doc_private
    @always_inline
    fn __del__(deinit self):
        self.ptr.free()

    @doc_private
    @always_inline
    fn __init__(out self, *, copy: Self):
        self.cap = copy.cap
        self.size = copy.size
        self.ptr = alloc[UInt8](Int(self.cap))
        memcpy(dest=self.ptr, src=copy.ptr, count=Int(copy.size))

    @always_inline
    fn __getitem__[I: Indexer](read self, idx: I) -> UInt8:
        return self.ptr[idx]

    @always_inline
    fn __setitem__[I: Indexer](mut self, idx: I, val: UInt8):
        self.ptr[idx] = val

    @always_inline
    fn __len__(read self) -> Int:
        return Int(self.size)

    @always_inline
    fn __eq__(self, other: Self) -> Bool:
        if len(self) != len(other):
            return False
        for i in range(len(self)):
            if self[i] != other[i]:
                return False
        return True

    # TODO: rename offset
    @always_inline
    fn addr[
        I: Indexer
    ](mut self, i: I) -> UnsafePointer[UInt8, MutExternalOrigin]:
        return self.ptr + i

    @staticmethod
    @always_inline
    fn _roundup32(val: UInt32) -> UInt32:
        var x = val
        x -= 1
        x |= x >> 1
        x |= x >> 2
        x |= x >> 4
        x |= x >> 8
        x |= x >> 16
        return x + 1

    @always_inline
    fn clear(mut self):
        self.size = 0

    @always_inline
    fn reserve(mut self, cap: UInt32):
        if cap < self.cap:
            return
        self.cap = cap
        var new_data = alloc[UInt8](Int(self.cap))
        memcpy(dest=new_data, src=self.ptr, count=len(self))
        self.ptr.free()
        self.ptr = new_data

    @always_inline
    fn resize(mut self, size: UInt32):
        var old_size = self.size
        self.size = size
        if self.size <= self.cap:
            return
        self.cap = Self._roundup32(self.size)
        var new_data = alloc[UInt8](Int(self.cap))
        memcpy(dest=new_data, src=self.ptr, count=Int(old_size))

        self.ptr.free()
        self.ptr = new_data

    @always_inline
    fn as_span(ref [_]self) -> Span[UInt8, origin_of(self)]:
        return Span[UInt8, origin_of(self)](
            ptr=self.ptr.unsafe_mut_cast[
                origin_of(self).mut
            ]().unsafe_origin_cast[origin_of(self)](),
            length=len(self),
        )

    fn to_string(self) -> String:
        return String(StringSlice(unsafe_from_utf8=self.as_span()))

    @always_inline
    fn as_string_slice(ref [_]self) -> StringSlice[origin = origin_of(self)]:
        """Return StringSlice view of BString bytes."""
        return StringSlice[origin = origin_of(self)](
            unsafe_from_utf8=self.as_span()
        )

    @always_inline
    fn __ne__(self, other: Self) -> Bool:
        """Compare two ASCIIStrings for inequality."""
        return not self.__eq__(other)

    @always_inline
    fn write_to[w: Writer](self, mut writer: w) -> None:
        writer.write(self.as_string_slice())

    @always_inline
    fn extend(mut self, src: Span[UInt8, _]):
        var needed = self.size + UInt32(len(src))
        if needed > self.cap:
            self.reserve(Self._roundup32(needed))
        memcpy(
            dest=self.ptr + Int(self.size), src=src.unsafe_ptr(), count=len(src)
        )
        self.size = needed

    @always_inline
    fn extend(mut self, src: List[UInt8]):
        var needed = self.size + UInt32(len(src))
        if needed > self.cap:
            self.reserve(Self._roundup32(needed))
        memcpy(
            dest=self.ptr + Int(self.size), src=src.unsafe_ptr(), count=len(src)
        )
        self.size = needed

    @always_inline
    fn extend(mut self, read src: BString):
        var needed = self.size + src.size
        if needed > self.cap:
            self.reserve(Self._roundup32(needed))
        memcpy(dest=self.ptr + Int(self.size), src=src.ptr, count=Int(src.size))
        self.size = needed
