"""Formatted text, with the format string checked when the program is built.
Go's `fmt`.

```mojo
from core.fmt import printf, sprintf

def main() raises:
    printf["%s is %d years old\\n"]("Ada", 36)
    var line = sprintf["%-8s|%6.2f|%#x"]("total", 12.5, 255)
```

The format string is a compile time parameter, written in square brackets
rather than passed as an argument. That is the whole design. It is parsed once,
when the program is compiled, and what the program carries is the pieces of
text and the calls that fill the gaps between them. The format string itself is
not in the binary and is not read at run time.

What that buys is the thing Go pays for with a vet pass: the verbs are checked
against the arguments beside them while the program is being built. `%d` on a
string, three verbs and two arguments, a `%z` nobody implements, a format that
ends in a bare `%`: all of them are known before the program runs.

## What a mistake looks like

Mojo has no way to fail a build on a fact computed at compile time, and no way
to raise a warning on one either. What it does have is an interpreter that runs
our code while the program is compiled, and a `print` from that interpreter
comes out on the compiler's output. So this is the compromise, stated plainly:
**every format error is found while the program is compiled and reported as a
line on the compiler's output, and then the program behaves exactly like Go at
run time.** Inside this repository the build of the test suite turns that line
into a failure, which is where it has to happen: compiling a package on its own
elaborates nothing, so there is nothing to see until something calls the code.
Outside it, a line while you build is what you get, and the run time output is
Go's marker for the same mistake, byte for byte:

```
%!d(string=hi)      a verb the argument cannot be printed with
%!d(MISSING)        a verb with no argument left for it
%!(EXTRA int=3)     an argument no verb used
%!(NOVERB)          a format string ending in a bare %
%!(BADWIDTH)        a * width reading something that is not a whole number
```

The line names the format string, the verb and the argument, one line per call
that is wrong. It has no file and line number on it, because a print is not a
diagnostic and carries no source location, and it appears on the build that
first compiles the call rather than on a build served from cache. See
`check.mojo` and section 10 of docs/design.md.

## What can be printed

Every integer type, both float types, `String` and `StaticString`, `Bool`, and
anything else that is `Writable`, which prints as what it writes and is this
library's answer to Go's `Stringer`. The verbs are Go's:

```
%v  the default for the kind      %x %X  hexadecimal, and of a string its bytes
%d  base ten                      %o %O  base eight, %O with a leading 0o
%b  base two                      %c     the code point as a character
%q  a quoted literal              %U     the code point as U+0041
%s  a string                      %t     a boolean
%e %E %f %F %g %G                 floats, with Go's default precisions
```

with the flags `+`, `-`, `#`, ` ` and `0`, a width, a precision, `*` for either
of those from an argument, and `%[2]d` to choose which argument.

`%p` and `%T` are not here and are not coming. Both are questions about a value
that only reflection can answer, and there is no reflection in Mojo. The
markers this package writes name the Go type an argument corresponds to for the
same reason: `String` is Go's `string`, and a type this library does not know
has no name at all and is called `value`.

## A type this package has never heard of

Go prints one under `%v` by reflecting on it. There is nothing here that can,
so the question is asked of the type while the program is built, and it has
three answers in order of preference:

1. It implements `Writable`, which is Go's `Stringer`, and prints as what it
   writes.
2. It implements `Fields`, and prints its fields. That is one method, and it
   gets the verb, the flags, the width and the precision and hands them to each
   field the way Go does, so `%d` of a struct holding an `Int` and a `String`
   is Go's `{1 %!d(string=hello)}`. See `fields.mojo` for the shape.
3. It implements neither, and there is nothing to print. The call is named on
   the compiler's output, with both ways out spelled in the message, and writes
   Go's `%!v(value)` marker when it runs.

## A format string nobody knew until the program ran

The compile time path cannot take one, because the format string is a
parameter. `vsprintf` can. It takes a `String` and a `List[Arg]`, does no
checking, costs a box for every argument, and prints the same bytes:

```mojo
from core.fmt import Arg, vsprintf

def main() raises:
    var format = String("%s has %d items")
    print(vsprintf(format, [Arg(String("cart")), Arg(3)]))
```

`vprintf`, `vfprintf` and `vappendf` are the same thing written somewhere else.
It is the honest answer for a caller building a format string out of a
translation table and the wrong answer for everything else. See `dynamic.mojo`
for what the two paths share, which is most of them.

## What is not here yet

`errorf`, and the `Scan` family, which is a parser rather than a printer.
"""

from core.io import Writer

from .check import (
    accepts,
    bad_format,
    bad_width,
    extra_argument,
    integral,
    missing_argument,
    no_width_argument,
    unprintable,
    wrong_verb,
)
from .arg import Arg
from .dynamic import (
    vappendf,
    vformat_to,
    vfprintf,
    vprintf,
    vsprintf,
)
from .fields import Fields, Spec
from .kind import OPAQUE, as_index, kind_of, name_of
from .out import to_stdout
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
from .print import (
    append,
    appendln,
    fprint,
    fprintln,
    print,
    println,
    sprint,
    sprintln,
)
from .value import one, write_field


