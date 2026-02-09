from testing import assert_equal, assert_raises, assert_true, assert_false
from blazeseq.CONSTS import (
    DEFAULT_CAPACITY,
    MAX_CAPACITY,
    new_line,
    carriage_return,
)
from blazeseq.parser import LineIterator
from blazeseq.readers import MemoryReader
from memory import Span
from collections.string import StringSlice
from testing import TestSuite


# ============================================================================
# Helper Functions
# ============================================================================


fn create_memory_reader(content: String) -> MemoryReader:
    """Helper function to create MemoryReader from string content."""
    var content_bytes = content.as_bytes()
    return MemoryReader(content_bytes)


fn span_to_string(span: Span[Byte, MutExternalOrigin]) -> String:
    """Convert a span to a string for comparison."""
    return String(StringSlice(unsafe_from_utf8=span))


# ============================================================================
# Basic next_line() Tests - Normal Cases
# ============================================================================


fn test_next_line_single_line() raises:
    """Single line with newline."""
    var content = "Hello World\n"
    var reader = create_memory_reader(content)
    var line_iter = LineIterator(reader^)

    var line = line_iter.next_line()
    assert_true(line is not None, "Should return a line")
    assert_equal(
        span_to_string(line.value()), "Hello World", "Line content should match"
    )

    var line2 = line_iter.next_line()
    assert_true(line2 is None, "Should return None at EOF")

    print("✓ test_next_line_single_line passed")


fn test_next_line_multiple_lines() raises:
    """Multiple lines, verify each line content."""
    var content = "Line 1\nLine 2\nLine 3\n"
    var reader = create_memory_reader(content)
    var line_iter = LineIterator(reader^)

    var line1 = line_iter.next_line()
    assert_true(line1 is not None, "Should return first line")
    assert_equal(
        span_to_string(line1.value()), "Line 1", "First line should match"
    )

    var line2 = line_iter.next_line()
    assert_true(line2 is not None, "Should return second line")
    assert_equal(
        span_to_string(line2.value()), "Line 2", "Second line should match"
    )

    var line3 = line_iter.next_line()
    assert_true(line3 is not None, "Should return third line")
    assert_equal(
        span_to_string(line3.value()), "Line 3", "Third line should match"
    )

    var line4 = line_iter.next_line()
    assert_true(line4 is None, "Should return None at EOF")

    print("✓ test_next_line_multiple_lines passed")


fn test_next_line_empty_content() raises:
    """Empty content should return None."""
    var content = ""
    var reader = create_memory_reader(content)
    var line_iter = LineIterator(reader^)

    var line = line_iter.next_line()
    assert_true(line is None, "Should return None for empty content")

    print("✓ test_next_line_empty_content passed")


fn test_next_line_single_line_no_newline() raises:
    """Content with one line but no trailing newline."""
    var content = "Hello World"
    var reader = create_memory_reader(content)
    var line_iter = LineIterator(reader^)

    var line = line_iter.next_line()
    assert_true(
        line is not None, "Should return a line even without trailing newline"
    )
    assert_equal(
        span_to_string(line.value()), "Hello World", "Line content should match"
    )

    var line2 = line_iter.next_line()
    assert_true(line2 is None, "Should return None at EOF")

    print("✓ test_next_line_single_line_no_newline passed")


# ============================================================================
# Basic next_line() Tests - Lines with Carriage Return
# ============================================================================


fn test_next_line_carriage_return() raises:
    """Lines ending with \\r\\n (Windows-style)."""
    var content = "Line 1\r\nLine 2\r\n"
    var reader = create_memory_reader(content)
    var line_iter = LineIterator(reader^)

    var line1 = line_iter.next_line()
    assert_true(line1 is not None, "Should return first line")
    assert_equal(
        span_to_string(line1.value()), "Line 1", "Line should not include \\r"
    )

    var line2 = line_iter.next_line()
    assert_true(line2 is not None, "Should return second line")
    assert_equal(
        span_to_string(line2.value()), "Line 2", "Line should not include \\r"
    )

    var line3 = line_iter.next_line()
    assert_true(line3 is None, "Should return None at EOF")

    print("✓ test_next_line_carriage_return passed")


