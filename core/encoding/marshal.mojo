"""The six traits, one method each.

Go declares these as interfaces so that a codec can ask a value at run time
whether it knows how to encode itself:

```go
if m, ok := v.(encoding.TextMarshaler); ok {
    return m.MarshalText()
}
```

There is no such question here. A trait is a compile time constraint rather than
a value, design.md section 1, so a codec that wants a type to encode itself
takes it as a generic parameter bound by the trait and the check happens when
the program is compiled. What Go discovers, this decides.

The method signatures are the ones the library already had. `marshal_binary`
hands back a fresh list, `append_binary` grows a list the caller owns and
returns how many bytes it added, and `unmarshal_binary` reads a span and sets
the receiver. `Time`, `big.Int`, `big.Float`, `big.Rat`, `rand.PCG` and
`rand.ChaCha8` were all written that way before this package existed, and the
traits are the shape those methods already have rather than a new one they were
moved to.

## Why the appenders are separate traits

Go added `AppendBinary` and `AppendText` in 1.24, as two more interfaces beside
the four that were already there, and a type is free to implement any subset.
The same six are declared here rather than four with the appenders folded in,
because folding them in would mean a type that only wants to hand back bytes has
to write the appending form as well, and the six are what a reader coming from
Go will look for by name.

The marshalling method of a type that has both is one line: build a list, append
into it, return it. That line is written out in each of the six types rather
than inherited from a default body, for the reason the trait has no default
body at all: a default `marshal_binary` calling `append_binary` would make every
`BinaryMarshaler` a `BinaryAppender` too, which is exactly the coupling Go's
split avoids.
"""

comptime Byte = UInt8
"""What an encoding is made of. Go's `byte`, and `[]byte` is `Span[Byte, o]`."""


trait BinaryMarshaler:
    """A type that can write itself out as bytes. Go's `BinaryMarshaler`.

    ```mojo
    from core.encoding import BinaryMarshaler


    def to_bytes[T: BinaryMarshaler](value: T) raises -> List[UInt8]:
        return value.marshal_binary()
    ```
    """

    def marshal_binary(self) raises -> List[Byte]:
        """This value as bytes, in a list the caller now owns.

        The bytes are the whole of the value and nothing else, so
        `unmarshal_binary` given them produces something equal to this. What the
        format is is the type's business and no codec above may depend on it,
        which is why there is no version number here and why the types that need
        one put it in their own first byte.

        Raises if the value cannot be written, which for most types is never.
        """
        ...


trait BinaryUnmarshaler:
    """A type that can read itself back from bytes. Go's `BinaryUnmarshaler`.

    ```mojo
    from core.encoding import BinaryUnmarshaler


    def from_bytes[
        T: BinaryUnmarshaler, o: ImmOrigin
    ](mut value: T, data: Span[UInt8, o]) raises:
        value.unmarshal_binary(data)
    ```
    """

    def unmarshal_binary[o: ImmOrigin](mut self, data: Span[Byte, o]) raises:
        """Set this value from `data`, which is copied and not kept.

        Go's documentation asks an implementation to copy anything it wants to
        keep, because the caller may reuse the slice. Here the span cannot
        outlive its owner at all, section 5, so the copy is not a convention
        that a careless type can break.

        The library's rule for a failure is stricter than Go's. Nothing is
        written unless the whole input is accepted, so a value handed to a call
        that refuses it is the value it was rather than a half decoded one.
        """
        ...


trait BinaryAppender:
    """A type that can write itself out into a list. Go's `BinaryAppender`.

    ```mojo
    from core.encoding import BinaryAppender


    def onto[T: BinaryAppender](value: T, mut dst: List[UInt8]) raises -> Int:
        return value.append_binary(dst)
    ```
    """

    def append_binary(self, mut dst: List[Byte]) raises -> Int:
        """Append this value's bytes to `dst` and return how many were added.

        Go returns the grown slice and this returns the count, which is the rule
        every appending function in this library follows, `strconv.append_int`
        and `utf8.append_rune` included: a list is grown in place because there
        is no shared ownership to hand it back through.

        Whatever was in `dst` is still there and is not read. A call that raises
        may have appended some of the bytes, and a caller who cannot have that
        truncates `dst` back to the length it noted first.
        """
        ...


trait TextMarshaler:
    """A type that can write itself out as text. Go's `TextMarshaler`.

    ```mojo
    from core.encoding import TextMarshaler


    def to_text[T: TextMarshaler](value: T) raises -> List[UInt8]:
        return value.marshal_text()
    ```
    """

    def marshal_text(self) raises -> List[Byte]:
        """This value as UTF-8 text, in a list the caller now owns.

        Bytes rather than a `String`, matching Go, because the callers are
        codecs that are about to write the answer into a buffer and a `String`
        would be an allocation in the middle of that. The bytes are valid UTF-8
        and `unmarshal_text` given them produces something equal to this.
        """
        ...


trait TextUnmarshaler:
    """A type that can read itself back from text. Go's `TextUnmarshaler`.

    ```mojo
    from core.encoding import TextUnmarshaler


    def from_text[
        T: TextUnmarshaler, o: ImmOrigin
    ](mut value: T, text: Span[UInt8, o]) raises:
        value.unmarshal_text(text)
    ```
    """

    def unmarshal_text[o: ImmOrigin](mut self, text: Span[Byte, o]) raises:
        """Set this value from the UTF-8 text in `text`, which is not kept.

        The same two rules `unmarshal_binary` has: the span is copied from
        rather than held, and nothing is written unless the whole input is
        accepted.
        """
        ...


trait TextAppender:
    """A type that can write its text into a list. Go's `TextAppender`.

    ```mojo
    from core.encoding import TextAppender


    def onto[T: TextAppender](value: T, mut dst: List[UInt8]) raises -> Int:
        return value.append_text(dst)
    ```
    """

    def append_text(self, mut dst: List[Byte]) raises -> Int:
        """Append this value's text to `dst` and return how many bytes it added.

        The count is bytes and not characters, for the reason every length in
        this library is bytes: a caller slicing `dst` afterwards is slicing a
        list of bytes. `append_binary` above says the rest of the contract, and
        it is the same one.
        """
        ...
