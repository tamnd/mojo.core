"""The sliding window, driven by hand. Go's `dict_decoder_test.go`.

Go's test is one long script of writes and copies against a two kilobyte
window, and the window is deliberately smaller than the text so that the copies
wrap around the end of it. Nothing here is a DEFLATE stream; the point is that
the window on its own produces the right bytes for a sequence of commands, so
that when the decompressor gets a wrong answer later it is the decompressor
that is wrong.

The interesting commands are the last few. A copy whose distance is the whole
history is the largest legal one. A copy whose length is many times its
distance is a repeated run, which is DEFLATE's only way to spell one. A copy at
distance one is that taken to its limit, sixty of the same byte from one
command.
"""

from std.testing import assert_equal

from core.compress.flate.dict import _DictDecoder
from core.io import Byte

from ._fixtures import as_bytes

comptime _ABC = "ABC\n"
"""Four bytes, repeated sixty times by one copy below."""

comptime _FOX = "The quick brown fox jumped over the lazy dog!\n"
"""Forty five bytes, repeated ten times the same way."""

comptime _POEM = (
    "The Road Not Taken\nRobert Frost\n"
    + "\n"
    + "Two roads diverged in a yellow wood,\n"
    + "And sorry I could not travel both\n"
    + "And be one traveler, long I stood\n"
    + "And looked down one as far as I could\n"
    + "To where it bent in the undergrowth;\n"
    + "\n"
    + "Then took the other, as just as fair,\n"
    + "And having perhaps the better claim,\n"
    + "Because it was grassy and wanted wear;\n"
    + "Though as for that the passing there\n"
    + "Had worn them really about the same,\n"
    + "\n"
    + "And both that morning equally lay\n"
    + "In leaves no step had trodden black.\n"
    + "Oh, I kept the first for another day!\n"
    + "Yet knowing how way leads on to way,\n"
    + "I doubted if I should ever come back.\n"
    + "\n"
    + "I shall be telling this with a sigh\n"
    + "Somewhere ages and ages hence:\n"
    + "Two roads diverged in a wood, and I-\n"
    + "I took the one less traveled by,\n"
    + "And that has made all the difference.\n"
)
"""Go's `poem`. Seven hundred and sixty three bytes of text that repeats
itself enough to be worth compressing, which is why Go chose it."""


def _refs() -> List[Int]:
    """Go's `poemRefs`, flattened to pairs of distance and length.

    A distance of zero means the next `length` bytes of the poem are inserted
    as they are; anything else means they are copied from that far back. This
    is what an encoder would have produced for the poem, and reading it back
    has to give the poem again.
    """
    var r: List[Int] = [
        0,
        38,
        33,
        3,
        0,
        48,
        79,
        3,
        0,
        11,
        34,
        5,
        0,
        6,
        23,
        7,
        0,
        8,
        50,
        3,
        0,
        2,
        69,
        3,
        34,
        5,
        0,
        4,
        97,
        3,
        0,
        4,
        43,
        5,
        0,
        6,
        7,
        4,
        88,
        7,
        0,
        12,
        80,
        3,
        0,
        2,
        141,
        4,
        0,
        1,
        196,
        3,
        0,
        3,
        157,
        3,
        0,
        6,
        181,
        3,
        0,
        2,
        23,
        3,
        77,
        3,
        28,
        5,
        128,
        3,
        110,
        4,
        70,
        3,
        0,
        4,
        85,
        6,
        0,
        2,
        182,
        6,
        0,
        4,
        133,
        3,
        0,
        7,
        47,
        5,
        0,
        20,
        112,
        5,
        0,
        1,
        58,
        3,
        0,
        8,
        59,
        3,
        0,
        4,
        173,
        3,
        0,
        5,
        114,
        3,
        0,
        4,
        92,
        5,
        0,
        2,
        71,
        3,
        0,
        2,
        76,
        5,
        0,
        1,
        46,
        3,
        96,
        4,
        130,
        4,
        0,
        3,
        360,
        3,
        0,
        3,
        178,
        5,
        0,
        7,
        75,
        3,
        0,
        3,
        45,
        6,
        0,
        6,
        299,
        6,
        180,
        3,
        70,
        6,
        0,
        1,
        48,
        3,
        66,
        4,
        0,
        3,
        47,
        5,
        0,
        9,
        325,
        3,
        0,
        1,
        359,
        3,
        318,
        3,
        0,
        2,
        199,
        3,
        0,
        1,
        344,
        3,
        0,
        3,
        248,
        3,
        0,
        10,
        310,
        3,
        0,
        3,
        93,
        6,
        0,
        3,
        252,
        3,
        157,
        4,
        0,
        2,
        273,
        5,
        0,
        14,
        99,
        4,
        0,
        1,
        464,
        4,
        0,
        2,
        92,
        4,
        495,
        3,
        0,
        1,
        322,
        4,
        16,
        4,
        0,
        3,
        402,
        3,
        0,
        2,
        237,
        4,
        0,
        2,
        432,
        4,
        0,
        1,
        483,
        5,
        0,
        2,
        294,
        4,
        0,
        2,
        306,
        3,
        113,
        5,
        0,
        1,
        26,
        4,
        164,
        3,
        488,
        4,
        0,
        1,
        542,
        3,
        248,
        6,
        0,
        5,
        205,
        3,
        0,
        8,
        48,
        3,
        449,
        6,
        0,
        2,
        192,
        3,
        328,
        4,
        9,
        5,
        433,
        3,
        0,
        3,
        622,
        25,
        615,
        5,
        46,
        5,
        0,
        2,
        104,
        3,
        475,
        10,
        549,
        3,
        0,
        4,
        597,
        8,
        314,
        3,
        0,
        1,
        473,
        6,
        317,
        5,
        0,
        1,
        400,
        3,
        0,
        3,
        109,
        3,
        151,
        3,
        48,
        4,
        0,
        4,
        125,
        3,
        108,
        3,
        0,
        2,
    ]
    return r^


