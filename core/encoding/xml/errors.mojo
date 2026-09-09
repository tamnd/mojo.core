"""The element that arrived was not the one expected. Go's `UnmarshalError`.

Go's package has three error types besides `SyntaxError`, which lives in
`syntax.mojo` beside the parser that raises it. This is the one of the three
that survives the move away from reflection, and it survives because it holds a
sentence rather than a `reflect.Type`. `TagPathError` and `UnsupportedTypeError`
are waived with a reason about Go in `tools/parity/waivers.toml`.

Go builds one by converting a string, `return UnmarshalError("expected element
type <a> but have <b>")`, and its reflection walk does so in two places: an
element whose local name is not the name the destination was tagged with, and
one whose name space is not. The walk is not here, so those two checks belong to
the `unmarshal_xml` an implementation writes, and `unmarshal_error` is the call
that writes the raise. That is the one error builder in this library that is
public, because it is the one whose callers are outside the package.
"""

from core.errors import Report, capture
from core.errors.codes import ErrXMLUnmarshal


struct UnmarshalError(Copyable, Movable, Writable):
    """An element a value refused to read itself out of.

    Built from a raised error by `of` rather than by hand, and the message is a
    copy, so it outlives the `Error` it came from.

    ```mojo
    from core.encoding.xml import UnmarshalError, unmarshal_error

    def main():
        try:
            raise unmarshal_error("expected element type <a> but have <b>")
        except e:
            var failure = UnmarshalError.of(e)
            if failure:
                print(failure.value().msg)
                # expected element type <a> but have <b>
    ```
    """

    var msg: String
    """What was expected and what arrived, in Go's words.

    Go has no field at all, because its type is the string. A struct cannot be
    a string here, so the sentence is a field and `error` hands it back
    unchanged, which is what Go's `Error` does.
    """

    def __init__(out self, msg: StringSlice):
        self.msg = String(msg)

    @staticmethod
    def of(e: Error) -> Optional[Self]:
        """`e` as an `UnmarshalError`, or nothing if it did not come from here.

        Go's `err.(xml.UnmarshalError)`. Nothing comes back when the document
        was malformed rather than merely unexpected, which is `SyntaxError`, or
        when the failure came from the reader underneath.
        """
        var value = capture(e)
        if value.code() != ErrXMLUnmarshal:
            return None
        var msg = value.field("msg")
        if not msg:
            return None
        return Self(msg.value())

    def error(self) -> String:
        """The message Go's `Error` builds, character for character."""
        return self.msg.copy()

    def write_to[W: Writer](self, mut writer: W):
        writer.write(self.error())


def unmarshal_error(msg: StringSlice) -> Error:
    """The raise Go spells `return UnmarshalError(msg)`. Go has no counterpart.

    ```mojo
    from core.encoding.xml import Name, unmarshal_error

    def refuse(want: String, got: Name) -> Error:
        return unmarshal_error(
            "expected element type <" + want + "> but have <" + got.local + ">"
        )
    ```

    A free function rather than a method on the type because a raise is built
    here and read back by `of` there, and one place to build it means the code
    and the field cannot drift apart from what `of` looks for.
    """
    return (
        Report(String(msg))
        .with_code(ErrXMLUnmarshal)
        .with_field("msg", String(msg))
        .error()
    )
