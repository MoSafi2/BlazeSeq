# Architecture of the MojoFastqParser

How I image it now, the parser should be consistent of multiple structs that each do one job quite well.

+ FastSingleThreaded
+ NormalSingleThreaded
+ FastMultiThreaded
+ NomralMultiThreaded

## Main points

+ Open/Closed: the parser should always accept a list of Analyszers where it can pass in the read in unmutable reference, the parsers would do smthing with it before returing it to the user
  + The Parser should be oblivious to those analysers at all time.
  + Parsers should support sum operators so that they can be spun during multi-threaded operations and aggreagte results independently before being summed at the end
+ Could Multithreaded be working in a stateful way?

## Comparison with other Parsers

+ Julia: Fastx Parser
+ Python: SeqIO
+ Rust: SeqIO?