def _flush(mut dd: _DictDecoder, mut got: List[Byte]):
    """Move whatever the window is holding into `got`."""
    var ready = dd.read_flush()
    for i in range(ready[0], ready[1]):
        got.append(dd.hist[i])


def _write_copy(
    mut dd: _DictDecoder, dist: Int, length: Int, mut got: List[Byte]
):
    """Go's `writeCopy` closure: copy, flushing whenever the window fills."""
    var left = length
    while left > 0:
        var n = dd.try_write_copy(dist, left)
        if n == 0:
            n = dd.write_copy(dist, left)
        left -= n
        if dd.avail_write() == 0:
            _flush(dd, got)


def _write_bytes[
    o: Origin
](mut dd: _DictDecoder, data: Span[Byte, o], mut got: List[Byte]):
    """Go's `writeString` closure, and the other half of `write_mark`.

    Go asks the window for a slice and copies into it. A method here cannot
    hand back a slice of a field, so the caller writes through `hist` and says
    how much it wrote, which is the same two steps with the borrow made
    explicit.
    """
    var at = 0
    while at < len(data):
        var room = dd.avail_write()
        var n = len(data) - at
        if n > room:
            n = room
        for i in range(n):
            dd.hist[dd.wr_pos + i] = data[at + i]
        dd.write_mark(n)
        at += n
        if dd.avail_write() == 0:
            _flush(dd, got)


def test_the_window_replays_the_poem() raises:
    """Go's `TestDictDecoder`, from the first dot to the last copy."""
    var got = List[Byte]()
    var want = List[Byte]()
    var dd = _DictDecoder()
    var none = List[Byte]()
    dd.reset(1 << 11, Span(none))

    var dot = as_bytes(".")
    _write_bytes(dd, Span(dot), got)
    want.append(Byte(ord(".")))

    var poem = as_bytes(_POEM)
    var refs = _refs()
    var at = 0
    for i in range(0, len(refs), 2):
        var dist = refs[i]
        var length = refs[i + 1]
        if dist == 0:
            _write_bytes(dd, Span(poem)[at : at + length], got)
        else:
            _write_copy(dd, dist, length, got)
        at += length
    for i in range(len(poem)):
        want.append(poem[i])

    # The largest legal distance, which is the whole history.
    _write_copy(dd, dd.hist_size(), 33, got)
    for i in range(33):
        var b = want[i]
        want.append(b)

    # A length sixty times its distance, which is how DEFLATE spells a run.
    var abc = as_bytes(_ABC)
    _write_bytes(dd, Span(abc), got)
    _write_copy(dd, len(abc), 59 * len(abc), got)
    for _ in range(60):
        for i in range(len(abc)):
            want.append(abc[i])

    var fox = as_bytes(_FOX)
    _write_bytes(dd, Span(fox), got)
    _write_copy(dd, len(fox), 9 * len(fox), got)
    for _ in range(10):
        for i in range(len(fox)):
            want.append(fox[i])

    # Distance one, the same byte ten times from one command.
    _write_bytes(dd, Span(dot), got)
    _write_copy(dd, 1, 9, got)
    for _ in range(10):
        want.append(Byte(ord(".")))

    var loud = as_bytes(String(_POEM).upper())
    _write_bytes(dd, Span(loud), got)
    _write_copy(dd, len(loud), 7 * len(loud), got)
    for _ in range(8):
        for i in range(len(loud)):
            want.append(loud[i])

    # A copy of the whole history again, now that it has wrapped many times.
    var size = dd.hist_size()
    var base = len(want) - size
    _write_copy(dd, size, 10, got)
    for i in range(10):
        var b = want[base + i]
        want.append(b)

    _flush(dd, got)
    assert_equal(len(got), len(want))
    for i in range(len(want)):
        assert_equal(got[i], want[i])
