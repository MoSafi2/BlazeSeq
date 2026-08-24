"""Synthetic FASTQ data generation for tests and benchmarks.

Deterministic generators producing valid 4-line FASTQ buffers or streaming
to a writer, with configurable read length, quality profile (Illumina-style
positional decay), and GC content.
"""

from blazeseq.fastq.quality_schema import _parse_schema
from blazeseq.io.writers import WriterBackend
from blazeseq.io.buffered import BufferedWriter


def compute_num_reads_for_size(
    target_size_bytes: Int,
    min_length: Int,
    max_length: Int,
) -> Int:
    """Compute the number of FASTQ reads needed to approximate a target size.

    Estimates bytes per record based on:
    - Header: @read_<padded_i>\\n (constant size: 6 + num_digits + 1 bytes)
    - Sequence line: read_len + 1 (newline)
    - Plus line: +\\n (2 bytes)
    - Quality line: read_len + 1 (newline)

    Uses average read length and constant header size (indices are zero-padded in `generate_synthetic_fastq_buffer`).

    Args:
        target_size_bytes: Target total size in bytes.
        min_length: Minimum read length per record.
        max_length: Maximum read length per record.

    Returns:
        Estimated number of reads needed to reach target_size_bytes.
    """
    if target_size_bytes <= 0:
        return 0
    var avg_read_length = (min_length + max_length) // 2
    # Initial header size estimate (e.g. 15 bytes for up to 100M reads)
    var header_est: Int = 15
    var bytes_per_record_est = header_est + 2 * avg_read_length + 4
    var num_reads_est = target_size_bytes // bytes_per_record_est
    if num_reads_est <= 0:
        return 0
    # Refine header size from estimated num_reads (zero-padded width)
    var num_digits: Int = 1
    if num_reads_est > 1:
        num_digits = String(num_reads_est - 1).byte_length()
    var header_size = 6 + num_digits + 1
    var bytes_per_record = header_size + 2 * avg_read_length + 4
    return target_size_bytes // bytes_per_record


def _validate_synthetic_fastq_args(
    num_reads: Int,
    min_length: Int,
    max_length: Int,
    min_phred: Int,
    max_phred: Int,
) raises:
    if (
        num_reads < 0
        or min_length < 0
        or max_length < 0
        or min_phred < 0
        or max_phred < 0
    ):
        raise Error("generate_synthetic_fastq_buffer: invalid arguments")
    if min_length > max_length:
        raise Error(
            "generate_synthetic_fastq_buffer: min_length must be <= max_length"
        )
    if min_phred > max_phred:
        raise Error(
            "generate_synthetic_fastq_buffer: min_phred must be <= max_phred"
        )


def _build_gc_biased_base_lut(gc_bias: Float32) -> List[Byte]:
    # Base LUT: 8 entries so index selects bases with configurable GC probability.
    # With gc_bias = 0.5: 2 G, 2 C, 2 A, 2 T (equal). Bias shifts the G/C vs A/T split.
    # We use 8 slots: floor(gc_bias * 8) slots get G/C, rest get A/T.
    # Slots alternate G/C and A/T to spread selection evenly across the LUT.
    var gc_slots = Int(gc_bias * 8.0 + 0.5)  # round to nearest
    if gc_slots < 0:
        gc_slots = 0
    if gc_slots > 8:
        gc_slots = 8
    var at_slots = 8 - gc_slots

    var base_lut = List[Byte](capacity=8)
    # Fill GC slots alternating G and C
    for k in range(gc_slots):
        if k % 2 == 0:
            base_lut.append(Byte(ord("G")))
        else:
            base_lut.append(Byte(ord("C")))
    # Fill AT slots alternating A and T
    for k in range(at_slots):
        if k % 2 == 0:
            base_lut.append(Byte(ord("A")))
        else:
            base_lut.append(Byte(ord("T")))
    return base_lut^


