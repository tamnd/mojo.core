"""The growable buffer. Go's `buffer_test.go`.

A `Buffer` is a list and an offset, and almost every bug one can have is about
the offset: bytes read twice, bytes skipped, the dead prefix never reclaimed,
an unread that moves the cursor when nothing was read. So the tests here fill
and drain the same buffer repeatedly rather than checking one operation at a
time, which is what Go does and is the shape that catches those.

The three failures Go writes as panics — a negative `grow`, a `truncate` past
what is buffered, and an allocation that cannot be represented — raise here,
and each has a case. The last is not reachable without asking for a slice
larger than memory, so what is tested is the two a caller can trip over.
"""

from std.testing import assert_equal, assert_raises, assert_true

from core.bytes import Buffer, MIN_READ, new_buffer, new_buffer_string
from core.errors import matches, partial
from core.errors.codes import EOF, ErrShortWrite
from core.io import Byte
from core.unicode import MAX_RUNE
from core.unicode.utf8 import UTF_MAX, append_rune

from tests.bytes._fixtures import OneByte, Short, Sink, enc, expect, quote

comptime ALPHABET = "abcdefghijklmnopqrstuvwxyz"
"""Go's `testString`, shortened to the letters. Twenty six bytes."""

comptime LETTERS = 26
"""How many bytes that is. `len` of a `String` is deliberately not a thing in
Mojo, since a length in bytes, in code points and in graphemes are three
different numbers, and this is the one this file means."""


def drain(mut b: Buffer, size: Int) raises -> String:
    """Read the buffer empty `size` bytes at a time, and quote what came out.

    Reading in small pieces is the point: a buffer emptied by one big read
    never moves its offset more than once, and the offset is where the bugs
    are.
    """
    var got = List[Byte]()
    var window = List[Byte](length=size, fill=0)
    while True:
        var n: Int
        try:
            n = b.read(Span(window))
        except e:
            assert_true(matches(e, EOF))
            break
        for i in range(n):
            got.append(window[i])
    return quote(Span(got))


def test_the_zero_value_is_ready_to_use() raises:
    """Go's `TestNil` and `TestNewBuffer`, which are about the same thing: a
    buffer nobody initialised behaves as an empty one."""
    var b = Buffer()
    assert_equal(b.len(), 0)
    assert_equal(b.string(), "")
    assert_equal(len(b.bytes()), 0)

    var owned = new_buffer(enc("abc"))
    assert_equal(owned.string(), "abc")

    var copied = new_buffer_string("abc")
    assert_equal(copied.string(), "abc")


def test_basic_operations() raises:
    """Go's `TestBasicOperations`, five times round as Go runs it.

    Going round more than once is the part that matters. The second pass
    starts from a buffer that has been written, read and reset, so it is the
    one that finds a `reset` which left the offset behind.
    """
    var b = Buffer()
    for _ in range(5):
        assert_equal(b.string(), "")
        b.reset()
        assert_equal(b.string(), "")
        b.truncate(0)
        assert_equal(b.string(), "")

        var first = enc("a")
        assert_equal(b.write(Span(first)), 1)
        assert_equal(b.string(), "a")

        b.write_byte(Byte(ord("b")))
        assert_equal(b.string(), "ab")

        var rest = enc("cdefghijklmnopqrstuvwxyz")
        assert_equal(b.write(Span(rest)), 24)
        assert_equal(b.string(), ALPHABET)

        b.truncate(26)
        assert_equal(b.string(), ALPHABET)
        b.truncate(20)
        assert_equal(b.string(), "abcdefghijklmnopqrst")

        assert_equal(drain(b, 5), expect("abcdefghijklmnopqrst"))
        assert_equal(drain(b, 100), "")

        b.write_byte(Byte(ord("b")))
        assert_equal(Int(b.read_byte()), ord("b"))
        with assert_raises():
            _ = b.read_byte()


def test_large_writes_and_small_reads() raises:
    """Go's `TestLargeStringWrites` and `TestLargeByteWrites` together.

    Five copies of the alphabet written in, then read out in pieces that do
    not divide evenly into it, for eight different piece sizes. The uneven
    division is deliberate: a read that ends part way through what a write put
    in is where an offset gets rounded.
    """
    var b = Buffer()
    for i in range(3, 27, 3):
        b.reset()
        var want = String("")
        for _ in range(5):
            _ = b.write_string(ALPHABET)
            want += ALPHABET
        var size = LETTERS // i
        if size == 0:
            size = 1
        assert_equal(drain(b, size), expect(want))
        assert_equal(b.len(), 0)


