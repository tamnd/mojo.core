# EXPECT: 4
# EXPECT-TEXT: asks for argument 2 and only 1 argument was passed
# EXPECT-TEXT: uses 1 argument and 2 arguments were passed
# EXPECT-TEXT: ends in a bare %
# EXPECT-TEXT: the * width reads argument 1, whose type is string
# EXPECT-OUTPUT: 1 %!d(MISSING)
# EXPECT-OUTPUT: 1%!(EXTRA int=2)
# EXPECT-OUTPUT: abc %!(NOVERB)
# EXPECT-OUTPUT: %!(BADWIDTH)4
#
# The counting and the parsing, which are the checks a Go programmer would go
# to `go vet` for. Too few arguments, too many, a format that ends in a bare
# percent, and a `*` width reading something that is not a whole number.

from core.fmt import sprintf


def main() raises:
    print(sprintf["%d %d"](1))
    print(sprintf["%d"](1, 2))
    print(sprintf["abc %"]())
    print(sprintf["%*d"]("hi", 4))
