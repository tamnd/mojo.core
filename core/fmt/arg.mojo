"""An argument with its type taken off, for the path that has no types.

`sprintf` knows the type of every argument, because the arguments are a
parameter pack and the whole package is built on that. `vsprintf` cannot: its
arguments arrive in a `List`, and a list has one element type. So each value is
taken apart while the program is built, which is the only time anything can be,
and what goes in the list is the pieces.

That is what `Arg` is. It is bigger than the value it holds and it costs an
allocation for anything with text in it, and both of those are the price of a
format string nobody knew until the program ran. The compile time path never
builds one.

```mojo
from core.fmt import Arg, vsprintf

def main() raises:
    var format = String("%s has %d items")
    print(vsprintf(format, [Arg(String("cart")), Arg(3)]))
```

One thing does not survive the boxing, and it is worth being plain about it. A
struct that prints through `Fields` is walked with the verb it was asked for,
and at the moment it goes into the list nobody knows what that verb will be. So
it is walked here, with `%v` unless the caller says otherwise, and the answer is
kept as text. If the format then asks for something else, that is a marker
rather than a wrong answer: `Arg` remembers what it was rendered with and says
so. Nothing else can be done without storing a value of unknown type, which is
the same hole that made this file necessary.
"""

from .check import complain
from .fields import Spec
from .kind import (
    BOOLEAN,
    FLOAT,
    OPAQUE,
    OTHER,
    SIGNED,
    STRUCT,
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
from .value import any_one
from .verb import bool_verb, float_verb, integer_verb, opaque_verb, text_verb


struct Arg(Copyable, ImplicitlyCopyable, Movable):
    """One argument, with everything `vsprintf` will need to print it.

    Only the fields the kind uses are filled in. Which ones those are is not a
    guess a reader has to make: `kind` says it, and it is the same `kind` the
    compile time path branches on.
    """

    var kind: Int
    """Which of the kinds in kind.mojo this was."""

    var name: StaticString
    """What Go calls the type, for the inside of a marker."""

    var bits: UInt64
    """An integer, widened to 64 bits and sign extended if it was signed."""

    var number: Float64
    """A float, widened to double precision."""

    var size: Int
    """How wide the float was, 32 or 64, which decides its shortest text."""

    var text: String
    """A string, or what a value that writes itself wrote, or what a struct
    came to when it was walked."""

    var truth: Bool
    """A boolean."""

    var under: Spec
    """For a struct, the spec it was walked with. Ignored by every other
    kind."""

    def __init__[T: AnyType](out self, value: T) raises:
        """A value boxed the way `%v` would print it.

        This is the constructor to use for anything that is not a struct,
        because for everything else the verb makes no difference to what is
        kept here.
        """
        self = Arg(value, Spec(ord("v"), 0, -1, -1))

    def __init__[T: AnyType](out self, value: T, spec: Spec) raises:
        """A value boxed, with the spec a struct should be walked with.

        The spec is ignored by every kind except `STRUCT`, and for `STRUCT` it
        is the difference between `{1 hi}` and `{x:1 y:hi}`.
        """
        comptime kind = kind_of[T]()
        self.kind = kind
        self.name = name_of[T]()
        self.bits = 0
        self.number = 0.0
        self.size = 64
        self.text = String()
        self.truth = False
        self.under = spec

        comptime if kind == SIGNED or kind == UNSIGNED:
            self.bits = as_uint64(value)
        elif kind == FLOAT:
            self.number = as_float64(value)
            self.size = float_bits[T]()
        elif kind == BOOLEAN:
            self.truth = as_bool(value)
        elif kind == TEXT or kind == OTHER:
            self.text = as_text(value)
        elif kind == STRUCT:
            any_one(
                self.text, spec.verb, spec.flags, spec.width, spec.prec, value
            )
        else:
            # There is nothing to keep. The type is named here rather than at
            # the call that formats it, because here is where it is known: by
            # the time `vsprintf` has a list of these, the type is gone.
            comptime said = _nothing_to_box[name_of[T]()]()
            self.text += said


def _nothing_to_box[name: StaticString]() -> StaticString:
    """The complaint for boxing a value that cannot be printed at all."""
    return complain(
        String(
            "core: fmt: Arg was given a value of a type that can neither write"
            " itself nor list its fields, so there is nothing to box and every"
            " verb using it writes Go's %!v(value) marker at run time."
            " Implement Writable on it, which is Go's Stringer, or implement"
            " core.fmt.Fields on it, which is the walk over the fields that Go"
            " would have done with reflection"
        )
    )


def write_arg(
    mut out: String, verb: Int, flags: Int, width: Int, prec: Int, arg: Arg
) raises:
    """A boxed argument written with a verb, both known only now.

    Every branch here hands off to the same function in verb.mojo that the
    compile time path hands off to. What is different between the two paths
    stops at this line: one of them got its pieces out of a type and the other
    got them out of a struct field.
    """
    if arg.kind == SIGNED or arg.kind == UNSIGNED:
        integer_verb(
            out,
            verb,
            arg.bits,
            arg.kind == SIGNED,
            arg.name,
            flags,
            width,
            prec,
        )
    elif arg.kind == FLOAT:
        float_verb(
            out, verb, arg.number, arg.size, arg.name, flags, width, prec
        )
    elif arg.kind == BOOLEAN:
        bool_verb(out, verb, arg.truth, arg.name, flags, width, prec)
    elif arg.kind == TEXT or arg.kind == OTHER:
        text_verb(out, verb, arg.text, arg.kind, arg.name, flags, width, prec)
    elif arg.kind == STRUCT:
        # The walk already happened. If it happened under a different verb the
        # text on hand is an answer to a different question, and saying so is
        # better than handing it over as if it were not.
        if (
            verb == arg.under.verb
            and flags == arg.under.flags
            and width == arg.under.width
            and prec == arg.under.prec
        ):
            out += arg.text
        else:
            out += "%!"
            out += chr(verb)
            out += "(value was not boxed for this verb)"
    else:
        opaque_verb(out, verb)