def test_mixed_reads_and_writes() raises:
    """Go's `TestMixedReadsAndWrites`, with a fixed pattern in place of Go's
    random one, because a test that fails only some mornings is worse than one
    that covers a little less.

    Fifty rounds of writing a slice of the alphabet and reading back a
    different number of bytes, with the expected contents tracked alongside.
    The buffer is never empty and never full, which is the state the offset
    arithmetic has to survive.
    """
    var b = Buffer()
    var want = List[Byte]()
    var window = List[Byte](length=LETTERS, fill=0)
    for i in range(50):
        var write = i % LETTERS
        var piece = enc(ALPHABET)
        _ = b.write(Span(piece)[0:write])
        for j in range(write):
            want.append(piece[j])

        var read = (i * 7) % LETTERS
        var n = 0
        if read > 0 and b.len() > 0:
            n = b.read(Span(window)[0:read])
        for j in range(n):
            assert_equal(Int(window[j]), Int(want[j]))
        var left = List[Byte]()
        for j in range(n, len(want)):
            left.append(want[j])
        want = left^
        assert_equal(b.len(), len(want))
    assert_equal(drain(b, 7), quote(Span(want)))


def test_truncate_refuses_what_is_not_there() raises:
    """Go panics on both of these."""
    var b = new_buffer_string("hello")
    with assert_raises(contains="out of range"):
        b.truncate(6)
    with assert_raises(contains="out of range"):
        b.truncate(-1)
    assert_equal(b.string(), "hello")


def test_truncate_counts_from_the_read_cursor() raises:
    """`truncate(n)` keeps the first `n` *unread* bytes, so it is `len()` it is
    measured against and not the size of the allocation. After reading two
    bytes of five, truncating to three is a no-op and truncating to four is out
    of range."""
    var b = new_buffer_string("hello")
    var window = List[Byte](length=2, fill=0)
    _ = b.read(Span(window))
    assert_equal(b.len(), 3)
    b.truncate(3)
    assert_equal(b.string(), "llo")
    with assert_raises(contains="out of range"):
        b.truncate(4)
    b.truncate(1)
    assert_equal(b.string(), "l")


def test_grow() raises:
    """Go's `TestGrow`, without the allocation count.

    Go asserts that the write after a `Grow` allocates nothing, which needs an
    allocation counter this library does not have. What can be checked is the
    part that would be a bug rather than a missed optimisation: growing never
    changes what the buffer holds, and the room it makes is really there.
    """
    for start in [0, 100, 1000, 10000]:
        for extra in [0, 100, 1000, 10000]:
            var b = Buffer()
            for _ in range(start):
                b.write_byte(Byte(ord("x")))
            var window = List[Byte](length=72, fill=0)
            var read = 0
            if start > 0:
                read = b.read(Span(window))
            b.grow(extra)
            assert_equal(b.len(), start - read)
            assert_true(b.available() >= extra)
            for _ in range(extra):
                b.write_byte(Byte(ord("y")))
            assert_equal(b.len(), start - read + extra)


def test_grow_refuses_a_negative_count() raises:
    """Go panics here."""
    var b = Buffer()
    with assert_raises(contains="negative count"):
        b.grow(-1)


def test_next() raises:
    """Go's `TestNext`: every start offset, every length, every ask.

    The buffer holds `0 1 2 3 4`, `i` bytes are read off the front, and then
    `next(k)` is asked for. What comes back has to be `min(k, j - i)` bytes
    starting at value `i`, for every combination, which pins both the count and
    that `next` reads from the cursor rather than from the front.
    """
    var source = List[Byte]()
    for i in range(5):
        source.append(Byte(i))
    var tmp = List[Byte](length=5, fill=0)
    for j in range(6):
        for i in range(j + 1):
            for k in range(7):
                var start = List[Byte](capacity=j)
                for at in range(j):
                    start.append(source[at])
                var b = new_buffer(start^)
                var n = 0
                if i > 0:
                    n = b.read(Span(tmp)[0:i])
                assert_equal(n, i)
                var got = b.next(k)
                var want = k
                if want > j - i:
                    want = j - i
                assert_equal(len(got), want)
                for at in range(len(got)):
                    assert_equal(Int(got[at]), at + i)


def test_next_takes_the_bytes_even_when_it_cannot_take_them_all() raises:
    """`next(n)` with more asked for than there is consumes what there is, and
    the answer is owned so it survives the write that follows.

    That last part is the deviation from Go worth checking: Go's `Next` returns
    a view the next write invalidates, and here the same call gives bytes the
    caller keeps.
    """
    var b = new_buffer_string("abc")
    var got = b.next(10)
    assert_equal(quote(Span(got)), expect("abc"))
    assert_equal(b.len(), 0)
    _ = b.write_string("defghijklmnopqrstuvwxyz")
    assert_equal(quote(Span(got)), expect("abc"))


