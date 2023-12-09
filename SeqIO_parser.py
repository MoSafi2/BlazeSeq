from Bio import SeqIO
from time import time_ns

count = 0
t1 = time_ns()
for record in SeqIO.parse("data/SRR4381936.fastq", "fastq"):
    list(record)
    count = count + 1

t2 = time_ns()

print((t2-t1)/1e9, " Seconds")
print(count, " recods")