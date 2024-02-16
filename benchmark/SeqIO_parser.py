from Bio import SeqIO
from time import time_ns
import sys



count = 0
bases = 0
t1 = time_ns()
for record in SeqIO.parse(sys.argv[1], "fastq"):
    list(record)
    count = count + 1
    bases = bases + len(record)


t2 = time_ns()

print((t2-t1)/1e9, "Seconds")
print(count, "records")
print(bases, "total bases")