@fieldwise_init
struct DelimCase(Copyable, Movable):
    """Go's `readBytesTests`: what comes out before the input runs out."""

    var buffer: String
    var delim: Int
    var want: String
    """The pieces with a bar between them, as `expect` reads them."""


def delim_cases() -> List[DelimCase]:
    """Go's `readBytesTests`.

    Go's rows carry the error that came back with the last piece, because Go
    returns the short read and `io.EOF` together. Here the bytes come back on
    one call and the end arrives on the next, so the error column is dropped
    and every row is read until it raises. `deviations.md` has the row; it is
    the same rule `bufio` follows.

    Two rows also grow a piece: Go stops at the first `nil` error and leaves
    the tail of `abbbaaaba` and of `hello\\x01world` unread, and reading to the
    end finds it.
    """
    var out = List[DelimCase]()
    out.append(DelimCase("", 0, ""))
    out.append(DelimCase("a\\x00", 0, "a\\x00"))
    out.append(DelimCase("abbbaaaba", ord("b"), "ab|b|b|aaab|a"))
    out.append(DelimCase("hello\\x01world", 1, "hello\\x01|world"))
    out.append(DelimCase("foo\nbar", 0, "foo\nbar"))
    out.append(
        DelimCase("alpha\nbeta\ngamma\n", ord("\n"), "alpha\n|beta\n|gamma\n")
    )
    out.append(
        DelimCase("alpha\nbeta\ngamma", ord("\n"), "alpha\n|beta\n|gamma")
    )
    return out^


def test_read_bytes() raises:
    """Go's `TestReadBytes`, read to the end rather than to the first error."""
    var cases = delim_cases()
    for row in cases:
        var b = new_buffer(enc(row.buffer))
        var got = String("")
        var seen = 0
        while True:
            var piece: List[Byte]
            try:
                piece = b.read_bytes(Byte(row.delim))
            except e:
                assert_true(matches(e, EOF))
                break
            if seen > 0:
                got += "|"
            seen += 1
            got += quote(Span(piece))
        assert_equal(got, expect(row.want))


def test_read_string() raises:
    """Go's `TestReadString`, over the rows whose bytes are text.

    The rows with a NUL delimiter are text as well — a NUL is a valid code
    point — so the only thing left out is nothing at all, and the check is that
    `read_string` and `read_bytes` cut in the same places.
    """
    var cases = delim_cases()
    for row in cases:
        var b = new_buffer(enc(row.buffer))
        var got = String("")
        var seen = 0
        while True:
            var piece: String
            try:
                piece = b.read_string(Byte(row.delim))
            except e:
                assert_true(matches(e, EOF))
                break
            if seen > 0:
                got += "|"
            seen += 1
            got += quote(piece.as_bytes())
        assert_equal(got, expect(row.want))


def test_read_string_refuses_bytes_that_are_not_text() raises:
    """A `String` promises UTF-8, so this raises where `read_bytes` does not.

    The bytes are consumed either way, which is the part a caller has to know:
    the failure is about turning them into a `String` and not about reading
    them, so there is nothing to retry.
    """
    var b = new_buffer(enc("bad\\xffline\ntail\n"))
    with assert_raises():
        _ = b.read_string(Byte(ord("\n")))
    assert_equal(b.string(), "tail\n")


@fieldwise_init
struct PeekCase(Copyable, Movable):
    """Go's `peekTests`, with the error column replaced by a flag."""

    var buffer: String
    var skip: Int
    var n: Int
    var want: String
    var raises_at_the_end: Bool