fn test_next_line_mixed_line_endings() raises:
    """Mix of \\n and \\r\\n endings."""
    var content = "Unix line\nWindows line\r\nAnother Unix\n"
    var reader = create_memory_reader(content)
    var line_iter = LineIterator(reader^)

    var line1 = line_iter.next_line()
    assert_true(line1 is not None)
    assert_equal(
        span_to_string(line1.value()), "Unix line", "Unix line should match"
    )

    var line2 = line_iter.next_line()
    assert_true(line2 is not None)
    assert_equal(
        span_to_string(line2.value()),
        "Windows line",
        "Windows line should match",
    )

    var line3 = line_iter.next_line()
    assert_true(line3 is not None)
    assert_equal(
        span_to_string(line3.value()),
        "Another Unix",
        "Another Unix line should match",
    )

    var line4 = line_iter.next_line()
    assert_true(line4 is None, "Should return None at EOF")

    print("✓ test_next_line_mixed_line_endings passed")


fn test_next_line_carriage_return_no_newline() raises:
    """Line ending with just \\r (edge case)."""
    var content = "Line with only\r"
    var reader = create_memory_reader(content)
    var line_iter = LineIterator(reader^)

    var line = line_iter.next_line()
    assert_true(line is not None, "Should return a line")
    assert_equal(
        span_to_string(line.value()),
        "Line with only",
        "Line should trim trailing \\r",
    )
    _ = line_iter
    print("✓ test_next_line_carriage_return_no_newline passed")


# ============================================================================
# Basic next_line() Tests - Empty Lines
# ============================================================================


fn test_next_line_multiple_empty_lines() raises:
    """Multiple consecutive empty lines (\\n\\n\\n)."""
    var content = "\n\n\n"
    var reader = create_memory_reader(content)
    var line_iter = LineIterator(reader^)

    var line1 = line_iter.next_line()
    assert_true(line1 is not None, "Should return first empty line")
    assert_equal(len(line1.value()), 0, "First line should be empty")

    var line2 = line_iter.next_line()
    assert_true(line2 is not None, "Should return second empty line")
    assert_equal(len(line2.value()), 0, "Second line should be empty")

    var line3 = line_iter.next_line()
    assert_true(line3 is not None, "Should return third empty line")
    assert_equal(len(line3.value()), 0, "Third line should be empty")

    var line4 = line_iter.next_line()
    assert_true(line4 is None, "Should return None at EOF")

    print("✓ test_next_line_multiple_empty_lines passed")


fn test_next_line_empty_line_at_start() raises:
    """Empty line at content start."""
    var content = "\nLine 2\nLine 3\n"
    var reader = create_memory_reader(content)
    var line_iter = LineIterator(reader^)

    var line1 = line_iter.next_line()
    assert_true(line1 is not None, "Should return first empty line")
    assert_equal(len(line1.value()), 0, "First line should be empty")

    var line2 = line_iter.next_line()
    assert_true(line2 is not None, "Should return second line")
    assert_equal(
        span_to_string(line2.value()), "Line 2", "Second line should match"
    )

    _ = line_iter
    print("✓ test_next_line_empty_line_at_start passed")


fn test_next_line_empty_line_at_end() raises:
    """Empty line at content end."""
    var content = "Line 1\nLine 2\n\n"
    var reader = create_memory_reader(content)
    var line_iter = LineIterator(reader^)

    var line1 = line_iter.next_line()
    assert_true(line1 is not None)
    assert_equal(
        span_to_string(line1.value()), "Line 1", "First line should match"
    )

    var line2 = line_iter.next_line()
    assert_true(line2 is not None)
    assert_equal(
        span_to_string(line2.value()), "Line 2", "Second line should match"
    )

    var line3 = line_iter.next_line()
    assert_true(line3 is not None, "Should return empty line")
    assert_equal(len(line3.value()), 0, "Last line should be empty")

    var line4 = line_iter.next_line()
    assert_true(line4 is None, "Should return None at EOF")

    print("✓ test_next_line_empty_line_at_end passed")


