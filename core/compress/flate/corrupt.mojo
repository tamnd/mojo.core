"""Where a DEFLATE stream stopped being one. Go's two decompressor errors.

Go declares `type CorruptInputError int64` and `type InternalError string`, so
in both cases the error value is the payload and a caller reads it with a type
assertion. There is nothing to assert against here, design.md section 8, so the
offset and the message go on the error record as fields and these read them
back.

The two are kept apart because they say different things about whose fault a
failure is. A corrupt input means the bytes are not a DEFLATE stream and the
sender is at fault. An internal error means the decompressor reached a state it
has no branch for, and there is a bug here. Go raises the second in exactly one
place, behind a range check that makes it unreachable, and it is ported anyway
because a reader who sees the message needs the word `internal` in it to know
which of the two they are looking at.
"""

from core.errors import Report, capture, matches
from core.errors.codes import ErrFlateCorruptInput, ErrFlateInternal


struct CorruptInputError(Copyable, Movable, Writable):
    """The offset a decompressor had reached. Go's `CorruptInputError`.

    Built from a raised error by `of`, not by hand.

    ```mojo
    from core.compress.flate import CorruptInputError, Reader, new_reader
    from core.io import read_all


    def say_where_it_went_wrong[R: Reader & Deinitable & Movable](var src: R):
        try:
            var r = new_reader(src^)
            _ = read_all(r)
        except e:
            var bad = CorruptInputError.of(e)
            if bad:
                print("corrupt input before offset", bad.value().offset)
    ```
    """

    var offset: Int64
    """How many bytes of the stream had been read when it was refused.

    Not the offset of the byte that is wrong. A DEFLATE stream is a bit stream
    and a symbol may straddle two bytes, so the only honest number is how far
    the reader had got, which is what Go's is too.
    """

    def __init__(out self, offset: Int64):
        self.offset = offset

    @staticmethod
    def of(e: Error) -> Optional[Self]:
        """`e` as a `CorruptInputError`, or nothing if it came from elsewhere.

        Go's `err.(flate.CorruptInputError)`. Nothing comes back when the
        stream simply ran out, which raises `ErrUnexpectedEOF`, or when the
        reader underneath failed, which raises whatever it raised.
        """
        if not matches(e, ErrFlateCorruptInput):
            return None
        var found = capture(e).field("offset")
        if not found:
            return None
        try:
            return Self(Int64(Int(found.value())))
        except:
            return None

    def error(self) -> String:
        """Go's `Error` text, byte for byte.

        `flate: corrupt input before offset 1`.
        """
        return "flate: corrupt input before offset " + String(self.offset)

    def write_to[W: Writer](self, mut writer: W):
        """`error` as this library spells `String`."""
        writer.write(self.error())


struct InternalError(Copyable, Movable, Writable):
    """A state the decompressor has no branch for. Go's `InternalError`.

    Built from a raised error by `of`, not by hand. Seeing one is a bug here
    rather than a bad stream.
    """

    var msg: String
    """What the decompressor was doing, in Go's words."""

    def __init__(out self, msg: StringSlice):
        self.msg = String(msg)

    @staticmethod
    def of(e: Error) -> Optional[Self]:
        """`e` as an `InternalError`, or nothing if it came from elsewhere.

        Go's `err.(flate.InternalError)`.
        """
        if not matches(e, ErrFlateInternal):
            return None
        var found = capture(e).field("msg")
        if not found:
            return None
        return Self(found.value())

    def error(self) -> String:
        """Go's `Error` text, byte for byte.

        `flate: internal error: unexpected length code`.
        """
        return "flate: internal error: " + self.msg

    def write_to[W: Writer](self, mut writer: W):
        """`error` as this library spells `String`."""
        writer.write(self.error())


def _corrupt(offset: Int64) -> Error:
    """The raise every refusal in the decompressor makes.

    One function rather than a `Report` built at each site, because the code,
    the field name and the message all have to agree for `CorruptInputError.of`
    to find them, and three of those in a dozen places is three chances to
    disagree.
    """
    return (
        Report(CorruptInputError(offset).error())
        .with_code(ErrFlateCorruptInput)
        .with_field("offset", String(offset))
        .error()
    )


def _internal(msg: StringSlice) -> Error:
    """The raise for a state that should be unreachable. Go has one caller."""
    return (
        Report(InternalError(msg).error())
        .with_code(ErrFlateInternal)
        .with_field("msg", String(msg))
        .error()
    )
