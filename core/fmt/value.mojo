"""One argument, printed with one verb.

The verb is a compile time parameter, so the chain below is not a switch that
runs: it is a chain the compiler walks once per call site, keeping the one
branch that applies and discarding the rest. A `%d` on an `Int` compiles to the
call to `integer` and nothing else, and the verb never exists as a value in the
program.

The order of the branches follows Go's `print.go`, where the same decisions are
made at run time by a type switch. What is a `default: p.badVerb(...)` there is
a `else: bad_verb[...]` here, and it is reached in the same cases, so a program
that gets it wrong still prints what Go prints.
"""

from .kind import (
    BOOLEAN,
    FLOAT,
    OTHER,
    SIGNED,
    TEXT,
    UNSIGNED,
    as_bool,
    as_float64,
    as_text,
    as_uint64,
    float_bits,
    kind_of,
    name_of,
)
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


def one[
    verb: Int, T: Writable
](mut out: String, flags: Int, width: Int, prec: Int, value: T) raises:
    """`value` written with `verb`, or Go's marker when the two do not go
    together."""
    comptime kind = kind_of[T]()

    comptime if kind == SIGNED or kind == UNSIGNED:
        comptime signed = kind == SIGNED
        comptime if verb == ord("v"):
            # `%#v` of an unsigned integer is hexadecimal with a `0x` on it,
            # which is Go's `fmt0x64`. Signed values ignore the sharp flag.
            if (flags & SHARPV) != 0 and not signed:
                var over = flags | SHARP
                integer(
                    out,
                    as_uint64(value),
                    16,
                    signed,
                    verb,
                    False,
                    over,
                    width,
                    prec,
                )
            else:
                integer(
                    out,
                    as_uint64(value),
                    10,
                    signed,
                    verb,
                    False,
                    flags,
                    width,
                    prec,
                )
        elif verb == ord("d"):
            integer(
                out,
                as_uint64(value),
                10,
                signed,
                verb,
                False,
                flags,
                width,
                prec,
            )
        elif verb == ord("b"):
            integer(
                out,
                as_uint64(value),
                2,
                signed,
                verb,
                False,
                flags,
                width,
                prec,
            )
        elif verb == ord("o") or verb == ord("O"):
            integer(
                out,
                as_uint64(value),
                8,
                signed,
                verb,
                False,
                flags,
                width,
                prec,
            )
        elif verb == ord("x"):
            integer(
                out,
                as_uint64(value),
                16,
                signed,
                verb,
                False,
                flags,
                width,
                prec,
            )
        elif verb == ord("X"):
            integer(
                out,
                as_uint64(value),
                16,
                signed,
                verb,
                True,
                flags,
                width,
                prec,
            )
        elif verb == ord("c"):
            character(out, as_uint64(value), flags, width)
        elif verb == ord("q"):
            quoted_rune(out, as_uint64(value), flags, width)
        elif verb == ord("U"):
            unicode(out, as_uint64(value), flags, width, prec)
        else:
            bad_verb[verb](out, value)

    elif kind == FLOAT:
        comptime size = float_bits[T]()
        # The default precision is part of the verb rather than of the value:
        # `%e` is six digits after the point and `%g` is however many read
        # back exactly, which is what -1 asks `strconv` for.
        comptime if verb == ord("v"):
            floating(
                out, as_float64(value), size, ord("g"), -1, flags, width, prec
            )
        elif verb == ord("b") or verb == ord("g") or verb == ord("G"):
            floating(out, as_float64(value), size, verb, -1, flags, width, prec)
        elif verb == ord("x") or verb == ord("X"):
            floating(out, as_float64(value), size, verb, -1, flags, width, prec)
        elif verb == ord("f") or verb == ord("e") or verb == ord("E"):
            floating(out, as_float64(value), size, verb, 6, flags, width, prec)
        elif verb == ord("F"):
            floating(
                out, as_float64(value), size, ord("f"), 6, flags, width, prec
            )
        else:
            bad_verb[verb](out, value)

    elif kind == BOOLEAN:
        comptime if verb == ord("v") or verb == ord("t"):
            boolean(out, as_bool(value), flags, width)
        else:
            bad_verb[verb](out, value)

    else:
        # Text, and everything else that can write itself. A type this library
        # has never heard of arrives here through `Writable` and is printed as
        # what it writes, which is what a Go type with a `String` method does.
        comptime if verb == ord("v"):
            if (flags & SHARPV) != 0 and kind == TEXT:
                quoted(out, as_text(value), flags, width, prec)
            else:
                text(out, as_text(value), flags, width, prec)
        elif verb == ord("s"):
            text(out, as_text(value), flags, width, prec)
        elif verb == ord("q"):
            quoted(out, as_text(value), flags, width, prec)
        elif verb == ord("x"):
            hexadecimal(out, as_text(value), False, flags, width, prec)
        elif verb == ord("X"):
            hexadecimal(out, as_text(value), True, flags, width, prec)
        else:
            bad_verb[verb](out, value)


def bad_verb[verb: Int, T: Writable](mut out: String, value: T) raises:
    """Go's `%!d(string=hi)`. Go's `badVerb`.

    The value is printed with `%v`, which every kind accepts, so this recursion
    is one deep and always ends.

    The type is named the way Go names it, because this text is compared
    against Go's byte for byte. A type this library does not know has no name
    to give and is called `value`, which is the one place the marker is ours
    rather than Go's.
    """
    out += "%!"
    out += chr(verb)
    out += "("
    out += name_of[T]()
    out += "="
    one[ord("v")](out, 0, -1, -1, value)
    out += ")"
