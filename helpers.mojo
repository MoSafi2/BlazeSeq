fn slice_tensor[T:DType](borrowed t: Tensor[T], start: Int, end: Int) -> Tensor[T]:
    var x = Tensor[T](end-start)
    for i in range(start, end):
        x[i - start] = t[i]
    return x 
