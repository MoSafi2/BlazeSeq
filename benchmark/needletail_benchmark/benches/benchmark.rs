use criterion::{black_box, criterion_group, criterion_main, Criterion};
use needletail::parse_fastx_file;
use rust_parser::process_records;

fn benchmark_needletail(c: &mut Criterion) {
    c.bench_function("needletail 40k:", |b| {
        b.iter(|| {
            let reader =
                parse_fastx_file("9_Swamp_S2B_rbcLa_2019_minq7.fastq").expect("valid path/file");
            black_box(process_records(black_box(reader)));
        });
    });
}

criterion_group!(benches, benchmark_needletail);
criterion_main!(benches);
