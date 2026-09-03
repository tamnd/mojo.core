"""Putting a string together. Go's `builder_test.go`.

Half of Go's file is about the copy check: `TestBuilderCopyPanics` builds a
table of eight ways to copy a builder and asserts that each one panics. None of
those tests can be written here, because none of those programs compile. The
type is `Movable` and not `Copyable`, so `var b2 = b` is refused where Go
refuses it at run time and only if the copy is used.

What is left is the ordinary behaviour, plus the one place this differs on
purpose: `string()` raises rather than handing back bytes that are not text.
"""

from std.testing import assert_equal, assert_raises, assert_true

from core.io import Byte
from core.strings import Builder


def test_empty() raises:
    """The zero value works and has nothing in it. Go's `TestBuilder`."""
    var b = Builder()
    assert_equal(b.len(), 0)
    assert_equal(b.string(), "")


def test_writes() raises:
    """The four ways in, and the length after each. Go's `TestBuilder`."""
    var b = Builder()
    assert_equal(b.write_string("hello"), 5)
    assert_equal(b.len(), 5)
    b.write_byte(Byte(ord(" ")))
    assert_equal(b.len(), 6)
    assert_equal(b.write_rune(0x263A), 3)
    assert_equal(b.len(), 9)
    var more = String("!")
    assert_equal(b.write(more.as_bytes()), 1)
    assert_equal(b.string(), "hello ☺!")


def test_write_returns_everything() raises:
    """A builder never takes less than it was given.

    The short write an `io.Writer` is allowed is impossible here, so nobody
    calling one has to loop, and the returned count is only ever the length of
    the argument.
    """
    var b = Builder()
    var s = String("0123456789")
    for _ in range(10):
        assert_equal(b.write(s.as_bytes()), 10)
    assert_equal(b.len(), 100)
    assert_equal(b.string()[byte=0:10], "0123456789")


def test_reset() raises:
    """Go's `TestBuilderReset`, with the allocation kept rather than dropped.

    Go's `Reset` throws the buffer away because its builder has to forget the
    pointer behind its copy check. There is no such pointer here, so the
    capacity survives and a builder reused around a loop allocates once.
    """
    var b = Builder()
    _ = b.write_string("hello")
    b.grow(64)
    var before = b.cap()
    b.reset()
    assert_equal(b.len(), 0)
    assert_equal(b.string(), "")
    assert_true(b.cap() >= before)
    _ = b.write_string("again")
    assert_equal(b.string(), "again")


def test_grow() raises:
    """Go's `TestBuilderGrow`.

    Growing changes nothing about the contents, so the only thing to assert is
    that it did not, and that the capacity afterwards covers what was asked
    for.
    """
    var b = Builder()
    _ = b.write_string("abc")
    b.grow(100)
    assert_equal(b.string(), "abc")
    assert_equal(b.len(), 3)
    assert_true(b.cap() >= 103)
    # Go panics on a negative count.
    with assert_raises():
        b.grow(-1)


def test_write_rune_on_a_bad_rune() raises:
    """A rune that is not a code point is written as U+FFFD.

    That is `utf8.append_rune`'s rule, and it is why `write_rune` cannot fail
    and why a builder fed only runes always holds valid text.
    """
    var b = Builder()
    assert_equal(b.write_rune(-1), 3)
    assert_equal(b.write_rune(0x110000), 3)
    # A surrogate is not a code point either, and Go substitutes the same way.
    assert_equal(b.write_rune(0xD800), 3)
    assert_equal(b.string(), "���")


def test_string_refuses_bytes_that_are_not_text() raises:
    """The one deviation from Go's builder, and where it bites.

    Go's `String` hands back whatever was written, because a Go string is
    arbitrary bytes. A Mojo `String` is not, so a lone continuation byte put
    down with `write_byte` has to be refused somewhere, and it is refused here
    rather than being turned into something the caller did not write.
    """
    var b = Builder()
    _ = b.write_string("ok")
    b.write_byte(0x80)
    with assert_raises():
        _ = b.string()
    # And `bytes()` is the accessor that never refuses, so the bytes are not
    # lost, they are just not called text.
    var raw = b.bytes()
    assert_equal(len(raw), 3)
    assert_equal(Int(raw[2]), 0x80)


def test_bytes_is_a_copy() raises:
    """The rule `core.bytes.Buffer` sets: no method hands out a view.

    A view would be freed memory the moment the next write reallocated, which
    is worse than the stale bytes the same mistake gives in Go. So `bytes()`
    copies, and the copy taken before a write does not change when the builder
    does.
    """
    var b = Builder()
    _ = b.write_string("abc")
    var snapshot = b.bytes()
    _ = b.write_string("def")
    assert_equal(len(snapshot), 3)
    assert_equal(b.len(), 6)


def test_builder_moves() raises:
    """A builder can be handed on, which is the copy check done at compile time.

    `var b2 = b` does not compile, and `var b2 = b^` does, which is the version
    the caller meant in every case Go's run time check catches.
    """
    var b = Builder()
    _ = b.write_string("moved")
    var b2 = b^
    assert_equal(b2.string(), "moved")


def test_writing_in_a_loop() raises:
    """What the type exists for, on a scale where `+=` would be noticeable."""
    var b = Builder()
    b.grow(4000)
    for i in range(1000):
        _ = b.write_string("abcd")
        _ = i
    assert_equal(b.len(), 4000)
    var got = b.string()
    assert_equal(got[byte=0:8], "abcdabcd")
    assert_equal(got[byte=3992:4000], "abcdabcd")
