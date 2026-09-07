"""The types a DER value arrives as when a machine type will not do.

Four of Go's are defined types over `int`, `bool` and `[]byte`, and they exist
so that reflection can tell a field that wants an ENUMERATED from a field that
wants an INTEGER. There is no reflection here and the generator reads the name
a field was declared with, so `Enumerated`, `Flag` and `RawContent` are aliases
rather than wrappers: the name is what carries the meaning either way, and an
alias leaves the arithmetic and the indexing alone.

`BitString`, `ObjectIdentifier` and `RawValue` are structs in Go too, and are
structs here for the same reason, which is that each of them is more than one
number.
"""

from core.io import Byte

from .tags import ClassUniversal, TagNull

comptime Enumerated = Int
"""An ENUMERATED, which is an INTEGER out of a list somebody wrote down. Go's
`Enumerated`, a defined type over `int` there and a name for `Int` here."""

comptime Flag = Bool
"""A field that is true when it is present and false when it is not, whatever
the bytes in it say. Go's `Flag`, a defined type over `bool`."""

comptime RawContent = List[Byte]
"""The undecoded bytes of the structure a field belongs to, kept so that a
signature over them can be checked after they have been read.

Go says the first field of a struct must have this type and that no other
field may. The generator enforces the same rule, because the bytes it holds
are the whole of the structure and there is only one of those.
"""


