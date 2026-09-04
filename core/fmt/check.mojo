"""Which verbs a kind can be printed with, and the complaints when it cannot.

Mojo will not turn a compile time fact into a compile error, and it will not
turn one into a warning either. Both mechanisms that look like they would work
do not:

`where` clauses are proof carrying, and their solver evaluates builtin
arithmetic on parameters and nothing else. It refuses to call our own parser,
so a `where` that asks whether a format string is right cannot be evaluated at
all. `@deprecated` emits a warning wherever the deprecated name is written,
whether or not the branch holding it is ever taken and whether or not the
function holding it is ever instantiated, so a stub called from inside a
`comptime if` warns on correct code. Neither can say a thing about one call and
stay quiet about the next.

What is left is the compile time interpreter itself. A `comptime` binding whose
value is used is folded while the program is built, by an interpreter that runs
our code, and a `print` in that code prints while the program is built. So the
complaint below is an ordinary `print` reached only when the check has actually
failed, in a branch the interpreter actually took, for one instantiation. It
names the format string, the verb and the argument, which is more than a
warning attached to a stub could ever have said.

The compromise, stated plainly because it is the one thing about this package a
caller has to know: **every format error is found while the program is compiled
and reported on the compiler's standard output, and then the program behaves
exactly like Go at run time.** Inside this repository the build of the test
suite turns any line carrying the `core:` marker into a failure, which is why
nothing in `core` ever ships a wrong format string. Outside it, a line of text
while you build is what you get, and Go's marker in the output is the rest.

Two limits are worth knowing. The line has no source location on it, because it
is a print and not a diagnostic, so it names the format string instead. And a
compiler that serves a build from cache does not re-run the interpreter, so the
complaint appears on the build that first compiles the call and not on the one
after it.

`tests/warnings/` asserts that these still fire. If a compiler release stops
running the interpreter this way, every compile time check in this library goes
quiet at once, and a test failing is how that gets noticed rather than a bug
report two releases later.
"""

from .kind import BOOLEAN, FLOAT, OTHER, SIGNED, TEXT, UNSIGNED


def accepts(verb: Int, kind: Int) -> Bool:
    """Whether `verb` can print a value of `kind`. Go's per kind switches.

    This is the same table `value.mojo` dispatches on, written once. The two
    agreeing is not left to inspection: `tests/fmt/test_verbs.mojo` walks every
    verb against every kind and asserts that what this says matches whether the
    output came out as a marker.
    """
    if verb == ord("v"):
        return True
    if kind == SIGNED or kind == UNSIGNED:
        return (
            verb == ord("d")
            or verb == ord("b")
            or verb == ord("o")
            or verb == ord("O")
            or verb == ord("x")
            or verb == ord("X")
            or verb == ord("c")
            or verb == ord("q")
            or verb == ord("U")
        )
    if kind == FLOAT:
        return (
            verb == ord("b")
            or verb == ord("e")
            or verb == ord("E")
            or verb == ord("f")
            or verb == ord("F")
            or verb == ord("g")
            or verb == ord("G")
            or verb == ord("x")
            or verb == ord("X")
        )
    if kind == TEXT or kind == OTHER:
        return (
            verb == ord("s")
            or verb == ord("q")
            or verb == ord("x")
            or verb == ord("X")
        )
    if kind == BOOLEAN:
        return verb == ord("t")
    return False


def integral(kind: Int) -> Bool:
    """Whether a `*` width or precision can be read from this kind.

    Go takes one from any integer type and refuses everything else. A float
    width is not rounded, it is `%!(BADWIDTH)`.
    """
    return kind == SIGNED or kind == UNSIGNED


def complain(message: String) -> StaticString:
    """`message` on the compiler's output, and an empty string.

    Every check below ends here. The empty string is not decoration: a
    `comptime` binding nothing reads is never folded, and a binding that is
    never folded never runs this. So each caller writes the result into the
    text it is building, which costs an append of nothing at run time and is
    what makes the complaint happen at all.
    """
    print(message)
    return ""


def _arguments(n: Int) -> String:
    """`n` with the word after it, singular when there is one of them."""
    return String(n, " argument") if n == 1 else String(n, " arguments")


def _were(n: Int) -> StaticString:
    """The verb that agrees with `n`."""
    return "was" if n == 1 else "were"


def wrong_verb[
    format: StaticString, verb: Int, name: StaticString, at: Int
]() -> StaticString:
    """A verb and the argument beside it that do not go together."""
    return complain(
        String(
            'core: fmt: in "',
            format,
            '" the verb %',
            chr(verb),
            " cannot print argument ",
            at + 1,
            ", whose type is ",
            name,
            ", so this call writes Go's %!",
            chr(verb),
            "(",
            name,
            "=...) marker at run time",
        )
    )


def missing_argument[
    format: StaticString, verb: Int, at: Int, count: Int
]() -> StaticString:
    """A verb with no argument left for it."""
    return complain(
        String(
            'core: fmt: in "',
            format,
            '" the verb %',
            chr(verb),
            " asks for argument ",
            at + 1,
            " and only ",
            _arguments(count),
            " ",
            _were(count),
            " passed, so this call writes Go's %!",
            chr(verb),
            "(MISSING) marker at run time",
        )
    )


def extra_argument[
    format: StaticString, used: Int, count: Int
]() -> StaticString:
    """Arguments no verb consumed."""
    return complain(
        String(
            'core: fmt: the format "',
            format,
            '" uses ',
            _arguments(used),
            " and ",
            _arguments(count),
            " ",
            _were(count),
            (
                " passed, so this call writes Go's %!(EXTRA type=value)"
                " marker at run time"
            ),
        )
    )


def bad_format[
    format: StaticString, what: StaticString, marker: StaticString
]() -> StaticString:
    """A format string that does not parse."""
    return complain(
        String(
            'core: fmt: the format "',
            format,
            '" ',
            what,
            ", so this call writes Go's %!(",
            marker,
            ") marker at run time",
        )
    )


def no_width_argument[
    format: StaticString,
    which: StaticString,
    marker: StaticString,
    at: Int,
    count: Int,
]() -> StaticString:
    """A `*` width or precision reading an argument that was never passed."""
    return complain(
        String(
            'core: fmt: in "',
            format,
            '" the * ',
            which,
            " reads argument ",
            at + 1,
            " and only ",
            _arguments(count),
            " ",
            _were(count),
            " passed, so this call writes Go's %!(",
            marker,
            ") marker at run time",
        )
    )


def bad_width[
    format: StaticString,
    which: StaticString,
    marker: StaticString,
    at: Int,
    name: StaticString,
]() -> StaticString:
    """A `*` width or precision pointing at something that is not an integer.

    `which` is the word for the message and `marker` is the name Go writes,
    because `width` becomes `BADWIDTH` and `precision` becomes `BADPREC` and
    the second does not follow from the first.
    """
    return complain(
        String(
            'core: fmt: in "',
            format,
            '" the * ',
            which,
            " reads argument ",
            at + 1,
            ", whose type is ",
            name,
            " rather than a whole number, so this call writes Go's %!(",
            marker,
            ") marker at run time",
        )
    )
