"""What kind of thing an argument is, decided when the program is compiled.

There is no reflection in Mojo, so nothing here can ask a value what it is. The
type is a parameter, though, and `comptime if T == Int` compares two types
exactly, so a chain of those is a complete answer for the types this library
knows about and `OTHER` covers the rest.

Trait conformance is the obvious alternative and it does not work. `Float64`
conforms to `Intable` and `Indexer`, `Bool` conforms to `Intable` and
`Floatable`, and `conforms_to` cannot tell a whole number from a fraction. That
is not a detail: `%d` on a float has to be an error, and a classifier that
answers "it is Intable" would print `3` for `3.7` and call it correct.

The names are Go's rather than Mojo's. They are only ever seen inside an error
marker, `%!d(string=hi)`, which is Go's text and is compared against Go's own
output byte for byte in the differential suite. A `String` here is a `string`
there, and spelling it the Mojo way would make our markers something a Go
programmer has to translate for no gain.
"""

comptime OTHER = 0
"""Anything `Writable` that is not one of the kinds below. It prints through
whatever it writes, which is what a Go type with a `String` method does."""

comptime SIGNED = 1
comptime UNSIGNED = 2
comptime FLOAT = 3
comptime TEXT = 4
comptime BOOLEAN = 5


def kind_of[T: Writable]() -> Int:
    """Which of the kinds above `T` is."""
    comptime if T == Int:
        return SIGNED
    elif T == Int8:
        return SIGNED
    elif T == Int16:
        return SIGNED
    elif T == Int32:
        return SIGNED
    elif T == Int64:
        return SIGNED
    elif T == UInt:
        return UNSIGNED
    elif T == UInt8:
        return UNSIGNED
    elif T == UInt16:
        return UNSIGNED
    elif T == UInt32:
        return UNSIGNED
    elif T == UInt64:
        return UNSIGNED
    elif T == Float64:
        return FLOAT
    elif T == Float32:
        return FLOAT
    elif T == String:
        return TEXT
    elif T == StaticString:
        return TEXT
    elif T == Bool:
        return BOOLEAN
    else:
        return OTHER


def name_of[T: Writable]() -> StaticString:
    """What Go calls the type `T` stands in for.

    `OTHER` has no name to give. Go would print the type here and we have no
    way to ask for one, so the marker says `value` and the compile time warning
    is what the programmer is expected to act on.
    """
    comptime if T == Int:
        return "int"
    elif T == Int8:
        return "int8"
    elif T == Int16:
        return "int16"
    elif T == Int32:
        return "int32"
    elif T == Int64:
        return "int64"
    elif T == UInt:
        return "uint"
    elif T == UInt8:
        return "uint8"
    elif T == UInt16:
        return "uint16"
    elif T == UInt32:
        return "uint32"
    elif T == UInt64:
        return "uint64"
    elif T == Float64:
        return "float64"
    elif T == Float32:
        return "float32"
    elif T == String:
        return "string"
    elif T == StaticString:
        return "string"
    elif T == Bool:
        return "bool"
    else:
        return "value"


def float_bits[T: Writable]() -> Int:
    """How wide the float is, which decides what the shortest text for it is.

    `%v` of `Float32(1.0 / 3)` is `0.33333334` and `%v` of the same division in
    double precision is `0.3333333333333333`. Rounding to the narrower type and
    then printing it as if it were wide gives neither.
    """
    comptime if T == Float32:
        return 32
    else:
        return 64


def as_uint64[T: Writable](value: T) -> UInt64:
    """The bits of an integer argument, sign extended if it is signed.

    Go passes every integer through `uint64` and remembers separately whether
    it was signed, which is what makes one formatting routine enough for ten
    types. `%c` of `int32(-1)` is `U+FFFD` because the conversion goes this
    way, so doing it any other way would be a different program.
    """
    comptime if T == Int:
        return Int64(rebind[Int](value)).cast[DType.uint64]()
    elif T == Int8:
        return rebind[Int8](value).cast[DType.int64]().cast[DType.uint64]()
    elif T == Int16:
        return rebind[Int16](value).cast[DType.int64]().cast[DType.uint64]()
    elif T == Int32:
        return rebind[Int32](value).cast[DType.int64]().cast[DType.uint64]()
    elif T == Int64:
        return rebind[Int64](value).cast[DType.uint64]()
    elif T == UInt:
        return UInt64(rebind[UInt](value))
    elif T == UInt8:
        return rebind[UInt8](value).cast[DType.uint64]()
    elif T == UInt16:
        return rebind[UInt16](value).cast[DType.uint64]()
    elif T == UInt32:
        return rebind[UInt32](value).cast[DType.uint64]()
    elif T == UInt64:
        return rebind[UInt64](value)
    else:
        return 0


def as_float64[T: Writable](value: T) -> Float64:
    """A float argument as the widest float, with its own width remembered by
    `float_bits`."""
    comptime if T == Float32:
        return rebind[Float32](value).cast[DType.float64]()
    elif T == Float64:
        return rebind[Float64](value)
    else:
        return 0.0


def as_text[T: Writable](value: T) -> String:
    """A text argument, or what anything else writes.

    The `OTHER` branch is the one that makes `%s` and `%v` work on a type this
    library has never heard of: it writes itself, the same way `print` makes it
    write itself, and everything after that treats the result as a string.
    """
    comptime if T == String:
        return rebind[String](value)
    elif T == StaticString:
        return String(rebind[StaticString](value))
    else:
        return String(value)


def as_bool[T: Writable](value: T) -> Bool:
    """A boolean argument."""
    comptime if T == Bool:
        return rebind[Bool](value)
    else:
        return False


def as_index[T: Writable](value: T) -> Int:
    """An integer argument as a width or a precision.

    Go takes a `*` width from any integer type and refuses anything else, which
    is why this is a separate conversion rather than a use of `as_uint64`: a
    negative width is Go's way of spelling the minus flag and the sign has to
    survive.
    """
    comptime if kind_of[T]() == UNSIGNED:
        return Int(as_uint64[T](value))
    elif kind_of[T]() == SIGNED:
        return Int(as_uint64[T](value).cast[DType.int64]())
    else:
        return 0
