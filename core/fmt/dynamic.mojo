"""Formatting with a format string nobody knew until the program ran.

Go's `Printf` takes a runtime format string without noticing, because Go reads
the format on every call anyway. This package reads it while the program is
built, which is where all the checking comes from, and that trade has to be
paid for somewhere. This is where: a second entry point that takes a `String`
and a `List[Arg]`, does no checking at all, and is slower.

It is the honest answer for a caller building a format string from a
translation table, and it is the wrong answer for everything else. A format
string written in the source belongs in `sprintf`, where a `%d` on a string is
found before the program runs.

What is the same between the two paths is deliberate and is most of the point.
The format string goes through the same parser in plan.mojo, and each verb is
turned into a call by the same functions in verb.mojo. What is different is
only how a value gets taken apart, which is a question about types and cannot
be shared. `tests/fmt/test_dynamic.mojo` runs every row of Go's own table
through both paths and compares the bytes, because a promise like that is worth
nothing without something that would notice it breaking.

The markers are Go's, the same ones the compile time path writes. The
difference is that nobody was told about them while the program was built.
"""

from core.io import Writer

from .arg import Arg, write_arg
from .plan import (
    BADINDEX,
    MINUS,
    NOVERB,
    PERCENT,
    REORDERED,
    TAIL,
    ZERO,
    pieces,
)
from .kind import SIGNED, UNSIGNED
from .out import to_stdout


def vformat_to[
    o: ImmOrigin
](mut out: String, format: StringSlice[o], args: List[Arg]) raises:
    """The formatted text onto the end of `out`.

    This is `format_to` with every `comptime if` turned into an `if`. Reading
    the two side by side is the intended way to check that they agree, and the
    order of the decisions is the same in both on purpose.
    """
    var plan = pieces(format)
    var count = len(args)
    var used = plan[len(plan) - 1].arg
    var reordered = (plan[len(plan) - 1].flags & REORDERED) != 0

    for i in range(len(plan)):
        out += plan[i].literal
        var verb = plan[i].verb

        if verb == PERCENT:
            out += "%"
        elif verb == NOVERB:
            out += "%!(NOVERB)"
        elif verb == BADINDEX:
            out += "%!(BADINDEX)"
        elif verb != TAIL:
            var width = plan[i].width
            var prec = plan[i].prec
            var flags = plan[i].flags

            # `%*d` and `%.*f`, where the width or the precision is an
            # argument. A negative width is how Go spells the minus flag from
            # an argument, and a negative precision is no precision at all.
            var wa = plan[i].width_arg
            if wa >= 0:
                if wa >= count or not _integral(args[wa].kind):
                    out += "%!(BADWIDTH)"
                else:
                    width = _as_index(args[wa])
                    if width < 0:
                        width = -width
                        flags = (flags | MINUS) & ~ZERO

            var pa = plan[i].prec_arg
            if pa >= 0:
                if pa >= count or not _integral(args[pa].kind):
                    out += "%!(BADPREC)"
                else:
                    prec = _as_index(args[pa])
                    if prec < 0:
                        prec = -1

            var a = plan[i].arg
            if a >= count:
                out += "%!"
                out += chr(verb)
                out += "(MISSING)"
            else:
                write_arg(out, verb, flags, width, prec, args[a])

    # Arguments nothing used. Go stops reporting these once a format has chosen
    # an argument by index, because after that they are not being consumed in
    # order and "one too many" stops meaning anything.
    if count > used and not reordered:
        out += "%!(EXTRA "
        for j in range(used, count):
            if j > used:
                out += ", "
            out += args[j].name
            out += "="
            write_arg(out, ord("v"), 0, -1, -1, args[j])
        out += ")"


def _integral(kind: Int) -> Bool:
    """Whether a `*` width or precision can be read from this kind.

    The same rule as `check.integral`, asked of a boxed argument rather than of
    a type.
    """
    return kind == SIGNED or kind == UNSIGNED


def _as_index(arg: Arg) -> Int:
    """A boxed integer as a width or a precision.

    The sign has to survive, because a negative width is Go's way of spelling
    the minus flag from an argument.
    """
    if arg.kind == UNSIGNED:
        return Int(arg.bits)
    return Int(arg.bits.cast[DType.int64]())


def vsprintf[
    o: ImmOrigin
](format: StringSlice[o], args: List[Arg]) raises -> String:
    """The formatted text as a string. Go's `Sprintf` with a runtime format."""
    var out = String()
    vformat_to(out, format, args)
    return out^


def vprintf[o: ImmOrigin](format: StringSlice[o], args: List[Arg]) raises:
    """The formatted text on standard output. Go's `Printf` with a runtime
    format."""
    to_stdout(vsprintf(format, args))


def vfprintf[
    o: ImmOrigin, W: Writer
](mut dst: W, format: StringSlice[o], args: List[Arg]) raises -> Int:
    """The formatted text to a writer, and how many bytes that took. Go's
    `Fprintf` with a runtime format."""
    var out = vsprintf(format, args)
    return dst.write(out.as_bytes())


def vappendf[
    o: ImmOrigin
](mut dst: List[Byte], format: StringSlice[o], args: List[Arg]) raises -> Int:
    """The formatted text onto the end of `dst`, and how many bytes that took.
    Go's `Appendf` with a runtime format."""
    var out = vsprintf(format, args)
    dst.extend(out.as_bytes())
    return out.byte_length()
