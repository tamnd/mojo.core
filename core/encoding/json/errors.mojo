"""The two refusals that are about a value rather than about the bytes.

Go's package has eight error types. One of them, `SyntaxError`, says a document
is not JSON and lives beside the scanner that finds that out. The other seven
are all about a value: what the document held would not go into what the
program has, or what the program has cannot be written down. Two of the seven
are here and five are waived, and `tools/parity/waivers.toml` carries the
reason for each of the five.

`UnmarshalTypeError` is the one a decoder actually produces. The document is
well formed and says one thing, the field wants another, and nothing about that
is a syntax error, which is why it carries its own code. Go draws the same line:
its scanner never sees this and its decoder never calls it a syntax error.

`UnsupportedValueError` is the same disagreement going the other way. A float
that is infinite or is not a number cannot be written down, because JSON has no
way to spell either, and Go and this both refuse rather than invent a spelling.

Both are read back out of a raise by their own `of`, the way `SyntaxError.of`
reads one, since there is no error value to type assert against.
"""

from core.errors import Report, capture
from core.errors.codes import ErrJSONType, ErrJSONUnsupported


struct UnmarshalTypeError(Copyable, Movable, Writable):
    """A value in the document that would not go into the field. Go's
    `UnmarshalTypeError`.

    Built from a raised error by `of`, not by hand, so it outlives the `Error`
    it came from.

    ```mojo
    from core.encoding.json import UnmarshalTypeError, ValueScanner

    def main():
        var sc = ValueScanner('"x"'.as_bytes())
        try:
            _ = sc.read_signed(64)
        except e:
            var failure = UnmarshalTypeError.of(e)
            if failure:
                print(failure.value().value)  # string
                print(failure.value().type)  # Int64
    ```
    """

    var value: String
    """What the document held, named the way Go names it. Go's `Value`.

    One of `bool`, `string`, `number`, `array`, `object` and `null`, or
    `number` and the digits when the number was read and would not fit. Go's
    own list is the first five and the last of those; `null` is here because a
    null where a value belongs is an error and in Go it is not, for the reason
    `missing_key` gives, that Mojo has no zero value to leave a field at.
    """

    var type: String
    """The type it could not go into. Go's `Type`.

    Go holds a `reflect.Type` and prints it with `String`. There is no run time
    type here and none is wanted: the call that failed named the type it was
    reading into, so this is that name, spelled the way Mojo spells it, which
    is the spelling in the struct the reader is looking at.
    """

    var offset: Int
    """How many bytes had been read when it went wrong. Go's `Offset`.

    Counts the byte the value started at, so it is a position from one rather
    than an index from zero.
    """

    var struct_name: String
    """The struct the field is in, or empty. Go's `Struct`.

    `struct` is a Mojo keyword, which is the whole of why the name is longer
    here. `tools/parity/renames.toml` has the line.
    """

    var field: String
    """The key the value arrived under, or empty. Go's `Field`.

    Go documents its field as the whole path from the root, because its walk
    keeps a stack of the names it has descended through. This is the one name,
    since the struct beside it is the struct that name is a field of, and a
    nested struct that fails reports its own name and its own field rather than
    the route taken to reach it.
    """

    def __init__(
        out self,
        value: String,
        type: String,
        offset: Int,
        struct_name: String = String(),
        field: String = String(),
    ):
        self.value = value.copy()
        self.type = type.copy()
        self.offset = offset
        self.struct_name = struct_name.copy()
        self.field = field.copy()

    @staticmethod
    def of(e: Error) -> Optional[Self]:
        """`e` as an `UnmarshalTypeError`, or nothing if it came from
        somewhere else.

        Go's `err.(*json.UnmarshalTypeError)`.
        """
        var held = capture(e)
        if held.code() != ErrJSONType:
            return None
        var at = held.field("offset")
        var what = held.field("value")
        var into = held.field("type")
        if not at or not what or not into:
            return None
        var owner = held.field("struct")
        var key = held.field("field")
        try:
            return Self(
                what.value(),
                into.value(),
                Int(at.value()),
                owner.value() if owner else String(),
                key.value() if key else String(),
            )
        except:
            return None

    def error(self) -> String:
        """The message. Go's `Error`, which has two forms and picks by whether
        it knows the field.

        Go says `into Go value of type int64` and this says `into a value of
        type Int64`, which is the one message in this package that is not Go's
        word for word. The type named is a Mojo type, so calling it a Go value
        would be telling somebody their `Int64` is something it is not.
        `docs/deviations.md` has the row.
        """
        if self.struct_name != "" or self.field != "":
            return (
                "json: cannot unmarshal "
                + self.value
                + " into struct field "
                + self.struct_name
                + "."
                + self.field
                + " of type "
                + self.type
            )
        return (
            "json: cannot unmarshal "
            + self.value
            + " into a value of type "
            + self.type
        )

    def write_to[W: Writer](self, mut writer: W):
        writer.write(self.error())


def _type_error(
    value: String,
    type: String,
    offset: Int,
    struct_name: String,
    field: String,
) -> Error:
    """The raise every type disagreement in this package makes.

    One place, so the five parts and the message cannot drift apart and so
    `UnmarshalTypeError.of` has one shape to read.
    """
    var built = UnmarshalTypeError(value, type, offset, struct_name, field)
    var report = (
        Report(built.error())
        .with_code(ErrJSONType)
        .with_field("value", value)
        .with_field("type", type)
        .with_field("offset", String(offset))
    )
    if struct_name != "":
        report = report^.with_field("struct", struct_name)
    if field != "":
        report = report^.with_field("field", field)
    return report^.error()


struct UnsupportedValueError(Copyable, Movable, Writable):
    """A value that cannot be written down as JSON. Go's
    `UnsupportedValueError`.

    ```mojo
    from core.encoding.json import UnsupportedValueError, append_float
    from core.io import Byte

    def main():
        var out = List[Byte]()
        try:
            append_float(out, Float64("nan"), 64)
        except e:
            var failure = UnsupportedValueError.of(e)
            if failure:
                print(failure.value().str)  # NaN
    ```

    Go's type has a `Value` beside the text, holding the `reflect.Value` the
    encoder was looking at. That field is waived rather than owed, because the
    text beside it is that same value already formatted and there is nothing a
    second copy of it would answer.
    """

    var str: String
    """The value, written out. Go's `Str`.

    `NaN`, `+Inf` or `-Inf`, which are the three Go's own encoder puts here
    and the three JSON has no way to spell.
    """

    def __init__(out self, str: String):
        self.str = str.copy()

    @staticmethod
    def of(e: Error) -> Optional[Self]:
        """`e` as an `UnsupportedValueError`, or nothing if it came from
        somewhere else.

        Go's `err.(*json.UnsupportedValueError)`.
        """
        var held = capture(e)
        if held.code() != ErrJSONUnsupported:
            return None
        var text = held.field("value")
        if not text:
            return None
        return Self(text.value())

    def error(self) -> String:
        """The message. Go's `Error`, word for word."""
        return "json: unsupported value: " + self.str

    def write_to[W: Writer](self, mut writer: W):
        writer.write(self.error())


def _unsupported_value(str: String) -> Error:
    """The raise a value with no spelling makes.

    One place, so the text and the message cannot drift apart and so
    `UnsupportedValueError.of` has one shape to read.
    """
    return (
        Report("json: unsupported value: " + str)
        .with_code(ErrJSONUnsupported)
        .with_field("value", str)
        .error()
    )
