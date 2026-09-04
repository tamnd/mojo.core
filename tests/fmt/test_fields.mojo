"""The three ways a value of a type this library never heard of gets printed.

Go answers all three with reflection. There is none here, so there are three
different answers and which one applies is decided while the program is built.
This file has one type for each and checks that the right one wins, because the
order between them is a choice rather than a consequence and a change to
`kind_of` could silently reverse it.

The expected text is Go's. A Go struct with a `String` method prints what
`String` returns under `%v`, one without prints `{1 hello}` under `%v` and
`{X:1 Y:hello}` under `%+v`, and there is nothing in Go that corresponds to the
third case because Go can always reflect.
"""

from std.testing import assert_equal, assert_true

from core.fmt import Fields, Spec, sprintf, write_field
from core.fmt.kind import OPAQUE, OTHER, STRUCT, kind_of


@fieldwise_init
struct Writes(Writable):
    """Level one. Go's `Stringer`, and it wins over everything below."""

    var n: Int

    def write_to[W: Writer](self, mut w: W):
        w.write("writes(")
        w.write(self.n)
        w.write(")")


@fieldwise_init
struct Both(Fields, Writable):
    """A type that could go either way, which is why the order is tested.

    `write_fields` would print `{7}` and `write_to` prints `both`. Seeing
    `both` come out is the assertion that `Writable` is preferred, and it is
    the only way to tell the two branches apart from outside.
    """

    var n: Int

    def write_to[W: Writer](self, mut w: W):
        w.write("both")

    def write_fields(self, mut out: String, spec: Spec) raises:
        out += "{"
        write_field(out, spec, self.n)
        out += "}"


@fieldwise_init
struct Point(Fields):
    """Level two. The walk a generator will write, written by hand for now.

    The shape is Go's: braces around the fields, a space between them under
    `%v` and `%+v`, a comma under `%#v`, and the type name in front only under
    `%#v`. The verb travels down with the spec, which is what makes `%d` of
    this reach the fields rather than stopping here.
    """

    var x: Int
    var y: String

    def write_fields(self, mut out: String, spec: Spec) raises:
        if spec.go_syntax():
            out += "Point"
        out += "{"
        if spec.named():
            out += "x:"
        write_field(out, spec, self.x)
        out += ", " if spec.go_syntax() else " "
        if spec.named():
            out += "y:"
        write_field(out, spec, self.y)
        out += "}"


@fieldwise_init
struct Nested(Fields):
    """A struct holding a struct, which is the case a flat walk gets wrong."""

    var name: String
    var at: Point

    def write_fields(self, mut out: String, spec: Spec) raises:
        if spec.go_syntax():
            out += "Nested"
        out += "{"
        if spec.named():
            out += "name:"
        write_field(out, spec, self.name)
        out += ", " if spec.go_syntax() else " "
        if spec.named():
            out += "at:"
        write_field(out, spec, self.at)
        out += "}"


@fieldwise_init
struct Opaque:
    """Level three. Neither `Writable` nor `Fields`, so there is nothing to
    print and nothing that could find out what there would have been.

    Only its classification is asked about here. Printing one complains while
    the program is built, and the suite build treats a complaint of ours as a
    failure, so the printing half lives in `tests/warnings/fmt_opaque.mojo`
    where a complaint is what the file is for. That file checks the markers
    too.
    """

    var n: Int


def test_kinds_are_what_they_look_like() raises:
    """The classification itself, before anything is printed with it.

    Asserting this separately is worth the four lines: every expectation below
    is really an expectation about which branch of `kind_of` was taken, and a
    failure here says so directly rather than through a string comparison.
    """
    assert_equal(kind_of[Writes](), OTHER)
    assert_equal(kind_of[Both](), OTHER)
    assert_equal(kind_of[Point](), STRUCT)
    assert_equal(kind_of[Opaque](), OPAQUE)


def test_writable_wins() raises:
    """Level one, and that it is preferred to level two."""
    assert_equal(sprintf["%v"](Writes(3)), "writes(3)")
    assert_equal(sprintf["%s"](Writes(3)), "writes(3)")
    assert_equal(sprintf["%v"](Both(7)), "both")
    assert_equal(sprintf["%+v"](Both(7)), "both")


def test_fields_walk() raises:
    """Level two, at the three levels of `%v` Go has."""
    var p = Point(1, String("hello"))
    assert_equal(sprintf["%v"](p), "{1 hello}")
    assert_equal(sprintf["%+v"](p), "{x:1 y:hello}")
    assert_equal(sprintf["%#v"](p), 'Point{x:1, y:"hello"}')


def test_the_verb_reaches_the_fields() raises:
    """Go hands the verb to each field rather than to the struct.

    `%d` of a struct holding an `Int` and a `String` is one good field and one
    marker, which is Go's `{1 %!d(string=hello)}`. A struct that answered the
    verb itself could not produce that, and a struct that ignored it would
    print the fields as if `%d` had been `%v`.
    """
    var p = Point(1, String("hello"))
    assert_equal(sprintf["%d"](p), "{1 %!d(string=hello)}")
    assert_equal(sprintf["%s"](p), "{%!s(int=1) hello}")
    # `%q` of an integer is Go's quoted rune, not a marker, so this row is two
    # good fields printed two different ways rather than a good one and a bad
    # one. It is here because it is the case where handing the verb down looks
    # wrong and is right.
    assert_equal(sprintf["%q"](p), "{'\\x01' \"hello\"}")


def test_nesting() raises:
    """A struct inside a struct, with the spec travelling all the way down."""
    var n = Nested(String("home"), Point(2, String("x")))
    assert_equal(sprintf["%v"](n), "{home {2 x}}")
    assert_equal(sprintf["%+v"](n), "{name:home at:{x:2 y:x}}")
    assert_equal(sprintf["%#v"](n), 'Nested{name:"home", at:Point{x:2, y:"x"}}')


def test_width_and_precision_reach_the_fields() raises:
    """A width on a struct is a width on each field, which is Go's rule.

    Go applies the whole spec to every field rather than to the rendered
    struct, so `%5v` of two fields pads both of them and not the braces.
    """
    var p = Point(1, String("ab"))
    assert_equal(sprintf["%5v"](p), "{    1    ab}")
    assert_true(sprintf["%.1v"](p) == "{1 a}")
