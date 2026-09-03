"""Go's `TestChaCha8`, `TestChaCha8Read`, `TestChaCha8Marshal` and
`TestChaCha8MarshalRead`.

All four run from Go's `chacha8seed`, the 32 bytes `ABCDEFGHIJKLMNOPQRSTUVWXYZ
123456`, and check the 372 values in `chacha8output` or the marshalled forms
beside them. Between them they say that the block function, the reseed at the
end of a cycle and both encodings are right rather than merely consistent with
each other, which is what a generator's golden output is for.

Go checks the `Read` transcript by taking a sha256 of 2976 bytes and comparing
it to `chacha8hash`. There is no sha256 in this library yet, and there does not
need to be one for this: 2976 is 372 times 8, and the transcript is exactly the
little endian expansion of `chacha8output`, which was confirmed against Go
before it was relied on here. So the read tests compare against the expansion
directly, which pins the same bytes and also says which one is wrong when one
is. `chacha8hash` is harvested and waiting for `core.crypto.sha256`.
"""

from std.testing import assert_equal, assert_true

from core.errors import matches
from core.errors.codes import ErrInvalidEncoding
from core.math.rand import ChaCha8, new_chacha8

from tests.generated.rand import (
    chacha8marshal_rows,
    chacha8marshalread_rows,
    chacha8output_rows,
)
from tests.math.rand._fixtures import chacha8_seed, hexed

comptime OUT_LEN = 2976
"""How many bytes the read tests move. Go's `chacha8outlen`, and eight times
the length of `chacha8output`."""


def _transcript() -> List[UInt8]:
    """`chacha8output` as bytes, least significant first.

    What `read` should hand back from a freshly seeded generator. See the
    module docstring for why this is not a hash.
    """
    var values = chacha8output_rows()
    var out = List[UInt8](capacity=len(values) * 8)
    for value in values:
        for k in range(8):
            out.append(UInt8((value >> UInt64(8 * k)) & 0xFF))
    return out^


def test_chacha8() raises:
    var seed = chacha8_seed()
    var want = chacha8output_rows()

    var p = new_chacha8(seed)
    for i in range(len(want)):
        assert_equal(p.uint64(), want[i], "ChaCha8 #" + String(i))

    # And again after a reseed, which has to put the generator back exactly
    # where a new one starts rather than merely somewhere valid.
    p.seed(seed)
    for i in range(len(want)):
        assert_equal(p.uint64(), want[i], "after seed, ChaCha8 #" + String(i))


def test_chacha8_read_in_one_call() raises:
    var p = new_chacha8(chacha8_seed())
    var buf = List[UInt8](length=OUT_LEN, fill=0)
    var moved = p.read(Span(buf))
    assert_equal(moved, OUT_LEN, "read moved the wrong number of bytes")
    assert_equal(hexed(Span(buf)), hexed(Span(_transcript())))


def test_chacha8_read_one_byte_at_a_time() raises:
    # Go wraps the generator in `iotest.OneByteReader`. The point is the
    # partial value carried between calls: every read but the first eight is
    # served out of `read_buf`, and a generator that drew a fresh value each
    # time would produce a different transcript.
    var p = new_chacha8(chacha8_seed())
    var buf = List[UInt8](length=OUT_LEN, fill=0)
    for i in range(OUT_LEN):
        var moved = p.read(Span(buf)[i : i + 1])
        assert_equal(moved, 1, "one byte read #" + String(i))
    assert_equal(hexed(Span(buf)), hexed(Span(_transcript())))


def test_chacha8_read_of_nothing_moves_nothing() raises:
    var p = new_chacha8(chacha8_seed())
    var empty = List[UInt8]()
    assert_equal(p.read(Span(empty)), 0)
    # And it did not draw a value, so the stream is where it started.
    assert_equal(p.uint64(), chacha8output_rows()[0])


def test_chacha8_read_in_uneven_pieces() raises:
    # Go's last section of `TestChaCha8Read`, with the same intent and a fixed
    # schedule rather than a random one. Go draws each piece length from the
    # global generator, which makes the case that fails vary from run to run;
    # these lengths are chosen to cross every boundary that matters, being an
    # eight byte value, a 32 byte block and the 2976 byte end.
    var pieces = [1, 7, 8, 9, 15, 16, 31, 32, 33, 63, 100, 127, 128, 255]
    var p = new_chacha8(chacha8_seed())
    var got = List[UInt8](capacity=OUT_LEN)
    var at = 0
    var which = 0
    while at < OUT_LEN:
        var want = min(pieces[which % len(pieces)], OUT_LEN - at)
        which += 1
        var buf = List[UInt8](length=want, fill=0)
        assert_equal(p.read(Span(buf)), want, "piece at " + String(at))
        got.extend(Span(buf))
        at += want
    assert_equal(hexed(Span(got)), hexed(Span(_transcript())))


