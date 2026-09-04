# EXPECT: 2
# EXPECT-TEXT: the verb %d cannot print argument 1, whose type is string
# EXPECT-TEXT: the verb %t cannot print argument 2, whose type is float64
# EXPECT-OUTPUT: %!d(string=hi)
# EXPECT-OUTPUT: fine %!t(float64=1.5)
# EXPECT-OUTPUT: 1 two true
#
# A verb that cannot print the argument beside it. Both of these compile, and
# both print Go's marker when they run. Both halves are asserted here: that the
# mistake was named while the program was built, and that the marker the
# program then prints is the one Go prints, byte for byte.
#
# The correct calls are here on purpose. A check that fires on everything is
# not a check, and this is the file that would notice.

from core.fmt import sprintf


def main() raises:
    print(sprintf["%d"]("hi"))
    print(sprintf["%s %t"]("fine", 1.5))
    print(sprintf["%d %s %v"](1, "two", True))
