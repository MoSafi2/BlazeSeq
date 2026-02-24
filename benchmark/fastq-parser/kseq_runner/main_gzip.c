/*
 * FASTQ parser benchmark runner using kseq with zlib gzip.
 * Reads a .fastq.gz path from argv[1], counts records and base pairs,
 * prints "records base_pairs". Link with -lz.
 *
 * Compile: gcc -O3 -o kseq_gzip_runner main_gzip.c -lz
 */

#include <stdio.h>
#include <stdlib.h>
#include <zlib.h>

/* kseq read callback: (stream, buf, size) -> bytes read; 0 = EOF, -1 = error */
static int gz_read(gzFile fp, unsigned char *buf, size_t size) {
    int n = gzread(fp, buf, (unsigned)size);
    if (n > 0) return n;
    if (gzeof(fp)) return 0;
    return -1;
}

#include "kseq.h"
KSEQ_INIT(gzFile, gz_read)

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "Usage: kseq_gzip_runner <path.fastq.gz>\n");
        return 1;
    }
    const char *path = argv[1];
    gzFile fp = gzopen(path, "rb");
    if (!fp) {
        fprintf(stderr, "kseq_gzip_runner: failed to open %s\n", path);
        return 1;
    }
    kseq_t *seq = kseq_init(fp);
    if (!seq) {
        fprintf(stderr, "kseq_gzip_runner: kseq_init failed\n");
        gzclose(fp);
        return 1;
    }
    long long total_reads = 0;
    long long total_base_pairs = 0;
    int64_t l;
    while ((l = kseq_read(seq)) >= 0) {
        total_reads++;
        total_base_pairs += (long long)l;
    }
    if (l < -1) {
        fprintf(stderr, "kseq_gzip_runner: parse error (code %lld)\n", (long long)l);
        kseq_destroy(seq);
        gzclose(fp);
        return 1;
    }
    kseq_destroy(seq);
    gzclose(fp);
    printf("%lld %lld\n", total_reads, total_base_pairs);
    return 0;
}