def format_to[
    format: StaticString, *Ts: AnyType
](mut out: String, *args: *Ts) raises:
    """The formatted text onto the end of `out`.

    Everything the other entry points do goes through here. The loop below is
    a `comptime for` over the pieces of the format string, so it is unrolled
    when the program is compiled and what is left is one call per verb with a
    string constant between each.
    """
    comptime plan = pieces(format)
    comptime last = plan[len(plan) - 1]
    comptime count = len(Ts)
    comptime used = last.arg
    comptime reordered = (last.flags & REORDERED) != 0

    comptime for i in range(len(plan)):
        comptime piece = plan[i]
        out += piece.literal
        comptime verb = piece.verb

        comptime if verb == PERCENT:
            out += "%"
        elif verb == NOVERB:
            comptime said = bad_format[format, "ends in a bare %", "NOVERB"]()
            out += said
            out += "%!(NOVERB)"
        elif verb == BADINDEX:
            comptime said = bad_format[
                format,
                "holds an argument index that is not a number",
                "BADINDEX",
            ]()
            out += said
            out += "%!(BADINDEX)"
        elif verb != TAIL:
            var width = piece.width
            var prec = piece.prec
            var flags = piece.flags

            # `%*d` and `%.*f`, where the width or the precision is an
            # argument. A negative width is how Go spells the minus flag from
            # an argument, and a negative precision is no precision at all.
            comptime wa = piece.width_arg
            comptime if wa >= 0:
                comptime if wa >= count:
                    comptime said = no_width_argument[
                        format, "width", "BADWIDTH", wa, count
                    ]()
                    out += said
                    out += "%!(BADWIDTH)"
                elif not integral(kind_of[Ts[wa]]()):
                    comptime said = bad_width[
                        format, "width", "BADWIDTH", wa, name_of[Ts[wa]]()
                    ]()
                    out += said
                    out += "%!(BADWIDTH)"
                else:
                    width = as_index(args[wa])
                    if width < 0:
                        width = -width
                        flags = (flags | MINUS) & ~ZERO

            comptime pa = piece.prec_arg
            comptime if pa >= 0:
                comptime if pa >= count:
                    comptime said = no_width_argument[
                        format, "precision", "BADPREC", pa, count
                    ]()
                    out += said
                    out += "%!(BADPREC)"
                elif not integral(kind_of[Ts[pa]]()):
                    comptime said = bad_width[
                        format, "precision", "BADPREC", pa, name_of[Ts[pa]]()
                    ]()
                    out += said
                    out += "%!(BADPREC)"
                else:
                    prec = as_index(args[pa])
                    if prec < 0:
                        prec = -1

            comptime a = piece.arg
            comptime if a >= count:
                comptime said = missing_argument[format, verb, a, count]()
                out += said
                out += "%!"
                out += chr(verb)
                out += "(MISSING)"
            else:
                comptime if kind_of[Ts[a]]() == OPAQUE:
                    comptime said = unprintable[format, verb, a]()
                    out += said
                elif not accepts(verb, kind_of[Ts[a]]()):
                    comptime said = wrong_verb[
                        format, verb, name_of[Ts[a]](), a
                    ]()
                    out += said
                one[verb](out, flags, width, prec, args[a])

    # Arguments nothing used. Go stops reporting these once a format has chosen
    # an argument by index, because after that they are not being consumed in
    # order and "one too many" stops meaning anything.
    comptime if count > used and not reordered:
        comptime said = extra_argument[format, used, count]()
        out += said
        out += "%!(EXTRA "
        comptime for j in range(used, count):
            comptime if j > used:
                out += ", "
            out += name_of[Ts[j]]()
            out += "="
            one[ord("v")](out, 0, -1, -1, args[j])
        out += ")"


def sprintf[format: StaticString, *Ts: AnyType](*args: *Ts) raises -> String:
    """The formatted text as a string. Go's `Sprintf`."""
    var out = String()
    format_to[format](out, *args)
    return out^


def printf[format: StaticString, *Ts: AnyType](*args: *Ts) raises:
    """The formatted text on standard output. Go's `Printf`.

    Go gives back the byte count and an error. Nothing here can fail, since
    the text is built before any of it is written, and a count nobody reads is
    a count that goes stale.
    """
    to_stdout(sprintf[format](*args))


def fprintf[
    format: StaticString, W: Writer, *Ts: AnyType
](mut dst: W, *args: *Ts) raises -> Int:
    """The formatted text to a writer, and how many bytes that took. Go's
    `Fprintf`."""
    var out = sprintf[format](*args)
    return dst.write(out.as_bytes())


def appendf[
    format: StaticString, *Ts: AnyType
](mut dst: List[Byte], *args: *Ts) raises -> Int:
    """The formatted text onto the end of `dst`, and how many bytes that took.
    Go's `Appendf`.

    Go gives back the grown slice. Here the list is already the caller's and a
    second name for it is the thing that goes stale, which is the same choice
    `core.strconv` made for its append forms.
    """
    var out = sprintf[format](*args)
    dst.extend(out.as_bytes())
    return out.byte_length()