fn test_next_line_empty_line_middle() raises:
    """Empty lines interspersed with content."""
    var content = "Line 1\n\nLine 3\n\nLine 5\n"
    var reader = create_memory_reader(content)
    var line_iter = LineIterator(reader^)

    var line1 = line_iter.next_line()
    assert_true(line1 is not None)
    assert_equal(
        span_to_string(line1.value()), "Line 1", "First line should match"
    )

    var line2 = line_iter.next_line()
    assert_true(line2 is not None)
    assert_equal(len(line2.value()), 0, "Second line should be empty")

    var line3 = line_iter.next_line()
    assert_true(line3 is not None)
    assert_equal(
        span_to_string(line3.value()), "Line 3", "Third line should match"
    )

    var line4 = line_iter.next_line()
    assert_true(line4 is not None)
    assert_equal(len(line4.value()), 0, "Fourth line should be empty")

    var line5 = line_iter.next_line()
    assert_true(line5 is not None)
    assert_equal(
        span_to_string(line5.value()), "Line 5", "Fifth line should match"
    )

    print("✓ test_next_line_empty_line_middle passed")


# ============================================================================
# Basic next_line() Tests - Content Without Ending Newline
# ============================================================================


fn test_next_line_no_trailing_newline() raises:
    """Content ends without newline separator."""
    var content = "Line 1\nLine 2"
    var reader = create_memory_reader(content)
    var line_iter = LineIterator(reader^)

    var line1 = line_iter.next_line()
    assert_true(line1 is not None, "Should return first line")
    assert_equal(
        span_to_string(line1.value()), "Line 1", "First line should match"
    )

    var line2 = line_iter.next_line()
    assert_true(
        line2 is not None, "Should return last line even without newline"
    )
    assert_equal(
        span_to_string(line2.value()), "Line 2", "Last line should match"
    )

    var line3 = line_iter.next_line()
    assert_true(line3 is None, "Should return None at EOF")

    print("✓ test_next_line_no_trailing_newline passed")


fn test_next_line_no_trailing_newline_empty() raises:
    """Empty content (no data, no newline)."""
    var content = ""
    var reader = create_memory_reader(content)
    var line_iter = LineIterator(reader^)

    var line = line_iter.next_line()
    assert_true(line is None, "Should return None for empty content")

    print("✓ test_next_line_no_trailing_newline_empty passed")


# ============================================================================
# Boundary Tests for next_line() - Lines Broken Across Buffer Boundaries
# ============================================================================


fn test_next_line_crosses_boundary() raises:
    """Line that spans buffer boundary (requires refill)."""
    # Create a line that will cross buffer boundary
    # Use small buffer (64 bytes), line1=50 chars, line2=30 chars
    var line1 = String("")
    for i in range(50):
        line1 += "A"
    var line2 = String("")
    for i in range(30):
        line2 += "B"
    var content = line1 + "\n" + line2 + "\n"

    var reader = create_memory_reader(content)
    var line_iter = LineIterator(reader^, capacity=64)

    var result1 = line_iter.next_line()
    assert_true(result1 is not None, "Should return first line")
    assert_equal(len(result1.value()), 50, "First line should have 50 chars")

    var result2 = line_iter.next_line()
    assert_true(result2 is not None, "Should return second line")
    assert_equal(len(result2.value()), 30, "Second line should have 30 chars")

    print("✓ test_next_line_crosses_boundary passed")


fn test_next_line_crosses_boundary_multiple() raises:
    """Multiple lines crossing boundaries."""
    var line1 = String("")
    for i in range(50):
        line1 += "A"
    var line2 = String("")
    for i in range(30):
        line2 += "B"
    var line3 = String("")
    for i in range(40):
        line3 += "C"
    var content = line1 + "\n" + line2 + "\n" + line3 + "\n"

    var reader = create_memory_reader(content)
    var line_iter = LineIterator(reader^, capacity=64)

    var result1 = line_iter.next_line()
    assert_true(result1 is not None)
    assert_equal(len(result1.value()), 50, "First line should have 50 chars")

    var result2 = line_iter.next_line()
    assert_true(result2 is not None)
    assert_equal(len(result2.value()), 30, "Second line should have 30 chars")

    var result3 = line_iter.next_line()
    assert_true(result3 is not None)
    assert_equal(len(result3.value()), 40, "Third line should have 40 chars")

    print("✓ test_next_line_crosses_boundary_multiple passed")