def test_peek() raises:
    """Go's `TestPeek`, adjusted where this library answers differently.

    Go returns the short slice together with `io.EOF` when there are fewer than
    `n` bytes. Here a short answer is just a short answer, and `EOF` is raised
    only when there is nothing at all to hand over, which is the rule
    everywhere in this library: bytes now, the reason next time. The two rows
    Go marks `io.EOF` and this does not are the two where something came back.

    Every row also checks the length afterwards, because peeking must not
    consume.
    """
    var cases = List[PeekCase]()
    cases.append(PeekCase("", 0, 0, "", False))
    cases.append(PeekCase("aaa", 0, 3, "aaa", False))
    cases.append(PeekCase("foobar", 0, 2, "fo", False))
    cases.append(PeekCase("a", 0, 2, "a", False))
    cases.append(PeekCase("helloworld", 4, 3, "owo", False))
    cases.append(PeekCase("helloworld", 5, 5, "world", False))
    cases.append(PeekCase("helloworld", 5, 6, "world", False))
    cases.append(PeekCase("helloworld", 10, 1, "", True))
    for row in cases:
        var b = new_buffer(enc(row.buffer))
        _ = b.next(row.skip)
        if row.raises_at_the_end:
            with assert_raises():
                _ = b.peek(row.n)
        else:
            var got = b.peek(row.n)
            assert_equal(quote(Span(got)), expect(row.want))
        assert_equal(b.len(), row.buffer.byte_length() - row.skip)


def test_peek_refuses_a_negative_count() raises:
    var b = new_buffer_string("abc")
    with assert_raises(contains="negative count"):
        _ = b.peek(-1)


def test_read_of_an_empty_span_at_the_end_is_not_a_failure() raises:
    """Go's `TestReadEmptyAtEOF`.

    An empty span is not a way of asking whether anything is left, so it
    answers zero rather than raising. A caller who wants to know calls `len()`.
    """
    var b = Buffer()
    var nothing = List[Byte]()
    assert_equal(b.read(Span(nothing)), 0)


def test_unread_byte() raises:
    """Go's `TestUnreadByte`.

    The rule is that there has to have been a read to undo. At the end of the
    input, after a read that moved nothing, and before anything has happened at
    all, the call is refused rather than quietly moving the cursor back over a
    byte that was never handed out.
    """
    var b = Buffer()
    with assert_raises():
        b.unread_byte()
    with assert_raises():
        _ = b.read_byte()
    with assert_raises():
        b.unread_byte()

    _ = b.write_string(ALPHABET)
    var nothing = List[Byte]()
    assert_equal(b.read(Span(nothing)), 0)
    with assert_raises():
        b.unread_byte()

    var upto = b.read_bytes(Byte(ord("m")))
    assert_equal(quote(Span(upto)), expect("abcdefghijklm"))
    b.unread_byte()
    assert_equal(Int(b.read_byte()), ord("m"))


def test_rune_io() raises:
    """Go's `TestRuneIO`: a thousand runes written, read back, and unread.

    The runes are U+0000 to U+03E7, which is every width from one byte to two
    and the boundary between them at U+0080. What is checked is that the width
    `write_rune` reports is the width `read_rune` gives back, for each one,
    and that an `unread_rune` between them puts back exactly what was taken.
    """
    # slow: a thousand runes, written, read, unread and read again
    comptime COUNT = 1000
    var b = Buffer()
    var want = List[Byte]()
    for r in range(COUNT):
        var wrote = b.write_rune(Int32(r))
        var width = append_rune(want, Int32(r))
        assert_equal(wrote, width)
    assert_equal(quote(Span(b.bytes())), quote(Span(want)))

    for r in range(COUNT):
        var got, width = b.read_rune()
        assert_equal(Int(got), r)
        var scratch = List[Byte]()
        assert_equal(width, append_rune(scratch, Int32(r)))
    assert_equal(b.len(), 0)

    b.reset()
    with assert_raises():
        b.unread_rune()
    with assert_raises():
        _ = b.read_rune()
    with assert_raises():
        b.unread_rune()

    _ = b.write(Span(want))
    for r in range(COUNT):
        var first, width = b.read_rune()
        b.unread_rune()
        var second, again = b.read_rune()
        assert_equal(Int(first), r)
        assert_equal(Int(second), r)
        assert_equal(width, again)


def test_unread_rune_is_stricter_than_unread_byte() raises:
    """After a `read` of bytes there is no rune width to give back, so
    `unread_rune` refuses where `unread_byte` would not."""
    var b = new_buffer_string("héllo")
    var window = List[Byte](length=1, fill=0)
    _ = b.read(Span(window))
    with assert_raises():
        b.unread_rune()
    b.unread_byte()
    assert_equal(b.string(), "héllo")


def test_write_invalid_rune() raises:
    """Go's `TestWriteInvalidRune`: a rune that is not one is written as U+FFFD.

    Negative and above the last code point both count, and neither is an error,
    because the encoder has a defined answer and a buffer that raised here
    would make every `write_rune` a call that has to be checked.
    """
    for r in [Int32(-1), MAX_RUNE + 1, Int32(0xD800)]:
        var b = Buffer()
        var wrote = b.write_rune(r)
        assert_equal(wrote, 3)
        assert_equal(quote(Span(b.bytes())), expect("\\xef\\xbf\\xbd"))


