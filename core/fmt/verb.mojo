"""One verb against one kind, written once for both paths.

There are two ways into this package. `sprintf` knows the format string while
the program is built, so it knows the verb as a parameter and the argument as a
type. `vsprintf` knows neither until the program runs, and its arguments arrive
boxed. The issue this package is written against asks that both produce the
same bytes, and the cheapest way to be sure of that is for there to be one
piece of code rather than two that are meant to agree.

So the verb is an ordinary `Int` here rather than a parameter, and the chains
below are the only place a verb is turned into a call. The compile time path
reaches them with a verb that is a constant at the call site, which the
optimiser folds; the runtime path reaches them after unboxing. What is not
shared between the two paths is only how a value is taken apart, which is a
question about types and cannot be shared, and the differential test compares
the two paths on every row of Go's table anyway.

The order of the branches follows Go's `print.go`, where the same decisions are
made by a type switch. What is a `default: p.badVerb(...)` there is a call to
one of the `_bad` functions here.
"""

from .kind import TEXT
from .plan import SHARP, SHARPV
from .write import (
    boolean,
    character,
    floating,
    hexadecimal,
    integer,
    quoted,
    quoted_rune,
    text,
    unicode,
)


def integer_verb(
    mut out: String,
    verb: Int,
    bits: UInt64,
    signed: Bool,
    name: StaticString,
    flags: Int,
    width: Int,
    prec: Int,
) raises:
    """An integer, already widened to 64 bits with its signedness beside it.

    Go does the same widening in `printArg`, which is what makes one routine
    enough for ten types. `%c` of `int32(-1)` is `U+FFFD` because the widening
    sign extends, so doing it any other way would be a different program.
    """
    if verb == ord("v"):
        # `%#v` of an unsigned integer is hexadecimal with a `0x` on it, which
        # is Go's `fmt0x64`. Signed values ignore the sharp flag.
        if (flags & SHARPV) != 0 and not signed:
            integer(
                out, bits, 16, signed, verb, False, flags | SHARP, width, prec
            )
        else:
            integer(out, bits, 10, signed, verb, False, flags, width, prec)
    elif verb == ord("d"):
        integer(out, bits, 10, signed, verb, False, flags, width, prec)
    elif verb == ord("b"):
        integer(out, bits, 2, signed, verb, False, flags, width, prec)
    elif verb == ord("o") or verb == ord("O"):
        integer(out, bits, 8, signed, verb, False, flags, width, prec)
    elif verb == ord("x"):
        integer(out, bits, 16, signed, verb, False, flags, width, prec)
    elif verb == ord("X"):
        integer(out, bits, 16, signed, verb, True, flags, width, prec)
    elif verb == ord("c"):
        character(out, bits, flags, width)
    elif verb == ord("q"):
        quoted_rune(out, bits, flags, width)
    elif verb == ord("U"):
        unicode(out, bits, flags, width, prec)
    else:
        _bad_integer(out, verb, bits, signed, name)


def float_verb(
    mut out: String,
    verb: Int,
    value: Float64,
    size: Int,
    name: StaticString,
    flags: Int,
    width: Int,
    prec: Int,
) raises:
    """A float, with the width of the type it came from beside it.

    `size` decides what the shortest text for the value is: `%v` of
    `Float32(1.0 / 3)` is `0.33333334` and the same division in double
    precision is `0.3333333333333333`.

    The default precision belongs to the verb rather than to the value. `%e` is
    six digits after the point and `%g` is however many read back exactly,
    which is what -1 asks `strconv` for.
    """
    if verb == ord("v"):
        floating(out, value, size, ord("g"), -1, flags, width, prec)
    elif verb == ord("b") or verb == ord("g") or verb == ord("G"):
        floating(out, value, size, verb, -1, flags, width, prec)
    elif verb == ord("x") or verb == ord("X"):
        floating(out, value, size, verb, -1, flags, width, prec)
    elif verb == ord("f") or verb == ord("e") or verb == ord("E"):
        floating(out, value, size, verb, 6, flags, width, prec)
    elif verb == ord("F"):
        floating(out, value, size, ord("f"), 6, flags, width, prec)
    else:
        _bad_float(out, verb, value, size, name)


