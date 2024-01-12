
"find next occurance of '\n' in randint Tensor with following lengths"

time: ns
"50"
"Iter: 666"
"SIMD: 702"

"1024"
"Iter: 1039"
"SIMD: 679"


"500_000"
"iter: 143_886"
"SIMD: 64_857"


"4MB"
"SIMD:551_820"
"Iter: 1_204_520"

"SIMD has 2x advatage at large tensors > 1_000 while at v. small Tensors it has same overhead as Iter."

-----------------

#Tensor Slicing
"Copying slices from large tensor to smaller tensors"
"Slice size - time (ns)"

"Slice size: 50"
"Iter: 662"
"SIMD: 629"

"Slice size: 1024"
"iter: 1133"
"SIMD: 1045"

"10_000"
"Iter: 9598"
"SIMD: 2600"

"500_000"
"Iter: 214_067 "
"SIMD: 203_450"

"4MB"
"Iter: 1_645_563"
"SIMD: 1_225_787"

"64 MB Approx"
"Iter: 24_622_506"
"SIMD: 18_585_364"

"2GB Approbx"
"Iter: 843_928_972"
"SIMD: 696_846_972"

"SIMD has 20-30% advantage starting from 1 MB tensor"