def _build_synthetic_fastq_record(
    i: Int,
    min_length: Int,
    max_length: Int,
    min_phred: Int,
    max_phred: Int,
    num_digits: Int,
    offset_int: Int,
    lower_int: Int,
    upper_int: Int,
    q_start: Int,
    q_range: Int,
    noise_amp: Int,
    base_lut: List[Byte],
) -> List[Byte]:
    # --- Read length ---
    var read_len: Int
    if max_length == min_length:
        read_len = min_length
    else:
        read_len = min_length + ((i * 31 + 7) % (max_length - min_length + 1))

    var record = List[Byte](capacity=2 * read_len + num_digits + 16)
    var newline = Byte(ord("\n"))
    var plus = Byte(ord("+"))

    # --- Header ---
    var index_str = String(i)
    while index_str.byte_length() < num_digits:
        index_str = "0" + index_str
    var header_str = "@read_" + index_str + "\n"
    record.extend(header_str.as_bytes())

    # --- Sequence line ---
    # We use a fast LCG per read seeded from i to get pseudorandom base indices.
    # Multiplier/increment from Knuth MMIX; state is 64-bit truncated to Int.
    var lcg_state: Int = (
        i * 6364136223846793005 + 1442695040888963407
    ) & 0x7FFFFFFFFFFFFFFF
    for _ in range(read_len):
        lcg_state = (
            lcg_state * 6364136223846793005 + 1442695040888963407
        ) & 0x7FFFFFFFFFFFFFFF
        var slot = (
            lcg_state >> 33
        ) % 8  # use upper bits for better distribution
        record.append(base_lut[slot])
    record.append(newline)

    # --- +\n ---
    record.append(plus)
    record.append(newline)

    # --- Quality line: positional decay + noise ---
    # At position p in [0, read_len-1]:
    #   mean_phred(p) = q_start - round(q_range * p / (read_len - 1))
    # For reads of length 1, mean = q_start throughout.
    # Noise: deterministic jitter via a second LCG stream (read + position mixed).
    var qrng: Int = (i * 2654435761 + 1013904223) & 0x7FFFFFFFFFFFFFFF
    var len_minus_1 = read_len - 1
    for p in range(read_len):
        # Mean quality at this position (linear decay)
        var mean_phred: Int
        if len_minus_1 == 0:
            mean_phred = q_start
        else:
            mean_phred = (
                q_start - (q_range * p + len_minus_1 // 2) // len_minus_1
            )  # integer rounding

        # Deterministic noise in [-noise_amp, +noise_amp]
        qrng = (qrng * 1664525 + 1013904223) & 0x7FFFFFFFFFFFFFFF
        var noise_raw = Int(
            (qrng >> 17) % (2 * noise_amp + 1)
        )  # [0, 2*noise_amp]
        var phred = mean_phred + noise_raw - noise_amp

        # Clamp to caller's [min_phred, max_phred]
        if phred < min_phred:
            phred = min_phred
        elif phred > max_phred:
            phred = max_phred

        # Convert to ASCII and clamp to schema range
        var ascii_int = offset_int + phred
        if ascii_int < lower_int:
            ascii_int = lower_int
        elif ascii_int > upper_int:
            ascii_int = upper_int
        record.append(Byte(ascii_int))
    record.append(newline)
    return record^


def generate_synthetic_fastq_buffer(
    num_reads: Int,
    min_length: Int,
    max_length: Int,
    min_phred: Int,
    max_phred: Int,
    quality_schema: String,
    gc_bias: Float32 = 0.5,
) raises -> List[Byte]:
    """Generate a contiguous in-memory FASTQ buffer with configurable read length and quality distribution.

    Read lengths are chosen deterministically in [min_length, max_length] (inclusive).
    Per-base Phred scores follow a positional decay model (high quality at 5' end, degrading
    toward 3' end), mimicking real Illumina quality profiles. Base composition follows a
    configurable GC content model with pseudorandom distribution.

    Args:
        num_reads: Number of FASTQ records to generate.
        min_length: Minimum sequence length per read (inclusive).
        max_length: Maximum sequence length per read (inclusive).
        min_phred: Minimum Phred score per base (inclusive) — used as the floor for 3' end quality.
        max_phred: Maximum Phred score per base (inclusive) — used as the ceiling for 5' end quality.
        quality_schema: Schema name (e.g. "sanger", "solexa", "illumina_1.8", "generic").
        gc_bias: Target GC fraction in [0.0, 1.0]. Default 0.5 (50% GC).
                 Values above 0.5 increase G/C frequency; below 0.5 increase A/T frequency.

    Returns:
        List[Byte] containing valid 4-line FASTQ data; pass to MemoryReader for parsing.

    Raises:
        Error: If num_reads < 0, min_length > max_length, or min_phred > max_phred.
    """
    if num_reads <= 0:
        return List[Byte]()
    _validate_synthetic_fastq_args(
        num_reads, min_length, max_length, min_phred, max_phred
    )

    var schema = _parse_schema(quality_schema)
    var offset_int = Int(schema.OFFSET)
    var lower_int = Int(schema.LOWER)
    var upper_int = Int(schema.UPPER)

    var capacity_estimate = num_reads * (max_length + 50)
    var out = List[Byte](capacity=capacity_estimate)

    var base_lut = _build_gc_biased_base_lut(gc_bias)

    # Header zero-padding width
    var num_digits: Int = 1
    if num_reads > 1:
        num_digits = String(num_reads - 1).byte_length()

    # Quality model parameters.
    # We model mean Phred as a linear decay from q_start (5' end) to q_end (3' end),
    # with per-base noise added on top. This matches the classic Illumina "ski slope" profile.
    #
    # q_start = max_phred (caller controls the 5' quality ceiling)
    # q_end   = min_phred (caller controls the 3' quality floor)
    # noise   = small jitter so consecutive bases aren't identical
    var q_start = max_phred  # Phred at position 0
    var q_end = min_phred  # Phred at last position
    var q_range = q_start - q_end  # total drop across the read (>= 0)

    # Noise amplitude: +/- noise_amp Phred units around the decayed mean.
    # We cap it so it can't push scores outside [min_phred, max_phred].
    var noise_amp = (q_range // 6) + 1  # ~15% of range, minimum 1

    for i in range(num_reads):
        var record = _build_synthetic_fastq_record(
            i=i,
            min_length=min_length,
            max_length=max_length,
            min_phred=min_phred,
            max_phred=max_phred,
            num_digits=num_digits,
            offset_int=offset_int,
            lower_int=lower_int,
            upper_int=upper_int,
            q_start=q_start,
            q_range=q_range,
            noise_amp=noise_amp,
            base_lut=base_lut,
        )
        out.extend(record[:])

    return out^


def generate_synthetic_fastq_to_writer[
    W: WriterBackend
](
    mut writer: BufferedWriter[W],
    num_reads: Int,
    min_length: Int,
    max_length: Int,
    min_phred: Int,
    max_phred: Int,
    quality_schema: String,
    gc_bias: Float32 = 0.5,
) raises:
    """Write synthetic FASTQ records directly to a buffered writer.

    Uses the same deterministic generation model as `generate_synthetic_fastq_buffer`,
    but streams records directly to the writer to avoid allocating one large output
    buffer.
    """
    if num_reads <= 0:
        return
    _validate_synthetic_fastq_args(
        num_reads, min_length, max_length, min_phred, max_phred
    )

    var schema = _parse_schema(quality_schema)
    var offset_int = Int(schema.OFFSET)
    var lower_int = Int(schema.LOWER)
    var upper_int = Int(schema.UPPER)
    var base_lut = _build_gc_biased_base_lut(gc_bias)

    # Header zero-padding width
    var num_digits: Int = 1
    if num_reads > 1:
        num_digits = String(num_reads - 1).byte_length()

    # Quality model parameters.
    # We model mean Phred as a linear decay from q_start (5' end) to q_end (3' end),
    # with per-base noise added on top. This matches the classic Illumina "ski slope" profile.
    #
    # q_start = max_phred (caller controls the 5' quality ceiling)
    # q_end   = min_phred (caller controls the 3' quality floor)
    # noise   = small jitter so consecutive bases aren't identical
    var q_start = max_phred  # Phred at position 0
    var q_end = min_phred  # Phred at last position
    var q_range = q_start - q_end  # total drop across the read (>= 0)

    # Noise amplitude: +/- noise_amp Phred units around the decayed mean.
    # We cap it so it can't push scores outside [min_phred, max_phred].
    var noise_amp = (q_range // 6) + 1  # ~15% of range, minimum 1

    for i in range(num_reads):
        var record = _build_synthetic_fastq_record(
            i=i,
            min_length=min_length,
            max_length=max_length,
            min_phred=min_phred,
            max_phred=max_phred,
            num_digits=num_digits,
            offset_int=offset_int,
            lower_int=lower_int,
            upper_int=upper_int,
            q_start=q_start,
            q_range=q_range,
            noise_amp=noise_amp,
            base_lut=base_lut,
        )
        writer.write_bytes(record)
