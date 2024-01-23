from helpers import *
from record_coord import RecordCoord


alias new_line: Int = ord("\n")
alias read_header: Int = ord("@")
alias quality_header: Int = ord("+")


struct FastqParser:
    var _file_handle: FileHandle
    var _BUF_SIZE: Int
    var _current_chunk: Tensor[DType.int8]
    var _file_pos: Int
    var _chunk_last_index: Int
    var _chunk_pos: Int

    fn __init__(
        inout self, path: String, BUF_SIZE: Int = 64 * 1024
    ) raises -> None:
        # Initailizing starting conditions
        self._BUF_SIZE = BUF_SIZE
        self._file_pos = 0
        self._chunk_pos = 0
        self._chunk_last_index = 0

        # Reading, Processing 1st chunk
        self._file_handle = open(path, "r")
        self._current_chunk = read_bytes(
            self._file_handle, self._file_pos, self._BUF_SIZE
        )

        self.get_last_index(self._BUF_SIZE)
        self._file_pos += self._chunk_last_index

    fn next(inout self) raises -> RecordCoord:
        let read: RecordCoord

        self.check_EOF()

        if self._chunk_pos >= self._chunk_last_index:
            self.fill_buffer()

        read = self.parse_read(self._current_chunk, self._chunk_pos)
        read.validate(self._current_chunk)
        self._chunk_pos += (read.end - read.SeqHeader).to_int() + 1
        return read

    fn check_EOF(self) raises:
        if self._current_chunk.num_elements() == 0:
            raise Error("EOF")

    fn fill_buffer(inout self) raises:
        self._current_chunk = read_bytes(
            self._file_handle, self._file_pos, self._BUF_SIZE
        )
        self.get_last_index(self._BUF_SIZE)
        self._chunk_pos = 0
        self._file_pos += self._chunk_last_index

    fn parse_read(self, chunk: Tensor[DType.int8], start: Int) -> RecordCoord:
        var T = Tensor[DType.int32](5)
        T[0] = start
        for i in range(1, 5):
            T[i] = find_chr_next_occurance_simd(chunk, new_line, T[i - 1].to_int() + 1)
        return RecordCoord(T[0], T[1], T[2], T[3], T[4])

    fn get_last_index(inout self, num_elements: Int):
        if self._current_chunk.num_elements() == num_elements:
            self._chunk_last_index = find_last_read_header(self._current_chunk)
        else:
            self._chunk_last_index = self._current_chunk.num_elements()