fn test_next_line_crosses_boundary_with_cr() raises:
    """Line with \\r\\n crossing boundary."""
    var line1 = String("")
    for i in range(50):
        line1 += "A"
    var line2 = String("")
    for i in range(30):
        line2 += "B"
    var content = line1 + "\r\n" + line2 + "\r\n"

    var reader = create_memory_reader(content)
    var line_iter = LineIterator(reader^, capacity=64)

    var result1 = line_iter.next_line()
    assert_true(result1 is not None)
    assert_equal(len(result1.value()), 50, "First line should have 50 chars")

    var result2 = line_iter.next_line()
    assert_true(result2 is not None)
    assert_equal(len(result2.value()), 30, "Second line should have 30 chars")

    print("✓ test_next_line_crosses_boundary_with_cr passed")


# ============================================================================
# Boundary Tests for next_line() - Lines Larger Than Buffer
# ============================================================================


fn test_next_line_exceeds_capacity() raises:
    """Line longer than buffer capacity (should raise error)."""
    var long_line = String("")
    for i in range(100):
        long_line += "A"
    var content = long_line + "\n"

    var reader = create_memory_reader(content)
    var line_iter = LineIterator(reader^, capacity=64, growth_enabled=False)

    with assert_raises(contains="Line exceeds buffer capacity of 64 bytes"):
        _ = line_iter.next_line()

    print("✓ test_next_line_exceeds_capacity passed")


fn test_next_line_exceeds_capacity_with_growth() raises:
    """Line longer than capacity but growth enabled (should grow buffer)."""
    var long_line = String("")
    for i in range(100):
        long_line += "A"
    var content = long_line + "\n"

    var reader = create_memory_reader(content)
    var line_iter = LineIterator(
        reader^, capacity=64, growth_enabled=True, max_capacity=200
    )

    var line = line_iter.next_line()
    assert_true(line is not None, "Should return line after growing buffer")
    assert_equal(len(line.value()), 100, "Line should have 100 chars")

    print("✓ test_next_line_exceeds_capacity_with_growth passed")


fn test_next_line_exceeds_max_capacity() raises:
    """Line longer than max_capacity even with growth (should raise error)."""
    var long_line = String("")
    for i in range(200):
        long_line += "A"
    var content = long_line + "\n"

    var reader = create_memory_reader(content)
    var line_iter = LineIterator(
        reader^, capacity=64, growth_enabled=True, max_capacity=150
    )

    with assert_raises(
        contains="Line exceeds max buffer capacity of 150 bytes"
    ):
        _ = line_iter.next_line()

    print("✓ test_next_line_exceeds_max_capacity passed")

# ============================================================================
# Iterator Protocol Tests (Sanity Checks) - Basic Iterator Behavior
# ============================================================================


fn test_line_iterator_for_loop() raises:
    """Basic for line in line_iter iteration."""
    var content = "Line 1\nLine 2\nLine 3\n"
    var reader = create_memory_reader(content)
    var line_iter = LineIterator(reader^)

    var lines = List[String]()
    for line in line_iter:
        lines.append(span_to_string(line))

    assert_equal(len(lines), 3, "Should iterate over 3 lines")
    assert_equal(lines[0], "Line 1", "First line should match")
    assert_equal(lines[1], "Line 2", "Second line should match")
    assert_equal(lines[2], "Line 3", "Third line should match")

    print("✓ test_line_iterator_for_loop passed")


fn test_line_iterator_for_loop_multiple_lines() raises:
    """Iterate over multiple lines."""
    var content = "A\nB\nC\nD\nE\n"
    var reader = create_memory_reader(content)
    var line_iter = LineIterator(reader^)

    var lines = List[String]()
    for line in line_iter:
        lines.append(span_to_string(line))

    assert_equal(len(lines), 5, "Should iterate over 5 lines")
    assert_equal(lines[0], "A", "First line should match")
    assert_equal(lines[4], "E", "Last line should match")

    print("✓ test_line_iterator_for_loop_multiple_lines passed")


