"""A struct that can print its own fields, which is this library's reflection.

Go prints a struct nobody wrote a `String` method for by walking it with
reflection, which is how `%v` gives `{1 hello}` and `%+v` gives `{A:1 B:hello}`
for a type that knows nothing about `fmt`. There is no reflection here, so the
walk has to be written down, and `Fields` is where it is written down.

There are three levels and they are tried in this order:

1. A type that is `Writable` prints through what it writes. That is Go's
   `Stringer` and it wins, the same way Go's does.
2. A type that is not `Writable` but conforms to `Fields` prints field by
   field, and `%v`, `%+v` and `%#v` differ the way they do in Go.
3. A type that is neither is named while the program is built and prints Go's
   marker at run time. That is the reflection hole and it is not covered over.

The body of `write_fields` is the same rote walk for every struct, which is
what a generator is for: `tools/docjson` already reports every field name and
type, and the generated codecs read the same JSON. Until that generator exists
the body is written by hand, and `write_field` below is what it calls so that a
field which is itself a struct recurses on the same rules.

```mojo
from core.fmt import Fields, Spec, write_field


@fieldwise_init
struct Point(Fields):
    var x: Int
    var y: Int

    def write_fields(self, mut out: String, spec: Spec) raises:
        out += "Point" if spec.go_syntax() else ""
        out += "{"
        if spec.named():
            out += "x:"
        write_field(out, spec, self.x)
        out += ", " if spec.go_syntax() else " "
        if spec.named():
            out += "y:"
        write_field(out, spec, self.y)
        out += "}"
```

The verb travels with the spec rather than being fixed to `v`, because Go
applies the verb to each field rather than to the struct: `%d` of a struct
holding an `Int` and a `String` is `{1 %!d(string=x)}`, one good field and one
marker, and a struct that ignored the verb could not produce that.
"""

from .plan import PLUSV, SHARPV


@fieldwise_init
struct Spec(Copyable, ImplicitlyCopyable, Movable):
    """What a verb was asked for, carried into a struct so its fields get it.

    Four numbers rather than four arguments, because they are always passed
    together and a struct with a name on each is easier to get right than a
    call with four bare integers in it.
    """

    var verb: Int
    """The verb as a code point."""

    var flags: Int
    """The flag bits, with `%#v` and `%+v` already moved to `SHARPV` and
    `PLUSV`."""

    var width: Int
    """The width, or -1 for none."""

    var prec: Int
    """The precision, or -1 for none."""

    def named(self) -> Bool:
        """Whether a field name goes before each value.

        True for both `%+v` and `%#v`, because Go names the fields in both.
        `%v` is the one that does not.
        """
        return self.verb == ord("v") and (self.flags & (PLUSV | SHARPV)) != 0

    def go_syntax(self) -> Bool:
        """Whether this is `%#v`, which prints something that reads like
        source: the type name in front, commas between the fields, and strings
        quoted."""
        return self.verb == ord("v") and (self.flags & SHARPV) != 0


trait Fields:
    """A type that prints its own fields when `fmt` has no other way in.

    Declaring this is the whole opt in. A type that also implements `Writable`
    never reaches here, because writing itself is the more specific answer and
    Go prefers it too.
    """

    def write_fields(self, mut out: String, spec: Spec) raises:
        """The fields of `self` onto `out`, under `spec`."""
        ...