def test_read_from() raises:
    """Go's `TestReadFrom`, over a reader that gives one byte a call.

    A reader is entitled to fill less than it was asked for, so `read_from`
    has to be a loop. Over `OneByte` a version written as a single read keeps
    the first byte and drops the rest, and the call count says the loop ran.
    """
    var src = OneByte(enc(ALPHABET))
    var b = Buffer()
    var moved = b.read_from(src)
    assert_equal(Int(moved), 26)
    assert_equal(b.string(), ALPHABET)
    assert_equal(src.reads, 27)


def test_read_from_an_empty_source() raises:
    """The end of the source is not a failure and nothing is added."""
    var src = OneByte(List[Byte]())
    var b = new_buffer_string("kept")
    var moved = b.read_from(src)
    assert_equal(Int(moved), 0)
    assert_equal(b.string(), "kept")


def test_read_from_asks_for_min_read_at_a_time() raises:
    """`MIN_READ` is the chunk size, so a source with more than that in it is
    drained in more than one call and the buffer still ends up holding all of
    it in order."""
    var big = List[Byte]()
    for i in range(MIN_READ * 2 + 7):
        big.append(Byte(i & 0xFF))
    var size = len(big)
    var want = quote(Span(big))
    var src = OneByte(big^)
    var b = Buffer()
    var moved = b.read_from(src)
    assert_equal(Int(moved), size)
    assert_equal(quote(Span(b.bytes())), want)


def test_write_to() raises:
    """Go's `TestWriteTo`: everything goes across in one call and the buffer is
    left empty."""
    var b = new_buffer_string(ALPHABET)
    var dst = Sink()
    var moved = b.write_to(dst)
    assert_equal(Int(moved), 26)
    assert_equal(dst.writes, 1)
    assert_equal(quote(Span(dst.data)), expect(ALPHABET))
    assert_equal(b.len(), 0)


def test_write_to_an_empty_buffer_writes_nothing() raises:
    """No bytes means no call, which matters for a writer that treats a write
    of zero bytes as something worth doing."""
    var b = Buffer()
    var dst = Sink()
    assert_equal(Int(b.write_to(dst)), 0)
    assert_equal(dst.writes, 0)


def test_write_to_a_writer_that_takes_only_part() raises:
    """A short write raises `ErrShortWrite` carrying the count that moved, and
    the cursor is left after the bytes the writer did take.

    That is what makes the failure recoverable: the caller knows how much went
    and what is left is still in the buffer, in order.
    """
    var b = new_buffer_string(ALPHABET)
    var dst = Short(10)
    var took = -1
    var raised = False
    try:
        _ = b.write_to(dst)
    except e:
        raised = True
        assert_true(matches(e, ErrShortWrite))
        took = partial(e)
    assert_true(raised)
    assert_equal(took, 10)
    assert_equal(quote(Span(dst.data)), expect("abcdefghij"))
    assert_equal(b.string(), "klmnopqrstuvwxyz")


def test_the_dead_prefix_is_reclaimed() raises:
    """Go's `TestBufferGrowth`, which is issue 5154.

    A buffer written and drained in a loop has a read cursor that only moves
    forward, so without compaction the allocation grows once per byte that ever
    went through it. Go slides the live bytes down once the dead prefix is big
    enough, and the test is that the capacity after five thousand rounds is
    within a small factor of the capacity after one.
    """
    # slow: five thousand rounds of a kilobyte each
    var b = Buffer()
    var block = List[Byte](length=1024, fill=Byte(ord("x")))
    _ = b.write(Span(block)[0:1])
    var first = 0
    for i in range(5 << 10):
        _ = b.write(Span(block))
        _ = b.read(Span(block))
        if i == 0:
            first = b.cap()
    assert_true(b.cap() <= first * 3)


def test_string_refuses_bytes_that_are_not_text() raises:
    """`bytes()` never refuses and `string()` does, which is the whole
    difference between them."""
    var b = new_buffer(enc("a\\xffb"))
    assert_equal(len(b.bytes()), 3)
    with assert_raises():
        _ = b.string()


def test_bytes_is_a_copy() raises:
    """Go documents `Bytes` as valid until the next write. Here it is owned,
    and this is the check that says so: the bytes taken out do not change when
    the buffer is written to, reset, or drained.
    """
    var b = new_buffer_string("abc")
    var taken = b.bytes()
    _ = b.write_string("defghijklmnopqrstuvwxyz")
    b.reset()
    assert_equal(quote(Span(taken)), expect("abc"))
