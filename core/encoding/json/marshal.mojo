"""Writing a value out, and reading one back into itself. Go's `Marshal` pair.

Go's `Marshal` takes an `any` and walks it with reflection, and along the way it
asks every value it meets whether it implements `Marshaler`, because a type that
knows its own JSON should win over a walk that is guessing. Here the walk is
generated code, one encoder per struct written by `tools/codec`, and there is
nothing to ask at run time, so what is left is the interface Go asks for. A type
that can write itself out implements `Marshaler`, a type that can read itself
back implements `Unmarshaler`, and `marshal` and `unmarshal` are the two calls
that take one.

That is a smaller door than Go's and it opens onto the same room. Go's own
`Marshal` on a `Marshaler` does exactly what `marshal` does here: call the
method, compact what came back, and hand the bytes over. What Go has in addition
is the fallback for a type that implements nothing, and the fallback here is
`marshal_json(value)`, the free function the generator wrote, which is a direct
call rather than a walk and is what `docs/design.md` section 1 leaves in place of
an interface.

`Encoder` is the streaming form and it is Go's, down to the newline after every
value. `set_indent` reshapes what goes out and `set_escape_html` says whether
the three HTML characters are spelled out on the way. The second of those means
here what it means on Go's `Marshaler` path: it stops escaping being added, and
it does not take away escaping a writer already put in. `docs/deviations.md` has
the row.
"""

from core.io import Byte, Writer as IoWriter

from .indent import _append_compact, indent as _append_indent
from .scan import _NEWLINE, valid_or_raise


trait Marshaler:
    """A type that can write itself out as JSON. Go's `Marshaler`.

    ```mojo
    from core.encoding.json import Marshaler
    from core.io import Byte


    def to_json[T: Marshaler](value: T) raises -> List[Byte]:
        return value.marshal_json()
    ```

    Go finds this with a type assertion while the program runs and this is a
    constraint checked while it is compiled, which is the difference every trait
    in this library has from the interface it answers for. A type that cannot
    write itself is a compile error at the call rather than a `Marshal` that
    fails on some inputs and not others.
    """

    def marshal_json(self) raises -> List[Byte]:
        """This value as one JSON value, in a list the caller now owns.

        One value and nothing else, so the bytes drop into a document where a
        value goes. Whitespace inside them is the implementation's business:
        `marshal` compacts what comes back, which is what Go does with the
        result of `MarshalJSON` and is why an implementation may lay its output
        out however it likes.

        Raises if the value cannot be written. A float that is infinite or not
        a number is the case that comes up, since JSON has no way to spell
        either.
        """
        ...


trait Unmarshaler:
    """A type that can read itself back from JSON. Go's `Unmarshaler`.

    ```mojo
    from core.encoding.json import Unmarshaler
    from core.io import Byte


    def from_json[
        T: Unmarshaler, o: ImmOrigin
    ](mut value: T, data: Span[Byte, o]) raises:
        value.unmarshal_json(data)
    ```
    """

    def unmarshal_json[o: ImmOrigin](mut self, data: Span[Byte, o]) raises:
        """Set this value from `data`, which is one JSON value.

        Go asks an implementation to copy anything it wants to keep, because
        the decoder reuses the slice. A span cannot outlive its owner here,
        `docs/design.md` section 5, so the copy is not a convention a careless
        type can break.

        The library's rule for a failure is stricter than Go's: nothing is
        written unless the whole input is accepted, so a value handed to a call
        that refuses it is the value it was rather than a half read one.
        """
        ...


def marshal[T: Marshaler](value: T) raises -> List[Byte]:
    """`value` as compact JSON. Go's `Marshal`.

    ```mojo
    from core.encoding.json import RawMessage, marshal

    def main() raises:
        var held = RawMessage()
        held.unmarshal_json('{ "a" : [1, 2] }'.as_bytes())
        print(String(from_utf8_lossy=Span(marshal(held))))  # {"a":[1,2]}
    ```

    What comes back from `marshal_json` is compacted and checked, which is what
    Go does with the result of a `MarshalJSON` and is worth having for the same
    two reasons: a type that lays its output out prettily still produces one
    line here, and a type that produces bytes that are not JSON is caught at the
    call that made them rather than at the far end of a wire.

    The three characters that make a document unsafe to drop into a script tag
    go out as escapes, which is Go's default for `Marshal` and cannot be turned
    off on this call, again as in Go. `Encoder.set_escape_html` is the switch.
    """
    var written = value.marshal_json()
    var out = List[Byte]()
    _append_compact(out, Span(written), True)
    return out^


def marshal_indent[
    T: Marshaler, o1: ImmOrigin, o2: ImmOrigin
](value: T, prefix: StringSlice[o1], indent: StringSlice[o2]) raises -> List[
    Byte
]:
    """`value` as JSON with every element on its own line. Go's `MarshalIndent`.

    ```mojo
    from core.encoding.json import RawMessage, marshal_indent

    def main() raises:
        var held = RawMessage()
        held.unmarshal_json("[1,2]".as_bytes())
        print(String(from_utf8_lossy=Span(marshal_indent(held, "", "  "))))
        # [
        #   1,
        #   2
        # ]
    ```

    `marshal` and then `indent`, which is how Go builds it, so every line begins
    with `prefix` and then one copy of `indent` per level of nesting and the
    first line gets neither.
    """
    var compacted = marshal(value)
    var out = List[Byte]()
    _append_indent(out, Span(compacted), prefix, indent)
    return out^


