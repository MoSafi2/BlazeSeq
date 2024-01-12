from tensor import Tensor
from fastq_record import FastqRecord
from helpers import *

struct FastqWriter(Sized, Stringable):
    var _out_path: String
    var _out_handle: FileHandle
    var _BUF_SIZE: Int
    var _write_buffer: Tensor[DType.int8]
    var _buffer_position: Int
    var _file_position: UInt64

    fn __init__(inout self, out_path: String, buf_size: Int) raises:
        self._out_path = out_path
        self._out_handle = open(out_path, "w")
        self._BUF_SIZE = buf_size
        self._write_buffer = Tensor[DType.int8](buf_size)
        self._buffer_position = 0
        self._file_position = 0


    fn get_read(inout self, read: FastqRecord, last_read: Bool = False) raises:

        var in_read = read
        in_read.trim_record()
        
        self._buffer_position += in_read.total_length

        if self._buffer_position > self._BUF_SIZE:
            
            ## Flushing out the write buffer
            # Take out to a seperate function
            var out = self._write_buffer
            let num = out.num_elements()
            let out_string = String(out._steal_ptr(), num)
            _ = self._out_handle.seek(self._file_position)
            self._out_handle.write(out_string)
            self._file_position += num

            ## Starting a new buffer
            self._write_buffer = Tensor[DType.int8](self._BUF_SIZE)
            self._buffer_position = 0
        
        if last_read:
            
            var out = self._write_buffer
            let num = out.num_elements()
            let out_string = String(out._steal_ptr(), num)
            _ = self._out_handle.seek(self._file_position)
            self._out_handle.write(out_string)
            self._file_position += num

            return



        write_to_buff(in_read.__concat_record(), self._write_buffer, self._buffer_position)

    fn __len__(self) -> Int:
        return 15

    fn __str__(self) -> String:
        return "ssdd"

