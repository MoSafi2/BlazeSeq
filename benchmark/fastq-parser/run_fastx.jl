#!/usr/bin/env julia
# FASTQ parser benchmark runner using FASTX.jl.
# Reads path from argv[1], counts records and base pairs, prints "records base_pairs".
# Run: julia --project=benchmark/fastq-parser benchmark/fastq-parser/run_fastx.jl <path.fastq>

using FASTX

function main()
    if length(ARGS) < 1
        println(stderr, "Usage: run_fastx.jl <path.fastq>")
        exit(1)
    end
    path = ARGS[1]
    total_reads = 0
    total_base_pairs = 0
    try
        reader = FASTQ.Reader(open(path))
        for record in reader
            total_reads += 1
            total_base_pairs += length(sequence(record))
        end
        close(reader)
    catch e
        println(stderr, "run_fastx.jl: error: ", e)
        exit(1)
    end
    println(total_reads, " ", total_base_pairs)
end

main()
