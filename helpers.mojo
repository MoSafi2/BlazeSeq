@always_inline
fn next_line_simd(borrowed s: Tensor[DType.int8], start: Int = 0) -> Tensor[DType.int8]:
    alias simd_width: Int = simdwidthof[DType.int8]()

    for nv in range(start, s.num_elements(), simd_width):
        let simd_vec = s.simd_load[simd_width](nv)
        let bool_vec = simd_vec == 10
        if bool_vec.reduce_or():
            for i in range(len(bool_vec)):
                if bool_vec[i]:
                    return slice_tensor(s, start, nv + i)

    # for n in range(simd_width*(s.num_elements()//simd_width), s.num_elements()):
    #     let simd_vec = s.simd_load[simd_width](n)
    #     let bool_vec = simd_vec == 10
    #     if bool_vec.reduce_or():
    #         for i in range(len(bool_vec)):
    #             if bool_vec[i]:
    #                 return slice_tensor(s, start, n+i)

    return Tensor[DType.int8](0)


@always_inline
fn slice_tensor[T: DType](borrowed t: Tensor[T], start: Int, end: Int) -> Tensor[T]:
    var x = Tensor[T](end - start)
    for i in range(start, end):
        x[i - start] = t[i]
    return x


@always_inline
fn read_bytes(
    borrowed handle: FileHandle, beginning: UInt64, length: Int64
) raises -> Tensor[DType.int8]:
    _ = handle.seek(beginning)
    return handle.read_bytes(length)
