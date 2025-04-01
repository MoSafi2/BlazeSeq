from sys.ffi import (
    c_char,
    c_int,
    c_size_t,
    OpaquePointer,
    external_call,
    UnsafePointer,
)
import os.fstat
from utils import StringSlice
from benchmark import QuickBench, keep
from sys.info import simdwidthof

alias PORT_READ = 1
alias MAP_PRIVATE = 2
alias O_RDONLY = 0
alias MAP_FAILED = -1
alias MADV_SEQUENTIAL = 2
alias MAP_HUGETLB = 0x40000  # Add hugepage flag
alias MAP_HUGE_2MB = 0x200000  # For 2MB hugepages (21 << MAP_HUGE_SHIFT)
alias MAP_HUGE_1GB = 0x400000  # For 1GB hugepages (30 << MAP_HUGE_SHIFT)
alias STEP = 64 * 1024
alias SIMD_STEP = simdwidthof[UInt8]()

fn main() raises:
    file = "data/SRR4381933_1.fastq"
    fs = open(file, "r")
    var stat = fstat.stat(file)
    #mmap(stat, fs)
    read_file(stat, fs)


fn read_file(stat: fstat.stat_result, fs: FileHandle) raises:
    var n = 0
    var ptr = UnsafePointer[UInt8]().alloc(STEP)
    while n < stat.st_size - STEP:
        _ = fs.read(ptr, STEP)
        n += STEP
        keep(ptr)
    _ = ptr


fn mmap(stat: fstat.stat_result, fs: FileHandle):
    var flags = PORT_READ | MAP_HUGETLB | MAP_HUGE_2MB
    #var flags = PORT_READ
    var hugepage_size = 2 * 1024 * 1024  # 1GBMB
    var aligned_size = (
        (stat.st_size + hugepage_size - 1) // hugepage_size
    ) * hugepage_size
    #var aligned_size = stat.st_size
    var maped_file = external_call[
        "mmap",
        UnsafePointer[UInt8],
        OpaquePointer,
        c_size_t,
        c_int,
        c_int,
        c_int,
        c_size_t,
    ](
        OpaquePointer(),
        aligned_size,
        flags,
        MAP_PRIVATE,
        fs._get_raw_fd(),
        0,
    )

    var madvise_ret = external_call[
        "madvise", c_int, UnsafePointer[UInt8], c_size_t, c_int
    ](maped_file, stat.st_size, MADV_SEQUENTIAL)

    var n = 0
    while n < stat.st_size - SIMD_STEP * 2:
        ld = maped_file.load[width=SIMD_STEP * 2](n)
        keep(ld)
        n += SIMD_STEP * 2
