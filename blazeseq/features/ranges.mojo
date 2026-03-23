# ---------------------------------------------------------------------------
# Position — 1-based coordinate (aligned with noodles_core::Position)
# ---------------------------------------------------------------------------


struct Position(
    Comparable, Copyable, Equatable, Hashable, TrivialRegisterPassable
):
    """1-based genomic coordinate (aligned with noodles_core::Position).

    Valid positions are >= 1. Position 0 is invalid.
    BED stores 0-based half-open; convert when exposing via start_position/interval.
    """

    var _value: UInt64
    comptime MIN_VALUE: UInt64 = 1
    comptime MAX_VALUE: UInt64 = UInt64.MAX
    comptime UNSET: UInt64 = 0

    def __init__(out self, value: UInt64) raises:
        if value < 1:
            raise Error("Position must be >= 1")
        self._value = value


    @always_inline
    def __init__(out self, value: UInt64, _unsafe: Bool):
        """Internal: use when value is already known to be >= 1 (e.g. from conversion).
        """
        # Keep 1-based invariant: do not store 0
        self._value = value

    @always_inline
    def get(self) -> UInt64:
        """Return the raw 1-based coordinate."""
        return self._value

    @always_inline
    def __eq__(self, other: Self) -> Bool:
        return self._value == other._value

    @always_inline
    def __lt__(self, other: Self) -> Bool:
        return self._value < other._value


# ---------------------------------------------------------------------------
# Interval — 1-based closed [start, end] (aligned with noodles_core::Interval)
# ---------------------------------------------------------------------------


struct Interval(Copyable, Equatable, TrivialRegisterPassable):
    """1-based closed genomic interval [start, end] (modeled on noodles_core::region::Interval).

    Both start and end are 1-based and inclusive. Supports contains(), intersects(), length().
    """

    var _start: Position
    var _end: Position

    def __init__(out self, start: Position, end: Position) raises:
        if start.get() > end.get():
            raise Error("Interval start must be <= end")
        self._start = start
        self._end = end

    @always_inline
    def __init__(out self, start: Position, end: Position, _unsafe: Bool):
        """Internal: use when start <= end is already guaranteed."""
        self._start = start
        self._end = end

    @always_inline
    def start(self) -> Position:
        return self._start

    @always_inline
    def end(self) -> Position:
        return self._end

    @always_inline
    def length(self) -> UInt64:
        """Number of bases in the interval (end - start + 1 for closed [start, end]).
        """
        return self._end.get() - self._start.get() + 1

    @always_inline
    def is_empty(self) -> Bool:
        return self._start.get() > self._end.get()

    def contains(self, position: Position) -> Bool:
        """True if position is in [start, end] (1-based closed)."""
        return (
            self._start <= position
            and position <= self._end
        )

    def intersects(self, other: Self) -> Bool:
        """True if this interval overlaps other (both 1-based closed)."""
        return (
            self._start <= other._end
            and other._start <= self._end
        )
