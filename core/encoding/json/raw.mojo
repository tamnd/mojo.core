"""A value kept as the bytes it was written with. Go's `RawMessage`.

The use is one Go programs make constantly: a document whose shape is decided
by something inside it. A message with a `kind` and a `payload` cannot be read
in one pass, because what the payload is depends on the kind, which is not known
until the kind has been read. So the payload is kept as its bytes and read a
second time once there is something to read it into.

Go spells it `type RawMessage []byte`, which is a slice with two methods hung
off it. That shape is not available here, since a method needs a struct to be on
and a slice of somebody else's bytes needs an origin to be tied to. So it is a
struct holding a `List[Byte]` of its own, which also means a raw message
outlives the document it came out of rather than pointing into a buffer the next
read moves.

Empty is `null`, which is Go's rule for a nil `RawMessage` and is what makes the
zero value of a struct field encode to something a decoder will read back.
"""

from core.io import Byte

from .marshal import Marshaler, Unmarshaler
from .scan import valid_or_raise


struct RawMessage(
    Copyable, Equatable, Marshaler, Movable, Sized, Unmarshaler, Writable
):
    """One JSON value, not yet read. Go's `RawMessage`.

    ```mojo
    from core.encoding.json import RawMessage

    def main() raises:
        var held = RawMessage()
        held.unmarshal_json('{"a":[1,2]}'.as_bytes())
        print(len(held))  # 11
        print(held)  # {"a":[1,2]}
    ```

    What it holds is a whole JSON value with its insignificant whitespace as it
    arrived, so writing it back out gives the document that came in rather than
    a reformatting of it. `core.encoding.json.compact` is the way to have the
    whitespace taken out.
    """

    var bytes: List[Byte]
    """The value, exactly as it was written.

    Go has no field, because its `RawMessage` is the slice. Reading this is
    Go's `[]byte(m)`.
    """

    def __init__(out self):
        """Nothing, which is the field a document did not carry.

        Writes as `null`, the same as Go's nil, so a struct that came in
        without the field goes back out with the field explicitly empty rather
        than with a hole where a value belongs.
        """
        self.bytes = List[Byte]()

    def __init__(out self, data: Span[Byte, _]):
        """A copy of `data`, taken as it is.

        Nothing is checked here. A raw message usually comes from a decoder
        that has already been over the bytes, and paying for a second pass on
        every one of them would be paying for a check that was already made.
        `unmarshal_json` is the constructor that checks.
        """
        self.bytes = List[Byte](data)

    def __len__(self) -> Int:
        """How many bytes it holds. Go's `len` on the slice."""
        return len(self.bytes)

    def __eq__(self, other: Self) -> Bool:
        """Whether the two hold the same bytes.

        Bytes rather than values, so `{"a":1}` and `{ "a" : 1 }` are not equal
        and neither are `1` and `1.0`. That is the comparison the type is for:
        a raw message is the text, and a caller who wanted the values compares
        what they read out of it.
        """
        if len(self.bytes) != len(other.bytes):
            return False
        for i in range(len(self.bytes)):
            if self.bytes[i] != other.bytes[i]:
                return False
        return True

    def __ne__(self, other: Self) -> Bool:
        return not (self == other)

    def marshal_json(self) raises -> List[Byte]:
        """The bytes, to be written where a value goes. Go's `MarshalJSON`.

        Go returns `null` for a nil message and so does this for an empty one,
        because a value has to be written where a field says there is one and
        the empty message is the one nothing was read into.

        It raises where Go's does not, since Go's signature has an error in it
        that is always nil. There is nothing here that can raise either, and
        the `raises` is on it so that a caller writing a marshaller by hand can
        call it in the same place they call the ones that do.
        """
        if len(self.bytes) == 0:
            return List[Byte]("null".as_bytes())
        return self.bytes.copy()

    def unmarshal_json[o: ImmOrigin](mut self, data: Span[Byte, o]) raises:
        """Keep `data` as the value. Go's `UnmarshalJSON`.

        Go copies without looking, on the reasoning that the only caller is its
        own decoder and that decoder has already scanned the bytes. This is a
        call anybody can make with anything, so it scans: a raw message that is
        not one JSON value would be a value that writes itself back out and
        breaks the document it is written into, and finding that out at the far
        end of a wire is worse than finding it out here.
        """
        valid_or_raise(data)
        self.bytes = List[Byte](data)

    def write_to[W: Writer](self, mut writer: W):
        """The value as it was written, or `null` for an empty one."""
        if len(self.bytes) == 0:
            writer.write("null")
            return
        writer.write(String(from_utf8_lossy=Span(self.bytes)))
