"""What a failed conversion records. Go's `NumError`, read rather than raised.

Every parser in this package raises with the same three pieces of information
attached: which function refused, what text it was given, and why. Go carries
those in a `*NumError` and returns it. There is no error value to return here,
so they go on the record as a code and two fields, and `NumError.of(e)` reads
them back out.

That means the shape of the failure survives the trip without the caller having
to type assert, which `core.errors` does not have and design.md section 8 says
it will not. The common questions do not need this type at all:
`errors.matches(e, ErrSyntax)` asks why, and `errors.field(e, "num")` asks what
the text was. `NumError` is for the caller who wants all of it at once, usually
to build their own message.

Go's `Err` is an `error` and can be a sentinel or a fresh value; here it is
always a code, which is why `ErrBase` and `ErrBitSize` exist. Go throws those
two away when it crosses out of `internal/strconv`, so a Go caller cannot tell
"you asked for base 37" from "your digits are wrong" without reading the
message. Here they are separate codes and the answer is a comparison.
"""

from core.errors import Code, Report, capture
from core.errors.codes import ErrBase, ErrBitSize, ErrRange, ErrSyntax

from core.strconv.quote import quote


def _reason(c: Code) -> String:
    """Go's `Error` text for a code, which is the tail of every message."""
    if c == ErrRange:
        return "value out of range"
    if c == ErrSyntax:
        return "invalid syntax"
    if c == ErrBase:
        return "invalid base"
    if c == ErrBitSize:
        return "invalid bit size"
    return "unknown error"


struct NumError(Copyable, Movable, Writable):
    """A conversion that failed, with the function, the input and the reason.

    Built from a raised error by `of`, not by hand, and every field is a copy,
    so it outlives the `Error` it came from.

    ```mojo
    from core.strconv import NumError, parse_int

    def main():
        try:
            _ = parse_int("hello", 10, 64)
        except e:
            var failure = NumError.of(e)
            if failure:
                print(failure.value().func)  # parse_int
                print(failure.value().num)  # hello
                print(failure.value().error())
    ```
    """

    var func: String
    """The function that refused, in this library's spelling: `parse_int`."""

    var num: String
    """The text it was given, copied."""

    var err: Code
    """Why: `ErrSyntax`, `ErrRange`, `ErrBase` or `ErrBitSize`."""

    def __init__(out self, var func: String, var num: String, err: Code):
        self.func = func^
        self.num = num^
        self.err = err

    @staticmethod
    def of(e: Error) -> Optional[Self]:
        """`e` as a `NumError`, or nothing if it did not come from here.

        Go's `err.(*strconv.NumError)`. Nothing comes back when the error was
        raised somewhere else, which is the case a type assertion covers by
        failing and this covers by being empty.
        """
        var value = capture(e)
        var name = value.field("func")
        var text = value.field("num")
        if not name or not text:
            return None
        var c = value.code()
        if (
            c != ErrSyntax
            and c != ErrRange
            and c != ErrBase
            and c != ErrBitSize
        ):
            return None
        return Self(name.value(), text.value(), c)

    def unwrap(self) -> Code:
        """The reason on its own. Go's `Unwrap`, which hands back the `Err`.

        Go needs it so `errors.Is(err, strconv.ErrSyntax)` sees through the
        wrapper. Nothing here is wrapped, so `errors.matches(e, ErrSyntax)`
        already worked on the error itself and this is for symmetry.
        """
        return self.err

    def error(self) -> String:
        """The message Go's `Error` builds, character for character except the
        function name, which is spelled the way this library spells it.

        `strconv.parse_int: parsing "hello": invalid syntax`.
        """
        return (
            String("strconv.")
            + self.func
            + ": parsing "
            + quote(self.num)
            + ": "
            + _reason(self.err)
        )

    def write_to[W: Writer](self, mut writer: W):
        writer.write(self.error())


def _num_error[
    o: ImmOrigin
](func: StringSlice[ImmStaticOrigin], num: StringSlice[o], c: Code) -> Error:
    """The raise every parser in this package makes.

    One place, so that the message and the two fields cannot drift apart, and
    so that `NumError.of` has exactly one shape to read. `func` and `num` are
    slices rather than `String`s because every parser passes them on the way
    in and only the failing call ever copies them.
    """
    return (
        Report(
            String("strconv.")
            + String(func)
            + ": parsing "
            + quote(num)
            + ": "
            + _reason(c)
        )
        .with_code(c)
        .with_field("func", String(func))
        .with_field("num", String(num))
        .error()
    )


def _syntax_error[
    o: ImmOrigin
](func: StringSlice[ImmStaticOrigin], num: StringSlice[o]) -> Error:
    """Go's `syntaxError`. The text was not a number of the kind asked for."""
    return _num_error(func, num, ErrSyntax)


def _range_error[
    o: ImmOrigin
](func: StringSlice[ImmStaticOrigin], num: StringSlice[o]) -> Error:
    """Go's `rangeError`. The number does not fit the bit size asked for."""
    return _num_error(func, num, ErrRange)


def _base_error[
    o: ImmOrigin
](func: StringSlice[ImmStaticOrigin], num: StringSlice[o], base: Int) -> Error:
    """Go's `baseError`, with the base on the record as well as in the message.

    Go writes it into the message and nowhere else. Here it is a field, so a
    caller can read the number back without parsing English.
    """
    return (
        Report(
            String("strconv.")
            + String(func)
            + ": parsing "
            + quote(num)
            + ": invalid base "
            + String(base)
        )
        .with_code(ErrBase)
        .with_field("func", String(func))
        .with_field("num", String(num))
        .with_field("base", String(base))
        .error()
    )


def _bit_size_error[
    o: ImmOrigin
](
    func: StringSlice[ImmStaticOrigin], num: StringSlice[o], bit_size: Int
) -> Error:
    """Go's `bitSizeError`, with the bit size on the record for the same
    reason the base is above."""
    return (
        Report(
            String("strconv.")
            + String(func)
            + ": parsing "
            + quote(num)
            + ": invalid bit size "
            + String(bit_size)
        )
        .with_code(ErrBitSize)
        .with_field("func", String(func))
        .with_field("num", String(num))
        .with_field("bits", String(bit_size))
        .error()
    )
