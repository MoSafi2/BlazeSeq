import sys
from blazeseq.iostream import InnerBuffer
from testing import assert_true, assert_raises

def test_init():
    buffer = InnerBuffer(10)
    assert_true(buffer._len == 10)

def test_get_set_item():
    var buffer = InnerBuffer(5)
    for i in range(5):
        buffer[i] = UInt8(i * 2)
    for i in range(5):
        assert_true(buffer[i] ==  UInt8(i * 2))

def test_get_slice():
    var buffer = InnerBuffer(6)
    for i in range(6):
        buffer[i] = UInt8(i + 1)  # Fill with 1..6
    slice = buffer[1:4]
    assert_true(slice._len == 3)
    assert_true(slice[0] == 2)
    assert_true(slice[1] == 3)
    assert_true(slice[2] == 4)

def test_out_of_bounds_access():
    var buffer = InnerBuffer(3)
    with assert_raises():
        _ = buffer[5]

    with assert_raises():
        buffer[4] = 10

    with assert_raises():
        _ = buffer[1:5]

def test_realloc():
    var buffer = InnerBuffer(3)
    buffer[0] = 10
    buffer[1] = 20
    buffer[2] = 30

    resized = buffer._realloc(6)
    assert_true( resized == True)
    assert_true(buffer._len == 6)
    assert_true(buffer[0] == 10)
    assert_true(buffer[1] == 20)
    assert_true(buffer[2] == 30)

    buffer[3] = 40
    buffer[4] = 50
    buffer[5] = 60
    assert_true(buffer[3] == 40)
    assert_true(buffer[4] == 50)
    assert_true(buffer[5] == 60)


def main():
    test_init()
    test_get_set_item()
    test_get_slice()
    test_out_of_bounds_access()
    test_realloc()
    print("All tests passed.")