def test_chacha8_marshal() raises:
    var want = chacha8marshal_rows()
    var values = chacha8output_rows()
    var p = new_chacha8(chacha8_seed())
    for i in range(len(values)):
        var enc = p.marshal_binary()
        assert_equal(
            hexed(Span(enc)), hexed(Span(want[i])), "marshal #" + String(i)
        )

        var appended: List[UInt8] = [0, 0, 0, 0]
        var count = p.append_binary(appended)
        assert_equal(count, len(enc), "append_binary count #" + String(i))
        assert_equal(
            hexed(Span(appended)[4:]),
            hexed(Span(want[i])),
            "append_binary #" + String(i),
        )

        # Restore into a generator seeded with something else, so that a
        # decoder that quietly left a field alone would be caught.
        var q = new_chacha8(InlineArray[UInt8, 32](fill=0))
        q.unmarshal_binary(Span(enc))
        assert_equal(q.uint64(), values[i], "after unmarshal #" + String(i))
        _ = p.uint64()


def test_chacha8_marshal_after_a_partial_read() raises:
    # The `readbuf:` section, which only appears when a read left part of a
    # value owed. Go's `TestChaCha8MarshalRead`, fifty rounds of marshal,
    # restore and read one byte.
    var want = chacha8marshalread_rows()
    var p = new_chacha8(chacha8_seed())
    for i in range(len(want)):
        var enc = p.marshal_binary()
        assert_equal(
            hexed(Span(enc)), hexed(Span(want[i])), "marshal #" + String(i)
        )

        var appended: List[UInt8] = [0, 0, 0, 0]
        _ = p.append_binary(appended)
        assert_equal(
            hexed(Span(appended)[4:]),
            hexed(Span(want[i])),
            "append_binary #" + String(i),
        )

        var q = new_chacha8(InlineArray[UInt8, 32](fill=0))
        q.unmarshal_binary(Span(enc))
        p = q^
        var one = List[UInt8](length=1, fill=0)
        _ = p.read(Span(one))


def test_chacha8_unmarshal_rejects_a_bad_state_encoding() raises:
    var good = new_chacha8(chacha8_seed()).marshal_binary()
    var p = new_chacha8(chacha8_seed())

    var raised = False
    try:
        p.unmarshal_binary(good[: len(good) - 1])
    except e:
        raised = True
        assert_true(matches(e, ErrInvalidEncoding))
    assert_true(raised, "a short encoding should be refused")

    var wrong = good.copy()
    wrong[0] = UInt8(ord("d"))
    raised = False
    try:
        p.unmarshal_binary(Span(wrong))
    except e:
        raised = True
        assert_true(matches(e, ErrInvalidEncoding))
    assert_true(raised, "a wrong tag should be refused")

    # A position past the end of a buffer. Left unchecked this restores a
    # generator that silently refills on its first draw and so skips forward
    # in the stream, which is a wrong answer rather than a loud one.
    var far = good.copy()
    far[15] = 0xFF
    raised = False
    try:
        p.unmarshal_binary(Span(far))
    except e:
        raised = True
        assert_true(matches(e, ErrInvalidEncoding))
    assert_true(raised, "a position past the end should be refused")


def test_chacha8_unmarshal_rejects_a_bad_read_buffer_encoding() raises:
    # Go indexes `readBuf[8-len(buf):]` without checking the length byte, so
    # these two panic there with a slice bounds failure. Here they are refused.
    # See docs/deviations.md.
    var p = new_chacha8(chacha8_seed())
    var tag: List[UInt8] = [
        UInt8(ord("r")),
        UInt8(ord("e")),
        UInt8(ord("a")),
        UInt8(ord("d")),
        UInt8(ord("b")),
        UInt8(ord("u")),
        UInt8(ord("f")),
        UInt8(ord(":")),
    ]

    var nine = tag.copy()
    nine.append(9)
    var raised = False
    try:
        p.unmarshal_binary(Span(nine))
    except e:
        raised = True
        assert_true(matches(e, ErrInvalidEncoding))
    assert_true(raised, "a claim of nine pending bytes should be refused")

    var truncated = tag.copy()
    truncated.append(4)
    truncated.append(1)
    raised = False
    try:
        p.unmarshal_binary(Span(truncated))
    except e:
        raised = True
        assert_true(matches(e, ErrInvalidEncoding))
    assert_true(raised, "a truncated read buffer should be refused")

    var bare = tag.copy()
    raised = False
    try:
        p.unmarshal_binary(Span(bare))
    except e:
        raised = True
        assert_true(matches(e, ErrInvalidEncoding))
    assert_true(raised, "a read buffer tag and nothing else should be refused")
