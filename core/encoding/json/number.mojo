"""A number kept as it was written. Go's `Number`.

JSON has one number type and it is not a machine type. `1e400` is a number a
document may hold and no float can, and an integer with twenty digits is a
number a document may hold and no `Int64` can, so reading every number as a
`Float64` loses documents that were fine. A `Number` is the text, and the
caller says which machine type they wanted and finds out there whether it fits.

The other thing this buys is a round trip. Reading `1.0` as a float and writing
it back gives `1`, and reading it as a `Number` and writing it back gives
`1.0`, which matters for anything that has to reproduce a document rather than
merely understand it.
"""

from core.strconv import parse_float, parse_int


struct Number(Copyable, Equatable, Movable, Writable):
    """The text of a number, not yet turned into one. Go's `Number`.

    ```mojo
    from core.encoding.json import Number

    def main() raises:
        var n = Number("1e400")
        print(n.string())  # 1e400
        print(n.int64())  # raises: value out of range
    ```

    Go makes this a named string type, so a Go caller can convert it to a
    string for free and compare two with `==`. That is what `string` and the
    comparison here are for.

    Nothing checks that the text is a number. Go does not check either, and its
    encoder is where an invalid one is caught, which is the same place it will
    be caught here.
    """

    var text: String
    """The number exactly as the document wrote it.

    Go has no field, because its `Number` is the string. Reading this is Go's
    `string(n)` and `string` is Go's `String`, and the two are the same value.
    """

    def __init__(out self, text: StringSlice):
        """Hold `text` as a number."""
        self.text = String(text)

    def __eq__(self, other: Self) -> Bool:
        """Whether the two were written the same way.

        Text rather than value, which is what Go's `==` on a string type does.
        `1.0` and `1` are the same number and are not equal here, and a caller
        who wanted the other question asks `float64` on both.
        """
        return self.text == other.text

    def __ne__(self, other: Self) -> Bool:
        return self.text != other.text

    def string(self) -> String:
        """The text. Go's `String`, which is the conversion written out."""
        return self.text.copy()

    def float64(self) raises -> Float64:
        """The number as a `Float64`. Go's `Float64`.

        `core.strconv.parse_float`, so it is correctly rounded rather than
        approximately parsed: the result is the float nearest the value the
        text names, and a value too large for one raises rather than becoming
        an infinity.
        """
        return parse_float(self.text, 64)

    def int64(self) raises -> Int64:
        """The number as an `Int64`. Go's `Int64`.

        Base ten, so a number written with a decimal point or an exponent
        raises even when its value is a whole number: `1.0` is not an integer
        literal and Go refuses it here for the same reason.
        """
        return parse_int(self.text, 10, 64)

    def write_to[W: Writer](self, mut writer: W):
        writer.write(self.text)
