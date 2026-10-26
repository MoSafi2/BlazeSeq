# Adapted from: https://github.com/BioRadOpenSource/ish/blob/main/ishlib/vendor/kseq.mojo
# Adapted from Kseq crystal implementation by ssstadick

from std.memory.alloc import unsafe_alloc
from std.memory import unsafe_memcpy, Pointer
from std.collections.string import StringSpan, String
from blazeseq.utils import memchr


struct BString(Copyable, Equatable, Movable, Sized, Writable):
    """ByteString is a mutable sequence of bytes. it does not ensure any encoding of the bytes.
    """

    # TODO: add address_space
    var size: UInt32
    var cap: UInt32
    var ptr: Pointer[UInt8, MutUntrackedOrigin]

    def __init__(out self, capacity: UInt = 0):
        self.ptr = unsafe_alloc[UInt8](0)
        self.size = 0
        self.cap = 0
        if capacity > 0:
            self.resize(UInt32(capacity))

    def __init__(out self, s: String):
        var n = s.byte_length()
        self.ptr = unsafe_alloc[UInt8](n)
        unsafe_memcpy(dest=self.ptr, src=s.unsafe_ptr(), count=n)
        self.size = UInt32(n)
        self.cap = UInt32(n)

    def __init__(out self, s: Span[UInt8, _]):
        self.ptr = unsafe_alloc[UInt8](len(s))
        unsafe_memcpy(dest=self.ptr, src=s.unsafe_ptr(), count=len(s))
        self.size = UInt32(len(s))
        self.cap = UInt32(len(s))

    def __init__(out self, s: StringSpan[_]):
        var n = s.byte_length()
        self.ptr = unsafe_alloc[UInt8](n)
        unsafe_memcpy(dest=self.ptr, src=s.unsafe_ptr(), count=n)
        self.size = UInt32(n)
        self.cap = UInt32(n)

    @doc_hidden
    @inline(.always)
    def __deinit__(deinit self):
        self.ptr.unsafe_free()

    @doc_hidden
    @inline(.always)
    def __init__(out self, *, copy: Self):
        self.cap = copy.cap
        self.size = copy.size
        self.ptr = unsafe_alloc[UInt8](Int(self.cap))
        unsafe_memcpy(dest=self.ptr, src=copy.ptr, count=Int(copy.size))

    @inline(.always)
    def __getitem__[I: Indexer](self, idx: I) -> UInt8:
        return self.ptr[unsafe_offset=idx]

    def __getitem__(ref[_] self, slice: Slice) -> Span[UInt8, origin_of(self)]:
        var start = slice.start.or_else(0)
        var end = slice.end.or_else(len(self))
        var length = end - start
        return Span[UInt8, origin_of(self)](
            unsafe_ptr=self.ptr.unsafe_mut_cast[origin_of(self).mut]()
            .unsafe_origin_cast[origin_of(self)]()
            .unsafe_offset(start),
            length=length,
        )

    @inline(.always)
    def __setitem__[I: Indexer](mut self, idx: I, val: UInt8):
        self.ptr[unsafe_offset=idx] = val

    @inline(.always)
    def __len__(self) -> Int:
        return Int(self.size)

    @inline(.always)
    def __eq__(self, other: Self) -> Bool:
        if len(self) != len(other):
            return False
        for i in range(len(self)):
            if self[i] != other[i]:
                return False
        return True

    # TODO: rename offset
    @inline(.always)
    def addr[I: Indexer](mut self, i: I) -> Pointer[UInt8, MutUntrackedOrigin]:
        return self.ptr.unsafe_offset(i)

    @staticmethod
    @inline(.always)
    def _roundup32(val: UInt32) -> UInt32:
        var x = val
        x -= 1
        x |= x >> 1
        x |= x >> 2
        x |= x >> 4
        x |= x >> 8
        x |= x >> 16
        return x + 1

    @inline(.always)
    def clear(mut self):
        self.size = 0

    @inline(.always)
    def reserve(mut self, cap: UInt32):
        if cap < self.cap:
            return
        self.cap = cap
        var new_data = unsafe_alloc[UInt8](Int(self.cap))
        unsafe_memcpy(dest=new_data, src=self.ptr, count=len(self))
        self.ptr.unsafe_free()
        self.ptr = new_data

    @inline(.always)
    def resize(mut self, size: UInt32):
        var old_size = self.size
        self.size = size
        if self.size <= self.cap:
            return
        self.cap = Self._roundup32(self.size)
        var new_data = unsafe_alloc[UInt8](Int(self.cap))
        unsafe_memcpy(dest=new_data, src=self.ptr, count=Int(old_size))

        self.ptr.unsafe_free()
        self.ptr = new_data

    @inline(.always)
    def as_span(ref[_] self) -> Span[UInt8, origin_of(self)]:
        return Span[UInt8, origin_of(self)](
            unsafe_ptr=self.ptr.unsafe_mut_cast[
                origin_of(self).mut
            ]().unsafe_origin_cast[origin_of(self)](),
            length=len(self),
        )

    def to_string(self) -> String:
        return String(StringSpan(unsafe_from_utf8=self.as_span()))

    @inline(.always)
    def as_string_slice(ref[_] self) -> StringSpan[origin=origin_of(self)]:
        """Return StringSpan view of BString bytes."""
        return StringSpan[origin=origin_of(self)](
            unsafe_from_utf8=self.as_span()
        )

    @inline(.always)
    def __ne__(self, other: Self) -> Bool:
        """Compare two ASCIIStrings for inequality."""
        return not self.__eq__(other)

    @inline(.always)
    def write_to[w: Writer](self, mut writer: w) -> None:
        writer.write(self.as_string_slice())

    @inline(.always)
    def extend(mut self, src: Span[UInt8, _]):
        var needed = self.size + UInt32(len(src))
        if needed > self.cap:
            self.reserve(Self._roundup32(needed))
        unsafe_memcpy(
            dest=self.ptr.unsafe_offset(Int(self.size)),
            src=src.unsafe_ptr(),
            count=len(src),
        )
        self.size = needed

    @inline(.always)
    def extend(mut self, src: List[UInt8]):
        var needed = self.size + UInt32(len(src))
        if needed > self.cap:
            self.reserve(Self._roundup32(needed))
        unsafe_memcpy(
            dest=self.ptr.unsafe_offset(Int(self.size)),
            src=src.unsafe_ptr(),
            count=len(src),
        )
        self.size = needed

    @inline(.always)
    def extend(mut self, imm src: BString):
        var needed = self.size + src.size
        if needed > self.cap:
            self.reserve(Self._roundup32(needed))
        unsafe_memcpy(
            dest=self.ptr.unsafe_offset(Int(self.size)),
            src=src.ptr,
            count=Int(src.size),
        )
        self.size = needed
