"""How exact an answer was, and how to round one. Go declares both of these in
`float.go` and prints them from two generated files, `accuracy_string.go` and
`roundingmode_string.go`.

They live in their own file here for one reason: `Int.float64` has to say
whether the float it produced is the number or only the nearest one, and that
answer is an `Accuracy`. Go can put the type next to `Float` because a Go file
is not a compilation unit that anything has to import. Here `int.mojo` would
have to import `float.mojo` for a one byte enumeration, and `float.mojo` is the
largest file in the package.

Go writes each as a named integer type, so `Accuracy(-1)` and `Below` are the
same value and arithmetic on them compiles. These are structs wrapping the
number instead, which is what `core.errors.Code` does and for the same reason:
a mode and an accuracy are both small integers, and passing one where the other
was meant is a mistake worth refusing at compile time rather than one to find
in a rounding result.
"""


struct Accuracy(Copyable, Equatable, ImplicitlyCopyable, Movable, Writable):
    """Whether a rounded result came out below, above or exactly on the true
    value. Go's `big.Accuracy`.

    ```mojo
    from core.math.big import Above, Below, Exact, new_int

    var x = new_int(1 << 60)
    var f, acc = x.float64()
    print(acc == Exact)                  # True
    ```

    The direction is the direction of the error, so a result rounded up is
    `Above` and one rounded down is `Below`. Go's documentation puts it as the
    sign of `computed - exact`, and that is exactly what the wrapped number is:
    `-1`, `0` or `+1`.
    """

    var value: Int8
    """The sign of the error, one of `-1`, `0` and `+1`."""

    def __init__(out self, value: Int8):
        """Wrap a sign. The three that mean anything are `Below`, `Exact` and
        `Above`."""
        self.value = value

    def __eq__(self, other: Self) -> Bool:
        """Whether these say the same thing about a result."""
        return self.value == other.value

    def __ne__(self, other: Self) -> Bool:
        """Whether these say different things about a result."""
        return self.value != other.value

    def string(self) -> String:
        """Go's name for this accuracy. Go's `Accuracy.String`.

        An accuracy outside the three gets Go's format, which is the type name
        and the number in parentheses.
        """
        if self.value == -1:
            return String("Below")
        if self.value == 0:
            return String("Exact")
        if self.value == 1:
            return String("Above")
        return String("Accuracy(", self.value, ")")

    def write_to[W: Writer](self, mut writer: W):
        """The name, so that printing an accuracy reads like Go's."""
        writer.write(self.string())


comptime Below = Accuracy(-1)
"""The result is smaller than the true value. Go's `big.Below`."""

comptime Exact = Accuracy(0)
"""The result is the true value. Go's `big.Exact`."""

comptime Above = Accuracy(1)
"""The result is larger than the true value. Go's `big.Above`."""


struct RoundingMode(Copyable, Equatable, ImplicitlyCopyable, Movable, Writable):
    """Which way a result that does not fit is rounded. Go's
    `big.RoundingMode`.

    ```mojo
    from core.math.big import ToNearestEven, ToZero

    print(ToNearestEven.string())         # ToNearestEven
    print(ToZero.string())                # ToZero
    ```

    Six modes, and the numbering is Go's, so a value written down by a Go
    program means the same thing here. `ToNearestEven` is the mode every IEEE
    754 operation uses and the one a `Float` starts with.
    """

    var value: UInt8
    """Go's `iota`, from zero for `ToNearestEven` to five for `ToPositiveInf`.
    """

    def __init__(out self, value: UInt8):
        """Wrap a number. The six that mean anything are the constants below."""
        self.value = value

    def __eq__(self, other: Self) -> Bool:
        """Whether these are the same mode."""
        return self.value == other.value

    def __ne__(self, other: Self) -> Bool:
        """Whether these are different modes."""
        return self.value != other.value

    def string(self) -> String:
        """Go's name for this mode. Go's `RoundingMode.String`.

        A mode outside the six gets Go's format, which is the type name and the
        number in parentheses.
        """
        if self.value == 0:
            return String("ToNearestEven")
        if self.value == 1:
            return String("ToNearestAway")
        if self.value == 2:
            return String("ToZero")
        if self.value == 3:
            return String("AwayFromZero")
        if self.value == 4:
            return String("ToNegativeInf")
        if self.value == 5:
            return String("ToPositiveInf")
        return String("RoundingMode(", self.value, ")")

    def write_to[W: Writer](self, mut writer: W):
        """The name, so that printing a mode reads like Go's."""
        writer.write(self.string())


comptime ToNearestEven = RoundingMode(0)
"""To the nearest value, and to the even one of a tie. Go's `ToNearestEven`."""

comptime ToNearestAway = RoundingMode(1)
"""To the nearest value, and away from zero on a tie. Go's `ToNearestAway`."""

comptime ToZero = RoundingMode(2)
"""Towards zero. Go's `ToZero`."""

comptime AwayFromZero = RoundingMode(3)
"""Away from zero. Go's `AwayFromZero`."""

comptime ToNegativeInf = RoundingMode(4)
"""Towards negative infinity. Go's `ToNegativeInf`."""

comptime ToPositiveInf = RoundingMode(5)
"""Towards positive infinity. Go's `ToPositiveInf`."""