struct BitString(Copyable, Movable, Writable):
    """A BIT STRING: a count of bits and the bytes they are packed into.

    Go's `BitString`. The bits are packed from the top of the first byte down,
    the padding at the end of the last byte is zero, and `bit_length` is what
    says where the bits stop, since the byte count cannot.

    ```mojo
    from core.encoding.asn1 import BitString

    def main():
        var bits = BitString([UInt8(0x80)], 1)
        print(bits.at(0))  # 1
        print(bits.at(1))  # 0, because it is past the end
    ```
    """

    var bytes: List[Byte]
    """The bits, packed. Go's `Bytes`."""

    var bit_length: Int
    """How many of the bits are real. Go's `BitLength`."""

    def __init__(out self):
        """No bits at all, which is what an empty BIT STRING holds."""
        self.bytes = List[Byte]()
        self.bit_length = 0

    def __init__(out self, var bytes: List[Byte], bit_length: Int):
        self.bytes = bytes^
        self.bit_length = bit_length

    def at(self, i: Int) -> Int:
        """The bit at `i`, or zero if `i` is outside the string.

        Go returns zero for an index out of range rather than panicking, which
        is unusual for Go and is kept, because the callers that matter are
        reading key usage bits out of a certificate that may simply be shorter
        than the list of bits the specification defines.
        """
        if i < 0 or i >= self.bit_length:
            return 0
        var byte = self.bytes[i // 8]
        return Int((byte >> Byte(7 - (i % 8))) & 1)

    def right_align(self) -> List[Byte]:
        """The same bits with the padding moved to the front.

        Go's `RightAlign`, which documents that the slice it returns may share
        memory with the `BitString`. This always returns a list of its own,
        because nothing in this library hands back a view into something a
        caller still owns.
        """
        var shift = Byte(8 - (self.bit_length % 8))
        if shift == 8 or len(self.bytes) == 0:
            return self.bytes.copy()

        var out = List[Byte](capacity=len(self.bytes))
        out.append(self.bytes[0] >> shift)
        for i in range(1, len(self.bytes)):
            out.append(
                (self.bytes[i - 1] << (8 - shift)) | (self.bytes[i] >> shift)
            )
        return out^

    def __eq__(self, other: Self) -> Bool:
        """The same bits and the same count of them."""
        return self.bit_length == other.bit_length and self.bytes == other.bytes

    def __ne__(self, other: Self) -> Bool:
        return not (self == other)

    def write_to[W: Writer](self, mut writer: W):
        """The bits, most significant first, as ones and zeros."""
        for i in range(self.bit_length):
            writer.write("1" if self.at(i) == 1 else "0")


struct ObjectIdentifier(Copyable, Movable, Sized, Writable):
    """An OBJECT IDENTIFIER: the numbers of a name in a registered hierarchy.

    Go's `ObjectIdentifier` is a `[]int` and this holds one, because a slice
    with methods on it is a Go shape rather than a Mojo one. Indexing and
    `len` work the way they would on the list.

    ```mojo
    from core.encoding.asn1 import ObjectIdentifier

    def main():
        var sha256 = ObjectIdentifier([2, 16, 840, 1, 101, 3, 4, 2, 1])
        print(sha256)  # 2.16.840.1.101.3.4.2.1
    ```
    """

    var values: List[Int]
    """The numbers, from the root down. Go has no name for this because the
    slice is the type."""

    def __init__(out self):
        """The empty identifier, which no encoding produces and a caller
        building one needs."""
        self.values = List[Int]()

    def __init__(out self, var values: List[Int]):
        self.values = values^

    def __len__(self) -> Int:
        return len(self.values)

    def __getitem__(self, i: Int) -> Int:
        return self.values[i]

    def equal(self, other: Self) -> Bool:
        """Whether the two name the same thing. Go's `Equal`."""
        return self.values == other.values

    def __eq__(self, other: Self) -> Bool:
        return self.equal(other)

    def __ne__(self, other: Self) -> Bool:
        return not self.equal(other)

    def write_to[W: Writer](self, mut writer: W):
        """The numbers with dots between them. Go's `String`."""
        for i in range(len(self.values)):
            if i > 0:
                writer.write(".")
            writer.write(self.values[i])


struct RawValue(Copyable, Movable, Writable):
    """A value that was read but not decoded. Go's `RawValue`.

    Everything about the header, plus the contents and plus the whole encoding
    including the header. Go's two slices point into the input; these are lists
    of their own, so a `RawValue` kept after the bytes it came from have gone
    is still the value that was read.
    """

    var tag_class: Int
    """Universal, application, context specific or private. Go calls this
    `Class`, which is a Mojo keyword."""

    var tag: Int
    """The tag number. Go's `Tag`."""

    var is_compound: Bool
    """Whether the contents are values rather than bytes. Go's
    `IsCompound`."""

    var bytes: List[Byte]
    """The contents, without the header. Go's `Bytes`."""

    var full_bytes: List[Byte]
    """The contents with the header in front of them, which is the encoding
    of the value entire. Go's `FullBytes`."""

    def __init__(out self):
        """A zero value, which is what a field with no value read into it
        holds."""
        self.tag_class = 0
        self.tag = 0
        self.is_compound = False
        self.bytes = List[Byte]()
        self.full_bytes = List[Byte]()

    def __init__(
        out self,
        tag_class: Int,
        tag: Int,
        is_compound: Bool,
        var bytes: List[Byte],
        var full_bytes: List[Byte],
    ):
        self.tag_class = tag_class
        self.tag = tag
        self.is_compound = is_compound
        self.bytes = bytes^
        self.full_bytes = full_bytes^

    def __eq__(self, other: Self) -> Bool:
        return (
            self.tag_class == other.tag_class
            and self.tag == other.tag
            and self.is_compound == other.is_compound
            and self.bytes == other.bytes
            and self.full_bytes == other.full_bytes
        )

    def __ne__(self, other: Self) -> Bool:
        return not (self == other)

    def write_to[W: Writer](self, mut writer: W):
        """The header and how many bytes of contents there are."""
        writer.write("asn1.RawValue(class=", self.tag_class)
        writer.write(", tag=", self.tag)
        writer.write(", compound=", self.is_compound)
        writer.write(", bytes=", len(self.bytes), ")")


def NullRawValue() -> RawValue:
    """A `RawValue` holding an ASN.1 NULL and nothing else.

    Go has this as a package level variable, which cannot be one here because
    a `List` is not a compile time value, so it is a function that builds one.
    `core.unicode` does the same with Go's six maps for the same reason.
    """
    return RawValue(ClassUniversal, TagNull, False, List[Byte](), List[Byte]())


def NullBytes() -> List[Byte]:
    """The DER encoding of NULL, which is the tag and a length of zero.

    Go's `NullBytes`, a package level variable there and a function here.
    """
    var out: List[Byte] = [Byte(TagNull), Byte(0)]
    return out^
