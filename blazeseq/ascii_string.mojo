# Adapted from: https://github.com/BioRadOpenSource/ish/blob/main/ishlib/vendor/kseq.mojo
# Adapted from Kseq crystal implementation by ssstadick

from memory import memcpy, UnsafePointer, Span, alloc
from collections.string import StringSlice, String
from blazeseq.utils import memchr


struct ASCIIString(Copyable, Equatable, Movable, Sized, Writable):
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
        for i in range(len(s)):
            self.ptr[i] = s.as_bytes()[i]
        self.size = UInt32(len(s))
        self.cap = UInt32(len(s))

    fn __init__(out self, s: Span[UInt8, MutExternalOrigin]):
        self.ptr = alloc[UInt8](len(s))
        for i in range(len(s)):
            self.ptr[i] = s[i]
        self.size = UInt32(len(s))
        self.cap = UInt32(len(s))

    fn __init__(out self, s: StringSlice[MutExternalOrigin]):
        self.ptr = alloc[UInt8](len(s))
        for i in range(len(s)):
            self.ptr[i] = s.as_bytes()[i]
        self.size = UInt32(len(s))
        self.cap = UInt32(len(s))

    fn __del__(deinit self):
        self.ptr.free()

    fn __copyinit__(out self, read other: Self):
        self.cap = other.cap
        self.size = other.size
        self.ptr = alloc[UInt8](Int(self.cap))
        memcpy(dest=self.ptr, src=other.ptr, count=Int(other.size))

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
    fn as_span(self) -> Span[UInt8, MutExternalOrigin]:
        return Span[UInt8, MutExternalOrigin](ptr=self.ptr, length=len(self))

    fn to_string(self) -> String:
        return String(StringSlice(unsafe_from_utf8=self.as_span()))

    @always_inline
    fn as_string_slice(self) -> StringSlice[MutExternalOrigin]:
        """Return StringSlice view of ASCIIString bytes."""
        return StringSlice(unsafe_from_utf8=self.as_span())

    fn __ne__(self, other: Self) -> Bool:
        """Compare two ASCIIStrings for inequality."""
        return not self.__eq__(other)

    fn write_to[w: Writer](self, mut writer: w) -> None:
        writer.write(self.as_string_slice())
