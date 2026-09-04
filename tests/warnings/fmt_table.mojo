# EXPECT: 13
# EXPECT-TEXT: the format "no args" uses 0 arguments and 1 argument was passed
# EXPECT-TEXT: the format "%s %" ends in a bare %
# EXPECT-TEXT: the verb %☠ cannot print argument 1, whose type is int
# EXPECT-TEXT: the verb %. cannot print argument 1, whose type is int
# EXPECT-OUTPUT: %!(EXTRA int=2)
# EXPECT-OUTPUT: no args%!(EXTRA string=hello)
# EXPECT-OUTPUT: hello %!(NOVERB)
# EXPECT-OUTPUT: %!(NOVERB)%!(EXTRA int=0)
# EXPECT-OUTPUT: %!(NOVERB)%!(EXTRA string=12345)
# EXPECT-OUTPUT: %!.(int=3)
# EXPECT-OUTPUT: %!☠(int=0)
# EXPECT-OUTPUT: %!☠(uint=0)
# EXPECT-OUTPUT: %!☠(string=hello)
# EXPECT-OUTPUT: %!☠(float64=1.2345678)
# EXPECT-OUTPUT: %!☠(float32=1.2345678)
#
# The rows of Go's own fmtTests that expect an error marker.
#
# tools/testgen/fmtcases leaves these out of tests/generated/test_fmt.mojo,
# because each one is a format string this library complains about while the
# program is built and the suite build treats a complaint of ours as a failure.
# They are not lost, they are here, where a complaint is what the file is for
# and the marker is checked beside it. The expected text is Go's own, copied
# from the row rather than worked out.
#
# The two long ones are the reason this file is worth having. A width of
# eighteen digits overflows every integer there is, and Go's answer is that the
# verb was never found, so the format ends in a NOVERB and the argument is
# extra. A parser that wrapped around instead would produce a plausible width
# and print something, and nothing else here would notice.
#
# `%☠` is the other one. The verb is a rune rather than a byte, so a parser
# that read one byte would split it and report the first half of it, and the
# marker names the type the same way for a rune verb as for an ASCII one.
#
# The rows left behind from Go's fourteen are the three `%p` ones, which is a
# verb waived in docs/deviations.md, and the ones whose value is a nil, a
# complex number, a pointer, a channel or a func, none of which this library
# has anything to hand.

from core.fmt import sprintf


def main() raises:
    print(sprintf[""](2))
    print(sprintf["no args"](String("hello")))
    print(sprintf["%s %"](String("hello")))
    print(sprintf["%017091901790959340919092959340919017929593813360"](0))
    print(sprintf["%010.2"](String("12345")))
    print(sprintf["%."](3))
    print(sprintf["%☠"](Int(0)))
    print(sprintf["%☠"](UInt(0)))
    print(sprintf["%☠"](String("hello")))
    print(sprintf["%☠"](1.2345678))
    print(sprintf["%☠"](Float32(1.2345678)))
