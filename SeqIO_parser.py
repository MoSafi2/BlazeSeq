from Bio import SeqIO
from time import time_ns

count = 0
bases = 0
t1 = time_ns()
for record in SeqIO.parse("data/9_Swamp_S2B_rbcLa_2019_minq7.fastq", "fastq"):
    list(record)
    count = count + 1
    bases = bases + len(record)


t2 = time_ns()

print((t2-t1)/1e9, "Seconds")
print(count, "records")
print(bases, "total bases")