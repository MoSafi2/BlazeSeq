alias fnv_32_prime: UInt32 = 0x01000193
alias fnv_32_offset_bassis: UInt32 = 0x811C9DC5
alias fnv_64_prime = 0x100000001B3
alias fnv_64_offset_bassis = 0xCBF29CE484222325


@always_inline
fn fnv1a32(s: String) -> UInt32:
    var hash = fnv_32_offset_bassis
    let buffer = s._as_ptr().bitcast[DType.uint8]()
    for i in range(len(s)):
        hash ^= buffer.load(i).cast[DType.uint32]()
        hash *= fnv_32_prime
    return hash


@always_inline
fn fnv1a64(s: String) -> UInt64:
    var hash: UInt64 = fnv_64_offset_bassis
    let buffer = s._as_ptr().bitcast[DType.uint8]()
    for i in range(len(s)):
        hash ^= buffer.load(i).cast[DType.uint64]()
        hash *= fnv_64_prime
    return hash
