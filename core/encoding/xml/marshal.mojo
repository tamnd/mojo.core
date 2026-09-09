"""A whole value out and a whole value back. Go's `Marshal` pair.

Go's `Marshal` takes an `any` and walks it with reflection, reading struct tags
as it goes to decide what becomes an element, what becomes an attribute and what
is left out, and along the way it asks every value it meets whether it
implements `Marshaler`, because a type that knows its own XML should win over a
walk that is guessing. There is no walk here. What is left is the interface Go
asks for: a type that can write itself out implements `Marshaler`, a type that
can read itself back implements `Unmarshaler`, and these three calls take one.

That is a smaller door than Go's and it opens onto the same room, with one
difference worth knowing about. Go's walk names the element after the Go type it
is walking, so a `Person` becomes `<Person>` unless a tag says otherwise. There
is no type name to read here, so `marshal` hands `marshal_xml` a start element
with an empty name and the value names itself. `docs/deviations.md` has the row.

The traits themselves live next to the types they take, `Marshaler` and
`MarshalerAttr` in `encode.mojo` and `Unmarshaler` and `UnmarshalerAttr` in
`decode.mojo`, because a trait method taking an `Encoder` and the `Encoder`
method taking the trait refer to each other and a module cannot import itself.
"""

from core.bytes import new_buffer, new_reader
from core.io import Byte

from .decode import Unmarshaler, new_decoder
from .encode import Marshaler, new_encoder


def marshal[T: Marshaler](value: T) raises -> List[Byte]:
    """`value` as one XML element, with no whitespace of its own. Go's
    `Marshal`.

    ```mojo
    from core.encoding.xml import CharData, Encoder, Marshaler, Name
    from core.encoding.xml import StartElement, Token, marshal
    from core.io import Writer


    struct Greeting(Marshaler):
        var who: String

        def marshal_xml[
            W: Writer & Deinitable & Movable
        ](self, mut e: Encoder[W], start: StartElement) raises:
            var open = start.copy()
            if not open.name.local:
                open.name = Name("", "greeting")
            e.encode_token(Token(open.copy()))
            e.encode_token(Token(CharData(self.who)))
            e.encode_token(Token(open.end()))


    def main() raises:
        print(String(from_utf8_lossy=Span(marshal(Greeting("world")))))
        # <greeting>world</greeting>
    ```

    No declaration goes out in front of it, which is Go's behaviour as well.
    `HEADER` is the constant to write first when the document needs one.

    Raises when the value writes a stream of tokens that is not a document: an
    element it opened and did not close, an end tag that does not match, or a
    comment or directive holding bytes that would not read back. Those are
    `encode_token`'s checks and they apply to a value writing itself exactly as
    they apply to a caller writing tokens by hand.
    """
    var e = new_encoder(new_buffer(List[Byte]()))
    e.encode(value)
    e.close()
    return e.w.w.bytes()


def marshal_indent[
    T: Marshaler, o1: ImmOrigin, o2: ImmOrigin
](value: T, prefix: StringSlice[o1], indent: StringSlice[o2]) raises -> List[
    Byte
]:
    """`value` as XML with every element on its own line. Go's `MarshalIndent`.

    Each line begins with `prefix` and then one copy of `indent` per level of
    nesting, and an element with nothing between its tags stays on one line.
    Both empty is `marshal`.
    """
    var e = new_encoder(new_buffer(List[Byte]()))
    e.indent(prefix, indent)
    e.encode(value)
    e.close()
    return e.w.w.bytes()


def unmarshal[
    T: Unmarshaler, o: ImmOrigin
](data: Span[Byte, o], mut value: T) raises:
    """Read the first element of `data` into `value`. Go's `Unmarshal`.

    Anything in front of that element is read and thrown away, so a document
    with a declaration and a comment at the top is read into the element under
    them. Raises `EOF` if there is no element in `data` at all, which is what
    Go's `Decode` does with the same input.

    Go takes a pointer and refuses one that is nil or is not a pointer, which is
    a run time check on something the caller wrote. The destination is a `mut`
    argument here, so both of those are compile errors and neither has an error
    value to return.
    """
    var d = new_decoder(new_reader(data))
    d.decode(value)
