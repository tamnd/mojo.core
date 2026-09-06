"""The dump layout, to the byte. Go's `TestDump` and `TestDumper`.

The value of a hex dump is that it lines up with every other tool that prints
one, so these compare whole lines rather than checking that the bytes are in
there somewhere. Go's `expectedHexDump` is forty bytes starting at thirty,
chosen so that the text column has unprintable characters at the front, a
quotation mark and a backslash in the middle, and letters at the end.
"""

from std.testing import assert_equal, assert_true

from core.encoding.hex import dump, dumper
from core.errors import matches
from core.errors.codes import ErrDumperClosed

from ._fixtures import Sink

comptime _EXPECTED = (
    "00000000  1e 1f 20 21 22 23 24 25  26 27 28 29 2a 2b 2c 2d  |.."
    " !\"#$%&'()*+,-|\n00000010  2e 2f 30 31 32 33 34 35  36 37 38 39 3a 3b 3c"
    " 3d  |./0123456789:;<=|\n00000020  3e 3f 40 41 42 43 44 45                "
    "           |>?@ABCDE|\n"
)
"""Go's `expectedHexDump`, which is forty bytes counting up from thirty."""


def _counting(count: Int) -> List[UInt8]:
    """Go's `in`: bytes thirty upwards, which is what the dump above shows."""
    var out = List[UInt8](capacity=count)
    for i in range(count):
        out.append(UInt8(i + 30))
    return out^


def test_dump() raises:
    """Go's `TestDump`."""
    assert_equal(dump(Span(_counting(40))), _EXPECTED)


def test_dump_of_nothing_is_nothing() raises:
    """An empty line would be wrong here, and Go agrees."""
    assert_equal(dump(Span(List[UInt8]())), "")


def test_dumper_at_every_stride() raises:
    """Go's `TestDumper`: the same dump however the input is cut up.

    A dumper that kept a line buffer and flushed it on the wrong boundary would
    pass at a stride of sixteen and fail at every other one, which is why this
    walks all of them.
    """
    var data = _counting(40)
    for stride in range(1, len(data)):
        var d = dumper(Sink())
        var done = 0
        while done < len(data):
            var todo = done + stride
            if todo > len(data):
                todo = len(data)
            _ = d.write(Span(data)[done:todo])
            done = todo
        d.close()
        assert_equal(d.w.text(), _EXPECTED)


def test_dumper_closed_twice() raises:
    """Go's `TestDumper_doubleclose`. The second close writes nothing."""
    var d = dumper(Sink())
    _ = d.write("gopher".as_bytes())
    d.close()
    d.close()
    assert_equal(
        d.w.text(),
        (
            "00000000  67 6f 70 68 65 72                                "
            " |gopher|\n"
        ),
    )


def test_writing_after_closing_is_refused() raises:
    """Go returns an error here and this raises, which is the only difference.

    Go's `TestDumper_doubleclose` writes after closing and ignores what comes
    back, so the assertion in it is that nothing more was written. Both halves
    are here: the raise, and the output being what it was before.
    """
    var d = dumper(Sink())
    _ = d.write("gopher".as_bytes())
    d.close()
    var before = d.w.text()

    var refused = False
    try:
        _ = d.write("gopher".as_bytes())
    except e:
        refused = True
        assert_true(matches(e, ErrDumperClosed))
    assert_true(refused)
    assert_equal(d.w.text(), before)


def test_closing_before_writing_anything() raises:
    """Go's `TestDumper_earlyclose`: nothing in, nothing out."""
    var d = dumper(Sink())
    d.close()
    try:
        _ = d.write("gopher".as_bytes())
    except:
        pass
    assert_equal(d.w.text(), "")


def test_a_dump_of_exactly_one_line() raises:
    """Sixteen bytes fill a line, so `close` has nothing left to pad."""
    var data = List[UInt8]()
    for i in range(16):
        data.append(UInt8(ord("a") + i))
    assert_equal(
        dump(Span(data)),
        (
            "00000000  61 62 63 64 65 66 67 68  69 6a 6b 6c 6d 6e 6f 70"
            "  |abcdefghijklmnop|\n"
        ),
    )


def test_the_offset_column_counts_up() raises:
    """Three lines means three offsets, and the third is a short one."""
    var data = List[UInt8](length=33, fill=UInt8(ord("z")))
    var text = dump(Span(data))
    assert_true(text.find("00000000  ") == 0)
    assert_true(text.find("\n00000010  ") > 0)
    assert_true(text.find("\n00000020  ") > 0)
