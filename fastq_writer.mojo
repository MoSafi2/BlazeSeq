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

    fn get_read(inout self, read: FastqRecord, end: Bool = False) raises:
        var in_read = read

        # Goind to town with the record applying all kinds of transformations
        #Transformation could be applied through a seperate entity which can read, organise, and schedule transformations
        in_read.trim_record()

        if self._buffer_position + in_read.total_length > self._BUF_SIZE:
            ## Flushing out the write buffer, starting a new record
            self.flush_buffer(self._buffer_position)

        write_to_buff(
            in_read.wirte_record(),
            self._write_buffer,
            self._buffer_position,
        )
        self._buffer_position += in_read.total_length

    @always_inline
    fn flush_buffer(inout self, length: Int) raises:

        var out = self._write_buffer
        let out_string = String(out._steal_ptr(), length)
        _ = self._out_handle.seek(self._file_position)
        self._out_handle.write(out_string)
        self._file_position += length
        
        #No new buffer is created, Just the _buff_pos is resetted
        self._buffer_position = 0


    fn __len__(self) -> Int:
        return 15

    fn __str__(self) -> String:
        return "ssdd"