def text_verb(
    mut out: String,
    verb: Int,
    s: String,
    kind: Int,
    name: StaticString,
    flags: Int,
    width: Int,
    prec: Int,
) raises:
    """A string, or whatever a value that writes itself wrote.

    `kind` is here for one byte of difference: `%#v` of a string is the quoted
    form and `%#v` of a type that wrote itself is not, because what it wrote is
    not a string literal and quoting it would claim it was.
    """
    if verb == ord("v"):
        if (flags & SHARPV) != 0 and kind == TEXT:
            quoted(out, s, flags, width, prec)
        else:
            text(out, s, flags, width, prec)
    elif verb == ord("s"):
        text(out, s, flags, width, prec)
    elif verb == ord("q"):
        quoted(out, s, flags, width, prec)
    elif verb == ord("x"):
        hexadecimal(out, s, False, flags, width, prec)
    elif verb == ord("X"):
        hexadecimal(out, s, True, flags, width, prec)
    else:
        _bad_text(out, verb, s, kind, name)


def bool_verb(
    mut out: String,
    verb: Int,
    value: Bool,
    name: StaticString,
    flags: Int,
    width: Int,
    prec: Int,
) raises:
    """A boolean, which only `%v` and `%t` print."""
    if verb == ord("v") or verb == ord("t"):
        boolean(out, value, flags, width)
    else:
        _bad_bool(out, verb, value, name)


def opaque_verb(mut out: String, verb: Int) raises:
    """A value that can neither write itself nor list its fields.

    There is no text to put in the brackets, because getting any would need the
    reflection this library does not have. The complaint on the compiler's
    output is where the type is named; this is only what is left at run time.
    """
    _marker(out, verb, "value", String())


def _marker(
    mut out: String, verb: Int, name: StaticString, rendered: String
) raises:
    """Go's `%!d(string=hi)`. Go's `badVerb`.

    The type is named the way Go names it, because this text is compared
    against Go's byte for byte. A type this library does not know has no name
    to give and is called `value`, which is the one place the marker is ours
    rather than Go's.
    """
    out += "%!"
    out += chr(verb)
    out += "("
    out += name
    if rendered.byte_length() > 0:
        out += "="
        out += rendered
    out += ")"


def _bad_integer(
    mut out: String, verb: Int, bits: UInt64, signed: Bool, name: StaticString
) raises:
    """The marker for an integer, with the value printed as `%v` inside it.

    `%v` is accepted by every kind, so this recursion is one deep and always
    ends. The same is true of the three below it.
    """
    var rendered = String()
    integer_verb(rendered, ord("v"), bits, signed, name, 0, -1, -1)
    _marker(out, verb, name, rendered)


def _bad_float(
    mut out: String, verb: Int, value: Float64, size: Int, name: StaticString
) raises:
    """The marker for a float."""
    var rendered = String()
    float_verb(rendered, ord("v"), value, size, name, 0, -1, -1)
    _marker(out, verb, name, rendered)


def _bad_text(
    mut out: String, verb: Int, s: String, kind: Int, name: StaticString
) raises:
    """The marker for a string, or for anything that wrote itself."""
    var rendered = String()
    text_verb(rendered, ord("v"), s, kind, name, 0, -1, -1)
    _marker(out, verb, name, rendered)


def _bad_bool(
    mut out: String, verb: Int, value: Bool, name: StaticString
) raises:
    """The marker for a boolean."""
    var rendered = String()
    bool_verb(rendered, ord("v"), value, name, 0, -1, -1)
    _marker(out, verb, name, rendered)
