"""The runtime path, and that it agrees with the compile time one.

`vsprintf` exists because a format string is not always known when the program
is built. It has none of the checking and it costs a box per argument, and the
one thing it must not do is print something different. So almost every case
below goes through `both`, which runs the two paths and compares them before it
compares either against Go.

The cases with no compile time twin are the ones at the bottom: a format string
that only exists at run time cannot be a parameter, so a wrong one has no
complaint to make and only has a marker to write. Those are checked against
Go's marker directly.

Go's own table is run through both paths as well, in
tests/generated/test_fmt.mojo, which is 326 more rows than are here.
"""

from std.testing import assert_equal

from core.fmt import Arg, Fields, Spec, sprintf, vsprintf, write_field
from core.io import Writer
from core.fmt import vappendf, vfprintf


def both[format: StaticString, *Ts: AnyType](want: String, *args: *Ts) raises:
    """The same call down both paths, checked against each other and against
    Go.

    Comparing the two paths to each other first is deliberate. When they
    disagree the failure says so, rather than saying only that one of them is
    not Go and leaving which one to be worked out.
    """
    var boxed = List[Arg]()
    comptime for i in range(len(Ts)):
        boxed.append(Arg(args[i]))

    var fast = sprintf[format](*args)
    var slow = vsprintf(String(format), boxed)
    assert_equal(
        slow,
        fast,
        String(
            "the two paths disagree on ", format, ": compile time gave ", fast
        ),
    )
    assert_equal(fast, want, String("Go's answer for ", format))


def test_verbs() raises:
    """One verb at a time, over every kind."""
    both["%d"](String("42"), 42)
    both["%v"](String("42"), 42)
    both["%s"](String("hi"), String("hi"))
    both["%q"](String('"hi"'), String("hi"))
    both["%t"](String("true"), True)
    both["%f"](String("3.140000"), 3.14)
    both["%g"](String("3.14"), 3.14)
    both["%x %X %o %b"](String("ff FF 10 101"), 255, 255, 8, 5)
    both["%c%c"](String("Hi"), 72, 105)
    both["%U"](String("U+1F600"), 0x1F600)


def test_flags_and_widths() raises:
    """The parts of a format that are not the verb."""
    both["%+d %+d"](String("+5 -5"), 5, -5)
    both["% d"](String(" 5"), 5)
    both["%08.3f"](String("0003.142"), 3.14159)
    both["%#x %#o %#b"](String("0xff 010 0b101"), 255, 8, 5)
    both["%5s|%-5s|"](String("   ab|cd   |"), String("ab"), String("cd"))
    both["%.2s"](String("hé"), String("héllo"))


def test_several_arguments() raises:
    """More than one verb, which no row of Go's table has."""
    both["%d %s %t"](String("1 two true"), 1, String("two"), True)
    both["a%sb%dc"](String("axb9c"), String("x"), 9)
    both[""](String(""))
    both["no verbs here"](String("no verbs here"))
    both["100%% sure"](String("100% sure"))


def test_argument_index() raises:
    """`%[n]d`, which the two parsers have to agree about.

    The counter it moves is the same counter that decides whether an argument
    was left over, so an off by one here shows up as a spurious `%!(EXTRA ...)`
    on one path and not the other.
    """
    both["%[2]d %[1]s"](String("7 a"), String("a"), 7)
    both["%[1]d %[1]d"](String("3 3"), 3)
    both["%[2]s%[1]s%[2]s"](String("bab"), String("a"), String("b"))


def test_star_width_and_precision() raises:
    """`%*d` and `%.*f`, where an argument sets the width or the precision."""
    both["%*d"](String("   42"), 5, 42)
    both["%-*d|"](String("42   |"), 5, 42)
    both["%*d"](String("42   "), -5, 42)
    both["%.*f"](String("3.14"), 2, 3.14159)
    both["%*.*f"](String("    3.142"), 9, 3, 3.14159)


def test_markers() raises:
    """The mistakes, which both paths have to get wrong in the same way.

    These do not go through `both`, because the compile time path would put a
    line on the compiler's output for each one and the suite build treats that
    as a failure. The compile time half of every case here is in
    tests/warnings/, where a complaint is what the file is for.
    """
    assert_equal(vsprintf(String("%d"), [Arg(String("hi"))]), "%!d(string=hi)")
    assert_equal(vsprintf(String("%t"), [Arg(1.5)]), "%!t(float64=1.5)")
    assert_equal(vsprintf(String("%d %d"), [Arg(1)]), "1 %!d(MISSING)")
    assert_equal(vsprintf(String("%d"), [Arg(1), Arg(2)]), "1%!(EXTRA int=2)")
    assert_equal(vsprintf(String("abc %"), List[Arg]()), "abc %!(NOVERB)")
    assert_equal(
        vsprintf(String("%*d"), [Arg(String("x")), Arg(4)]), "%!(BADWIDTH)4"
    )
    assert_equal(vsprintf(String("%☠"), [Arg(0)]), "%!☠(int=0)")
    assert_equal(vsprintf(String("%."), [Arg(3)]), "%!.(int=3)")


def test_a_format_built_at_run_time() raises:
    """The reason this entry point exists at all.

    A format assembled from pieces cannot be a parameter, and this is what it
    looks like: the caller has a table and a count and neither is in the
    source.
    """
    var table = [String("%d file"), String("%d files")]
    var n = 1
    assert_equal(vsprintf(table[0 if n == 1 else 1], [Arg(n)]), "1 file")
    n = 4
    assert_equal(vsprintf(table[0 if n == 1 else 1], [Arg(n)]), "4 files")


@fieldwise_init
struct Point(Fields):
    """A struct for the boxing rule below."""

    var x: Int
    var y: Int

    def write_fields(self, mut out: String, spec: Spec) raises:
        out += "{"
        if spec.named():
            out += "x:"
        write_field(out, spec, self.x)
        out += ", " if spec.go_syntax() else " "
        if spec.named():
            out += "y:"
        write_field(out, spec, self.y)
        out += "}"


def test_a_boxed_struct_remembers_what_it_was_boxed_for() raises:
    """The one thing that does not survive the boxing, said out loud.

    A struct is walked when it goes into the list, because that is the last
    moment its type is known, and the verb is not known until the format is
    read. So a box made for `%v` used under `%+v` is a marker rather than the
    `%v` text handed over as if nobody had asked for anything else.
    """
    var p = Point(1, 2)
    assert_equal(vsprintf(String("%v"), [Arg(p)]), "{1 2}")
    assert_equal(
        vsprintf(String("%+v"), [Arg(p)]),
        "%!v(value was not boxed for this verb)",
    )
    assert_equal(
        vsprintf(String("%+v"), [Arg(p, Spec(ord("v"), 64, -1, -1))]),
        "{x:1 y:2}",
    )


struct Sink(Copyable, Movable, Writer):
    """Keeps what it is given, and counts the calls."""

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


def test_the_other_writers() raises:
    """`vfprintf` and `vappendf`, which are `vsprintf` put somewhere else."""
    var sink = Sink()
    var n = vfprintf(sink, String("%d %s"), [Arg(1), Arg(String("two"))])
    assert_equal(n, 5)
    assert_equal(sink.text(), "1 two")
    assert_equal(sink.writes, 1)

    var buffer = List[Byte]()
    buffer.extend(String("head ").as_bytes())
    var m = vappendf(buffer, String("%d-%d"), [Arg(4), Arg(5)])
    assert_equal(m, 3)
    assert_equal(String(from_utf8=Span(buffer)), "head 4-5")