fn test_line_iterator_stop_iteration() raises:
    """Iterator raises StopIteration at EOF."""
    var content = "Line 1\n"
    var reader = create_memory_reader(content)
    var line_iter = LineIterator(reader^)

    var lines = List[String]()
    for line in line_iter:
        lines.append(span_to_string(line))

    assert_equal(len(lines), 1, "Should iterate over 1 line")
    assert_equal(lines[0], "Line 1", "Line should match")

    # Next iteration should not execute (StopIteration raised internally)
    var count = 0
    for line in line_iter:
        count += 1

    assert_equal(count, 0, "Should not iterate after EOF")

    print("✓ test_line_iterator_stop_iteration passed")


# ============================================================================
# Iterator Protocol Tests (Sanity Checks) - has_more() Method
# ============================================================================


fn test_has_more_true() raises:
    """Has_more() returns True when lines available."""
    var content = "Line 1\nLine 2\n"
    var reader = create_memory_reader(content)
    var line_iter = LineIterator(reader^)

    assert_true(line_iter.has_more(), "Should have more lines initially")

    _ = line_iter.next_line()
    assert_true(
        line_iter.has_more(), "Should have more lines after reading one"
    )

    print("✓ test_has_more_true passed")


fn test_has_more_false() raises:
    """Has_more() returns False at EOF."""
    var content = "Line 1\n"
    var reader = create_memory_reader(content)
    var line_iter = LineIterator(reader^)

    _ = line_iter.next_line()
    _ = line_iter.next_line()
    assert_false(line_iter.has_more(), "Should not have more lines at EOF")
    _ = line_iter
    print("✓ test_has_more_false passed")


fn test_has_more_after_consuming() raises:
    """Has_more() after consuming all lines."""
    var content = "Line 1\nLine 2\nLine 3\n"
    var reader = create_memory_reader(content)
    var line_iter = LineIterator(reader^)

    assert_true(line_iter.has_more(), "Should have more lines initially")

    _ = line_iter.next_line()
    assert_true(line_iter.has_more(), "Should have more lines")

    _ = line_iter.next_line()
    assert_true(line_iter.has_more(), "Should have more lines")

    _ = line_iter.next_line()
    assert_false(
        line_iter.has_more(), "Should not have more lines after consuming all"
    )

    print("✓ test_has_more_after_consuming passed")


# ============================================================================
# Iterator Protocol Tests (Sanity Checks) - position() Method
# ============================================================================


fn test_position_initial() raises:
    """Initial position is 0."""
    var content = "Line 1\nLine 2\n"
    var reader = create_memory_reader(content)
    var line_iter = LineIterator(reader^)

    assert_equal(line_iter.position(), 0, "Initial position should be 0")

    print("✓ test_position_initial passed")


fn test_position_advances() raises:
    """Position advances after reading lines."""
    var content = "Line 1\nLine 2\n"
    var reader = create_memory_reader(content)
    var line_iter = LineIterator(reader^)

    var pos1 = line_iter.position()
    assert_equal(pos1, 0, "Initial position should be 0")

    _ = line_iter.next_line()
    var pos2 = line_iter.position()
    assert_true(pos2 > pos1, "Position should advance after reading line")

    print("✓ test_position_advances passed")


fn test_position_after_multiple_lines() raises:
    """Position after reading multiple lines."""
    var content = "A\nB\nC\n"
    var reader = create_memory_reader(content)
    var line_iter = LineIterator(reader^)

    var pos0 = line_iter.position()
    _ = line_iter.next_line()
    var pos1 = line_iter.position()
    _ = line_iter.next_line()
    var pos2 = line_iter.position()
    _ = line_iter.next_line()
    var pos3 = line_iter.position()

    assert_equal(pos0, 0, "Initial position should be 0")
    assert_true(pos1 > pos0, "Position should advance after first line")
    assert_true(pos2 > pos1, "Position should advance after second line")
    assert_true(pos3 > pos2, "Position should advance after third line")

    print("✓ test_position_after_multiple_lines passed")


# ============================================================================
# Main Test Runner
# ============================================================================


fn main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
