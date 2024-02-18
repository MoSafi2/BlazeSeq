use needletail::FastxReader;
use std::hint::black_box;

pub fn process_records(mut reader: Box<dyn FastxReader>) -> (usize, usize) {
    let mut slen = 0usize;
    let mut qlen = 0usize;

    loop {
        match reader.next() {
            Some(record) => {
                let seqrec = record.expect("invalid record");
                slen += black_box(seqrec.seq().len());
                qlen += black_box(seqrec.qual().map_or(0, |qual| qual.len()));
            }
            None => break,
        }
    }

    (slen, qlen)
}
