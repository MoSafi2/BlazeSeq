/*
 * FASTQ parser benchmark runner using kseq (plain FILE, no zlib).
 * Reads path from argv[1], counts records and base pairs, prints "records base_pairs".
 */

#include <stdio.h>
#include <stdlib.h>

/* Wrapper so kseq's read callback matches: (stream, buf, size) -> bytes read; 0 = EOF, -1 = error */
static int file_read(FILE *fp, unsigned char *buf, size_t size) {
    size_t n = fread(buf, 1, size, fp);
    if (n > 0) return (int)n;
    return feof(fp) ? 0 : -1;
}

#include "kseq.h"
KSEQ_INIT(FILE *, file_read)

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "Usage: kseq_runner <path.fastq>\n");
        return 1;
    }
    const char *path = argv[1];
    FILE *fp = fopen(path, "r");
    if (!fp) {
        fprintf(stderr, "kseq_runner: failed to open %s\n", path);
        return 1;
    }
    kseq_t *seq = kseq_init(fp);
    if (!seq) {
        fprintf(stderr, "kseq_runner: kseq_init failed\n");
        fclose(fp);
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
        fprintf(stderr, "kseq_runner: parse error (code %lld)\n", (long long)l);
        kseq_destroy(seq);
        fclose(fp);
        return 1;
    }
    kseq_destroy(seq);
    fclose(fp);
    printf("%lld %lld\n", total_reads, total_base_pairs);
    return 0;
}