def unmarshal[
    T: Unmarshaler, o: ImmOrigin
](data: Span[Byte, o], mut value: T) raises:
    """Read `data` into `value`. Go's `Unmarshal`.

    ```mojo
    from core.encoding.json import RawMessage, unmarshal

    def main() raises:
        var held = RawMessage()
        unmarshal('{"a":1}'.as_bytes(), held)
        print(held)  # {"a":1}
    ```

    Go takes a pointer and refuses one that is nil or is not a pointer at all,
    which is a run time check on something the caller wrote. The destination is
    a `mut` argument here, so there is nothing to pass that would fail that
    check and no `InvalidUnmarshalError` to raise.

    The whole document is checked before any of it is read, which is Go's order
    as well. It costs a pass and it buys the rule the rest of this library
    follows: a value handed to a call that refuses its input comes back the
    value it was.
    """
    valid_or_raise(data)
    value.unmarshal_json(data)


struct Encoder[W: IoWriter & Deinitable & Movable](Movable):
    """JSON values into a stream, one after another. Go's `Encoder`.

    ```mojo
    from core.encoding.json import Marshaler, new_encoder
    from core.io import Writer


    def send[
        W: Writer & Deinitable & Movable, T: Marshaler
    ](var dst: W, values: List[T]) raises:
        var enc = new_encoder(dst^)
        for i in range(len(values)):
            enc.encode(values[i])
    ```

    Every value is followed by a newline, which is Go's rule and the reason a
    stream of JSON values is readable as lines. Go gives two: it looks better
    when something has gone wrong and is being read by a person, and a number
    written with nothing after it gives a reader no way to know the digits have
    stopped.

    Nothing is buffered. A value is built in memory and goes out in one write,
    which is what Go does, so a sink that is a socket sees one value per call
    rather than a value split across several.

    Not `Copyable`. Two encoders over one sink would interleave.
    """

    var w: Self.W
    """The sink. Owned, so every write is a direct call rather than a call
    through an interface."""

    var escape_html: Bool
    """Whether `<`, `>` and `&` are spelled out as escapes on the way through.
    Go's unexported `escapeHTML`, set by `set_escape_html` and true unless
    changed."""

    var indent_prefix: String
    """What every line after the first begins with. Go's `indentPrefix`."""

    var indent_value: String
    """One level of nesting, repeated. Go's `indentValue`."""

    def __init__(out self, var w: Self.W):
        """Wrap `w`, with Go's defaults. Go's `NewEncoder`."""
        self.w = w^
        self.escape_html = True
        self.indent_prefix = String()
        self.indent_value = String()

    def encode[T: Marshaler](mut self, value: T) raises:
        """Write `value` and a newline. Go's `Encode`."""
        var written = value.marshal_json()
        self.encode_bytes(Span(written))

    def encode_bytes[o: ImmOrigin](mut self, data: Span[Byte, o]) raises:
        """Write one value that is already JSON, and a newline.

        Nothing of Go's. Go reaches its reflection walk for a struct and this
        reaches a generated `marshal_json(value)`, which hands back bytes rather
        than a value implementing anything, so this is where those bytes go.
        The document is compacted and checked on the way, the same as `encode`,
        so a generated encoder and a hand written one produce the same stream.
        """
        var out = List[Byte]()
        _append_compact(out, data, self.escape_html)
        # The newline goes on before the indenting rather than after it, which
        # is Go's order and matters: `indent` copies trailing whitespace, so the
        # newline survives, and putting it on afterwards would give a second one
        # for a document that ended in a line ending already.
        out.append(_NEWLINE)
        if self.indent_prefix != "" or self.indent_value != "":
            var shaped = List[Byte]()
            _append_indent(
                shaped, Span(out), self.indent_prefix, self.indent_value
            )
            _ = self.w.write(Span(shaped))
            return
        _ = self.w.write(Span(out))

    def set_indent(mut self, prefix: StringSlice, indent: StringSlice):
        """Lay every value out with `prefix` and `indent`. Go's `SetIndent`.

        Two empty strings turn it off again, which is Go's documented way of
        saying so.
        """
        self.indent_prefix = String(prefix)
        self.indent_value = String(indent)

    def set_escape_html(mut self, on: Bool):
        """Whether `<`, `>` and `&` are escaped on the way out. Go's
        `SetEscapeHTML`.

        On unless turned off, because a document going into a page is the case
        that is dangerous and the one nobody remembers to ask about.

        Turning it off stops escaping being added and does not take away
        escaping the value already carried. That is what Go's switch does to a
        value implementing `Marshaler`, and every value here is one.
        `docs/deviations.md` has the row.
        """
        self.escape_html = on


def new_encoder[W: IoWriter & Deinitable & Movable](var w: W) -> Encoder[W]:
    """An encoder over `w`. Go's `NewEncoder`.

    Go takes an `io.Writer` interface and this takes the concrete type, so every
    write is a direct call. `core.io.AnyWriter` is the way to hold one of
    several sinks in the same variable.
    """
    return Encoder[W](w^)
