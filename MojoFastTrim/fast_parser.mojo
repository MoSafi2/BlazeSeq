from MojoFastTrim.helpers import get_next_line_index, read_bytes, find_last_read_header
from MojoFastTrim import RecordCoord, Stats

alias T = DType.int8


struct FastParser:
    var _file_handle: FileHandle
    var _BUF_SIZE: Int
    var _current_chunk: Tensor[DType.int8]
    var _file_pos: Int
    var _chunk_last_index: Int
    var _chunk_pos: Int
    var parsing_stats: Stats

    fn __init__(inout self, path: String, BUF_SIZE: Int = 64 * 1024) raises -> None:
        # Initailizing starting conditions
        self._BUF_SIZE = BUF_SIZE
        self._file_pos = 0
        self._current_chunk = Tensor[T](0)
        self._chunk_last_index = 0
        self._chunk_pos = 0
        self.parsing_stats = Stats()

        self._file_handle = open(path, "r")
        self.fill_buffer()
        # _ = self._header_parser()

    fn parse_all(inout self) raises:
        while True:
            self.parse_chunk(self._current_chunk, start=0, end=self._chunk_last_index)
            try:
                self.fill_buffer()
                self.check_EOF()
            except:
                break

    @always_inline
    fn next(inout self) raises -> RecordCoord:
        let read: RecordCoord

        self.check_EOF()
        if self._chunk_pos >= self._chunk_last_index:
            self.fill_buffer()

        read = self.parse_read(self._chunk_pos, self._current_chunk)
        read.validate(self._current_chunk)
        self.parsing_stats.tally(read)
        return read

    # Internal counter is used to enable Multi-threading later
    @always_inline
    fn parse_chunk(inout self, chunk: Tensor[DType.int8], start: Int, end: Int) raises:
        let read: RecordCoord
        var pos = 0
        while True:
            try:
                read = self.parse_read(pos, chunk)
                self.parsing_stats.tally(read)
            except:
                raise Error("failed read")
            if pos >= end - start:
                break

    @always_inline
    fn check_EOF(self) raises:
        if self._current_chunk.num_elements() == 0:
            raise Error("EOF")

    @always_inline
    fn fill_buffer(inout self) raises:
        self._current_chunk = read_bytes(
            self._file_handle, self._file_pos, self._BUF_SIZE
        )
        self._chunk_last_index = find_last_read_header(self._current_chunk)
        if self._current_chunk.num_elements() < self._BUF_SIZE:
            self._chunk_last_index = self._current_chunk.num_elements()
            if self._chunk_last_index <= 1:
                raise Error("EOF")
        self._chunk_pos = 0
        self._file_pos += self._chunk_last_index

    @always_inline
    fn parse_read(
        self, inout pos: Int, chunk: Tensor[DType.int8]
    ) raises -> RecordCoord:
        let start = pos
        let line1 = get_next_line_index(chunk, pos)
        let line2 = get_next_line_index(chunk, line1 + 1)
        let line3 = get_next_line_index(chunk, line2 + 1)
        let line4 = get_next_line_index(chunk, line3 + 1)
        pos = line4 + 1
        return RecordCoord(start, line1, line2, line3, line4)

    @always_inline
    fn set_last_index(inout self, num_elements: Int):
        if self._current_chunk.num_elements() == num_elements:
            self._chunk_last_index = find_last_read_header(self._current_chunk)
        else:
            self._chunk_last_index = self._current_chunk.num_elements()
