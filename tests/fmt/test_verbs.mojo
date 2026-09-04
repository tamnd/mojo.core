"""Which verbs each kind accepts. Go's `print.go` type switches.

`core/fmt/check.mojo` says in one table which verbs go with which kinds, and
`core/fmt/value.mojo` dispatches on the same pairs in a chain of `comptime if`.
Two statements of one fact drift, and when they drift the compile time check
starts complaining about calls that work or staying quiet about calls that do
not. So this file walks every verb this library knows against every kind and
asserts the two agree: `one` writes a marker exactly when `accepts` says no.

The call goes to `one` rather than through a format string on purpose. A wrong
format string is a compile time complaint, and the suite build treats any
complaint of ours as a failure, so the calls that are meant to be refused are
made one level down where the checker never sees them. What the checker itself
says about a wrong format string is asserted in `tests/warnings/fmt_verbs.mojo`.
"""

from std.testing import assert_equal, assert_true

from core.fmt.check import accepts
from core.fmt.kind import (
    BOOLEAN,
    FLOAT,
    OTHER,
    SIGNED,
    TEXT,
    UNSIGNED,
    kind_of,
    name_of,
)
from core.fmt.value import one

comptime VERBS = [
    ord("v"),
    ord("d"),
    ord("b"),
    ord("o"),
    ord("O"),
    ord("x"),
    ord("X"),
    ord("c"),
    ord("q"),
    ord("U"),
    ord("s"),
    ord("t"),
    ord("e"),
    ord("E"),
    ord("f"),
    ord("F"),
    ord("g"),
    ord("G"),
    ord("p"),
    ord("z"),
]
"""Every verb Go has, and `%z`, which is not a verb at all.

`%p` and `%z` are here for the same reason: nothing accepts either of them, and
a table that only ever says yes proves nothing. `%p` is a pointer verb this
library does not implement, listed under waivers in docs/deviations.md.
"""


struct Named(Writable):
    """A type this library has no case for, so `kind_of` calls it `OTHER`.

    Go prints such a value through its `String` method and accepts the same
    four verbs it accepts for a string, which is what the sweep checks.
    """

    var text: String

    def __init__(out self, var text: String):
        self.text = text^

    def write_to[W: Writer](self, mut writer: W):
        writer.write(self.text)


def refused[verb: Int, T: Writable](value: T) raises -> Bool:
    """Whether `one` turned this pair into a marker instead of printing it."""
    var out = String()
    one[verb](out, 0, -1, -1, value)
    return out.startswith("%!")


def sweep[T: Writable](value: T, kind: Int) raises:
    """Every verb against one value, checked against the table."""
    assert_equal(
        kind_of[T](),
        kind,
        String("kind_of said the wrong kind for ", name_of[T]()),
    )
    comptime for i in range(len(VERBS)):
        comptime verb = VERBS[i]
        var marked = refused[verb](value)
        assert_equal(
            accepts(verb, kind),
            not marked,
            String(
                "%",
                chr(verb),
                " on ",
                name_of[T](),
                ": the table says ",
                accepts(verb, kind),
                " and the output ",
                "was a marker" if marked else "was not a marker",
            ),
        )


def test_signed() raises:
    """Every verb against the signed integer kind."""
    sweep(Int(65), SIGNED)
    sweep(Int8(65), SIGNED)
    sweep(Int16(65), SIGNED)
    sweep(Int32(65), SIGNED)
    sweep(Int64(65), SIGNED)


def test_unsigned() raises:
    """Every verb against the unsigned integer kind."""
    sweep(UInt(65), UNSIGNED)
    sweep(UInt8(65), UNSIGNED)
    sweep(UInt16(65), UNSIGNED)
    sweep(UInt32(65), UNSIGNED)
    sweep(UInt64(65), UNSIGNED)


def test_float() raises:
    """Every verb against the floating point kind."""
    sweep(Float64(1.5), FLOAT)
    sweep(Float32(1.5), FLOAT)


def test_text() raises:
    """Every verb against the string kind."""
    sweep(String("hi"), TEXT)
    sweep(StaticString("hi"), TEXT)


def test_boolean() raises:
    """Every verb against the boolean kind.

    `%t` and nothing else, `%v` aside. A bool is `Intable` and `Floatable` in
    Mojo, so a classifier built on traits would have let `%d` through here.
    """
    sweep(True, BOOLEAN)
    sweep(False, BOOLEAN)


def test_other() raises:
    """Every verb against a type this library has no case for."""
    sweep(Named("hello"), OTHER)


def test_marker_names_the_type() raises:
    """Go's `badVerb`, which names the type inside the marker.

    The sweep only asks whether a marker came out. This asks what it said, for
    one pair of each kind, because the text is compared against Go's byte for
    byte and `%!d(string=hi)` differs from `%!d(hi)` in a way a boolean check
    would never notice.
    """
    var out = String()
    one[ord("d")](out, 0, -1, -1, String("hi"))
    assert_equal(out, "%!d(string=hi)")

    out = String()
    one[ord("t")](out, 0, -1, -1, Float64(1.5))
    assert_equal(out, "%!t(float64=1.5)")

    out = String()
    one[ord("s")](out, 0, -1, -1, Int(7))
    assert_equal(out, "%!s(int=7)")

    out = String()
    one[ord("d")](out, 0, -1, -1, True)
    assert_equal(out, "%!d(bool=true)")


def test_unknown_type_is_called_value() raises:
    """The one place the marker is ours rather than Go's.

    Go prints the type name here and there is no reflection to ask for one, so
    a type outside the table is called `value`. This is written down in
    docs/deviations.md and asserted here so it cannot change by accident.
    """
    var out = String()
    one[ord("d")](out, 0, -1, -1, Named("hello"))
    assert_equal(out, "%!d(value=hello)")
    assert_true(accepts(ord("s"), OTHER))


def test_percent_v_accepts_everything() raises:
    """`%v` is the verb with no wrong argument, which is what makes it the one
    the marker itself prints with."""
    assert_true(accepts(ord("v"), SIGNED))
    assert_true(accepts(ord("v"), UNSIGNED))
    assert_true(accepts(ord("v"), FLOAT))
    assert_true(accepts(ord("v"), TEXT))
    assert_true(accepts(ord("v"), BOOLEAN))
    assert_true(accepts(ord("v"), OTHER))
