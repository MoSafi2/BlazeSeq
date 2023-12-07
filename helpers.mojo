

@value
struct IntableString(Intable, Stringable):

    var data: String

    fn __str__(self) -> String:
        return self.data
    
    fn __int__(self) -> Int:
        let data_n = len(self.data)
        var n: Int = 0
        for i in range(0, data_n):
            let chr: Int = ord(self.data[i]) -48
            n = n + chr * (10**(data_n-(i+1)))
        return n





