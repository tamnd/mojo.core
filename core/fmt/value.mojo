"""One argument, printed with one verb.

The type is a parameter and the verb is not. That split is the whole of this
file. Which kind of thing an argument is has to be decided while the program is
built, because there is no reflection to ask at run time and because `%d` on a
float has to be an error rather than a rounding. What to do with the verb, once
the kind is known, is the same work whichever path got here, and it lives in
verb.mojo so that the compile time path and `vsprintf` cannot drift apart.

So the chain below is not a switch that runs: it is a chain the compiler walks
once per call site, keeping the one branch that applies. A `%d` on an `Int`
compiles to the call to `integer_verb` and nothing else.

The last two branches are the ones Go answers with reflection. A type that
writes itself has already been handled as `OTHER` above them, so what is left
is a type that lists its fields and a type that can do neither. See fields.mojo
for why that order and not the other one.
"""

from .fields import Fields, Spec
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
from .verb import (
    bool_verb,
    float_verb,
    integer_verb,
    opaque_verb,
    text_verb,
)


def any_one[
    T: AnyType
](
    mut out: String, verb: Int, flags: Int, width: Int, prec: Int, value: T
) raises:
    """`value` written with `verb`, or Go's marker when the two do not go
    together."""
    comptime kind = kind_of[T]()

    comptime if kind == SIGNED or kind == UNSIGNED:
        integer_verb(
            out,
            verb,
            as_uint64(value),
            kind == SIGNED,
            name_of[T](),
            flags,
            width,
            prec,
        )
    elif kind == FLOAT:
        float_verb(
            out,
            verb,
            as_float64(value),
            float_bits[T](),
            name_of[T](),
            flags,
            width,
            prec,
        )
    elif kind == BOOLEAN:
        bool_verb(out, verb, as_bool(value), name_of[T](), flags, width, prec)
    elif kind == TEXT or kind == OTHER:
        text_verb(
            out, verb, as_text(value), kind, name_of[T](), flags, width, prec
        )
    elif conforms_to(T, Fields):
        value.write_fields(out, Spec(verb, flags, width, prec))
    else:
        opaque_verb(out, verb)


def one[
    verb: Int, T: AnyType
](mut out: String, flags: Int, width: Int, prec: Int, value: T) raises:
    """`value` written with the verb given as a parameter.

    This is what the compile time path calls, and the verb being a parameter is
    what lets `check.mojo` have already decided that the pair goes together.
    The verb arrives at `any_one` as a constant at the call site, so the chain
    in verb.mojo folds the same way it would have if it were written with
    `comptime if`.
    """
    any_one(out, verb, flags, width, prec, value)


def write_field[T: AnyType](mut out: String, spec: Spec, value: T) raises:
    """One field of a struct, under the spec the struct was asked for.

    This is what the body of a `write_fields` calls, and the reason a struct
    holding a struct comes out right: the spec travels down unchanged, so `%+v`
    names the fields at every level and `%d` reaches every leaf.
    """
    any_one(out, spec.verb, spec.flags, spec.width, spec.prec, value)
