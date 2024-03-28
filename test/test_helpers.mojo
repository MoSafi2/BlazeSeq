from tensor import Tensor
from random.random import rand
from testing.testing import assert_true, assert_false, assert_equal, assert_not_equal
from blazeseq.helpers import *

alias T = DType.int8


fn test_tensor[T: DType](num_ele: Int) -> Tensor[T]:
    var test_tensor = Tensor[T](num_ele)
    rand[T](test_tensor._ptr, num_ele)
    return test_tensor


fn test_find_chr_next_occurance_simd() raises:
    var in_tensor = Tensor[T](50)
    in_tensor[40] = 10

    var result_happy = find_chr_next_occurance_simd(in_tensor, chr=10, start=0)
    var result_not_found = find_chr_next_occurance_simd(in_tensor, chr=80, start=0)

    assert_equal(result_happy, 40)
    assert_equal(result_not_found, -1)


fn test_find_chr_next_occurance_simd_short_tensor() raises:
    var in_tesnor = Tensor[T](5)
    in_tesnor[4] = 64
    var result_happy = find_chr_next_occurance_simd(in_tesnor, 64)
    var result_not_found = find_chr_next_occurance_simd(in_tesnor, 10)

    assert_equal(result_happy, 4)
    assert_equal(result_not_found, -1)


# fn test_find_chr_all_occurances_short_tensor() raises:
#     var in_tesnor = Tensor[T](5)
#     in_tesnor[1] = 10
#     in_tesnor[4] = 10
#     var x = find_chr_all_occurances(in_tesnor, 10)
#     assert_equal(len(x), 2)
#     assert_equal(x[0], 1)
#     assert_equal(x[1], 4)


# fn test_find_chr_all_occurances_long_tensor() raises:
#     var in_tensor = Tensor[T](500)
#     in_tensor[100] = 10
#     in_tensor[105] = 10
#     in_tensor[300] = 10
#     in_tensor[200] = 10
#     in_tensor[201] = 10

#     var x = find_chr_all_occurances(in_tensor, 10)
#     assert_equal(len(x), 5)
#     assert_equal(x[0], 100)
#     assert_equal(x[1], 105)
#     assert_equal(x[2], 200)
#     assert_equal(x[3], 201)
#     assert_equal(x[4], 300)

#     var x2 = find_chr_all_occurances(in_tensor, 0)
#     assert_equal(len(x2), 495)


fn test_find_last_read_header() raises:
    var in_tensor = Tensor[T](50)
    in_tensor[30] = 10
    in_tensor[31] = 64
    in_tensor[44] = 64
    in_tensor[46] = 64
    in_tensor[35] = 64

    var last = find_last_read_header(in_tensor)
    assert_equal(last, 31)


fn test_find_last_read_header_last() raises:
    var in_tensor = Tensor[T](50)
    in_tensor[49] = 64
    in_tensor[48] = 10

    var last = find_last_read_header(in_tensor)
    assert_equal(last, 49)


fn main() raises:
    test_find_chr_next_occurance_simd()
    test_find_chr_next_occurance_simd_short_tensor()
    # test_find_chr_all_occurances_short_tensor()
    # test_find_chr_all_occurances_long_tensor()
    test_find_last_read_header()
    test_find_last_read_header_last()
