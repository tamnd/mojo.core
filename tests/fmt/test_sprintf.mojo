"""Formatting, by hand. Go's `fmt_test.go`, the parts its table cannot reach.

Every row of Go's `fmtTests` has exactly one value in it, so the harvest in
`tests/generated/test_fmt.mojo` says nothing about a format with two arguments,
an explicit argument index, or a `*` width. Those are the parts of the parser
with the most to get wrong and they are here, with the answers taken from Go
1.27.1 rather than reasoned about.

The writer forms are here too. `sprintf` builds a string and the other three
put the same string somewhere else, so what is worth checking about them is the
somewhere else and the count they give back, not the formatting again.
"""

from std.testing import assert_equal, assert_true

from core.io import Writer
from core.fmt import appendf, fprintf, sprintf


struct Sink(Copyable, Movable, Writer):
    """Keeps what it is given, and counts the calls.

    The count is what says `fprintf` writes once. Formatting straight into a
    writer verb by verb would pass every assertion about the bytes and fail
    this one, and for a writer that is a syscall each time it is the difference
    that matters.
    """

    var got: List[Byte]
    var writes: Int

    def __init__(out self):
        self.got = List[Byte]()
        self.writes = 0

    def write[o: Origin](mut self, data: Span[Byte, o]) raises -> Int:
        self.writes += 1
        for b in data:
            self.got.append(b)
        return len(data)

    def text(self) raises -> String:
        return String(from_utf8=Span(self.got))


def test_several_arguments() raises:
    """More than one verb, which no row of Go's table has."""
    assert_equal(sprintf["%d %s %t"](1, String("two"), True), "1 two true")
    assert_equal(sprintf["%s and %s"](String("a"), String("b")), "a and b")
    assert_equal(sprintf["a%sb%dc"](String("x"), 9), "axb9c")
    assert_equal(
        sprintf["%v %v %v %v"](1, 1.5, String("s"), False), "1 1.5 s false"
    )


def test_no_verbs() raises:
    """A format with nothing in it, which still has to come out."""
    assert_equal(sprintf[""](), "")
    assert_equal(sprintf["no verbs here"](), "no verbs here")


def test_percent() raises:
    """`%%`, which consumes no argument. Go's `%%` case."""
    assert_equal(sprintf["100%% sure"](), "100% sure")
    assert_equal(sprintf["%d%%"](50), "50%")


def test_argument_index() raises:
    """`%[n]d`, which says which argument to take rather than taking the next.

    The second one is the reason this exists: an index can name the same
    argument twice, so the count of arguments used is not the count of verbs.
    """
    assert_equal(sprintf["%[2]d %[1]s"](String("a"), 7), "7 a")
    assert_equal(sprintf["%[1]d %[1]d"](3), "3 3")
    assert_equal(sprintf["%[2]s%[1]s%[2]s"](String("a"), String("b")), "bab")


def test_star_width() raises:
    """`%*d`, where the width is an argument.

    A negative width is a left justification with the sign taken off, which is
    Go's rule and is the one case where an argument sets a flag.
    """
    assert_equal(sprintf["%*d"](5, 42), "   42")
    assert_equal(sprintf["%-*d|"](5, 42), "42   |")
    assert_equal(sprintf["%*d"](-5, 42), "42   ")


def test_star_precision() raises:
    """`%.*f`, and both of them at once."""
    assert_equal(sprintf["%.*f"](2, 3.14159), "3.14")
    assert_equal(sprintf["%*.*f"](9, 3, 3.14159), "    3.142")


def test_width_counts_runes() raises:
    """A width is runes and a precision on a string is runes too.

    `héllo` is five characters and six bytes. A width counted in bytes would
    pad it by one and a precision counted in bytes would cut the `é` in half.
    """
    assert_equal(
        sprintf["%5s|%-5s|"](String("ab"), String("cd")), "   ab|cd   |"
    )
    assert_equal(sprintf["%5s"](String("héllo")), "héllo")
    assert_equal(sprintf["%.2s"](String("héllo")), "hé")


def test_flags() raises:
    """The flags, against the verbs they change."""
    assert_equal(sprintf["%+d %+d"](5, -5), "+5 -5")
    assert_equal(sprintf["% d"](5), " 5")
    assert_equal(sprintf["%08.3f"](3.14159), "0003.142")
    assert_equal(sprintf["%x %X %o %b"](255, 255, 8, 5), "ff FF 10 101")
    assert_equal(sprintf["%#x %#o %#b"](255, 8, 5), "0xff 010 0b101")


def test_floats_and_runes() raises:
    """The four float verbs beside each other, and the two rune ones."""
    assert_equal(
        sprintf["%e %E %g %G"](1234.5678, 1234.5678, 1234.5678, 1234.5678),
        "1.234568e+03 1.234568E+03 1234.5678 1234.5678",
    )
    assert_equal(sprintf["%c%c"](72, 105), "Hi")
    assert_equal(sprintf["%q %q"](Int32(ord("x")), String("x")), "'x' \"x\"")
    assert_equal(sprintf["%U"](0x1F600), "U+1F600")


def test_fprintf() raises:
    """Go's `Fprintf`: the text to a writer, and the byte count back."""
    var sink = Sink()
    var n = fprintf["%d %s"](sink, 1, String("two"))
    assert_equal(n, 5)
    assert_equal(sink.text(), "1 two")
    assert_equal(sink.writes, 1)


def test_appendf() raises:
    """Go's `Appendf`: onto the end of what is already there.

    Go gives back the grown slice and this grows the caller's list, which is
    the choice `core.strconv` made for its append forms and is written down in
    docs/deviations.md. What is asserted here is that it appends rather than
    replaces, since a version that replaced would pass every other check.
    """
    var buffer = List[Byte]()
    buffer.extend(String("head ").as_bytes())
    var n = appendf["%d-%d"](buffer, 4, 5)
    assert_equal(n, 3)
    assert_equal(String(from_utf8=Span(buffer)), "head 4-5")


def test_empty_write_is_still_a_write() raises:
    """A format with nothing to say still reaches the writer.

    Go's `Fprintf` calls through to the writer whatever the format was, and a
    short circuit here would change what a caller counting writes sees.
    """
    var sink = Sink()
    var n = fprintf[""](sink)
    assert_equal(n, 0)
    assert_equal(sink.writes, 1)
    assert_true(len(sink.got) == 0)
