"""Comparing two byte slices. Go's `compare_test.go` and the equality half of
`bytes_test.go`.

Go's table is transcribed and then run at seventeen alignments of the second
argument, which is what its own `TestCompare` does. That loop exists because a
comparison written a word at a time is right on aligned input and wrong on
unaligned input, and the naive loop this library has today passes either way.
Keeping it means the day somebody makes `equal` fast, the test is already
there.

The exhaustive pair is Go's too: every length and every pair of offsets inside
a 128 byte window, once for equal windows and once with a single bit set. That
is 128 cubed at its widest and it is the case that catches a comparison which
stops one byte early.
"""

from std.testing import assert_equal, assert_false, assert_true

from core.bytes import compare, equal, equal_fold, has_prefix, has_suffix
from core.io import Byte

from tests.bytes._fixtures import enc


@fieldwise_init
struct Pair(Copyable, Movable):
    """Two slices and the sign `compare` should answer with."""

    var a: String
    var b: String
    var want: Int


def compare_cases() -> List[Pair]:
    """Go's `compareTests`. The nil rows are dropped: an empty list is the only
    empty thing here, so they would be the rows above written twice."""
    var out = List[Pair]()
    out.append(Pair("", "", 0))
    out.append(Pair("a", "", 1))
    out.append(Pair("", "a", -1))
    out.append(Pair("abc", "abc", 0))
    out.append(Pair("abd", "abc", 1))
    out.append(Pair("abc", "abd", -1))
    out.append(Pair("ab", "abc", -1))
    out.append(Pair("abc", "ab", 1))
    out.append(Pair("x", "ab", 1))
    out.append(Pair("ab", "x", -1))
    out.append(Pair("x", "a", 1))
    out.append(Pair("b", "x", -1))
    # Go's rows for the chunked memeq: eight bytes and one more than eight.
    out.append(Pair("abcdefgh", "abcdefgh", 0))
    out.append(Pair("abcdefghi", "abcdefghi", 0))
    out.append(Pair("abcdefghi", "abcdefghj", -1))
    out.append(Pair("abcdefghj", "abcdefghi", 1))
    return out^


def test_compare_at_every_alignment() raises:
    """Go's `TestCompare`, including its shift loop."""
    var cases = compare_cases()
    for row in cases:
        var a = enc(row.a)
        var b = enc(row.b)
        for offset in range(17):
            var window = List[Byte](length=len(b) + 17, fill=0)
            for i in range(len(b)):
                window[offset + i] = b[i]
            var shifted = Span(window)[offset : offset + len(b)]
            assert_equal(compare(Span(a), shifted), row.want)


def test_equal_agrees_with_compare() raises:
    """Go's `TestEqual`, which is the same table read as a Bool."""
    var cases = compare_cases()
    for row in cases:
        var a = enc(row.a)
        var b = enc(row.b)
        assert_equal(equal(Span(a), Span(b)), row.want == 0)


def test_a_slice_equals_itself() raises:
    """Go's `TestCompareIdenticalSlice`, both ways round."""
    var b = enc("Hello Gophers!")
    assert_equal(compare(Span(b).as_imm(), Span(b).as_imm()), 0)
    assert_true(equal(Span(b).as_imm(), Span(b).as_imm()))


def test_equal_windows_are_equal_at_every_offset() raises:
    """Go's `TestEqualExhaustive`.

    Two 128 byte buffers of unrelated data, a window of every length copied
    from one into the other at every pair of offsets, and both directions
    asserted. What it catches is a comparison that reads the length from the
    wrong side or stops a byte early, neither of which shows up on a table of
    short literals.
    """
    # slow: 128 lengths by 128 offsets by 128 offsets
    var size = 128
    var a = List[Byte](length=size, fill=0)
    var seed = List[Byte](length=size, fill=0)
    for i in range(size):
        a[i] = Byte((17 * i) & 0xFF)
        seed[i] = Byte((23 * i + 100) & 0xFF)

    var b = List[Byte](length=size, fill=0)
    for width in range(size + 1):
        for x in range(size - width + 1):
            for y in range(size - width + 1):
                for i in range(size):
                    b[i] = seed[i]
                for i in range(width):
                    b[y + i] = a[x + i]
                var left = Span(a)[x : x + width]
                var right = Span(b)[y : y + width]
                assert_true(equal(left, right))
                assert_true(equal(right, left))


def test_one_differing_byte_is_not_equal() raises:
    """Go's `TestNotEqual`. Zeros everywhere but one position, every window."""
    # slow: the same three nested loops with a fourth inside them
    var size = 64
    var a = List[Byte](length=size, fill=0)
    var b = List[Byte](length=size, fill=0)
    for width in range(1, size + 1):
        for x in range(size - width + 1):
            for y in range(size - width + 1):
                for at in range(x, x + width):
                    a[at] = Byte(1)
                    var left = Span(a)[x : x + width]
                    var right = Span(b)[y : y + width]
                    assert_false(equal(left, right))
                    assert_false(equal(right, left))
                    a[at] = Byte(0)


def test_has_prefix_and_has_suffix() raises:
    """Not a Go table: Go tests these through `TrimPrefix` and `TrimSuffix`.

    They are two of the four functions everything else in the package is built
    out of, so they get their own cases, including the two that are easy to get
    backwards: an empty affix is present, and an affix longer than the slice is
    not.
    """
    var s = enc("abcdef")
    assert_true(has_prefix(Span(s), Span(enc("abc"))))
    assert_true(has_prefix(Span(s), Span(enc(""))))
    assert_true(has_prefix(Span(s).as_imm(), Span(s).as_imm()))
    assert_false(has_prefix(Span(s), Span(enc("abd"))))
    assert_false(has_prefix(Span(s), Span(enc("abcdefg"))))
    assert_true(has_suffix(Span(s), Span(enc("def"))))
    assert_true(has_suffix(Span(s), Span(enc(""))))
    assert_true(has_suffix(Span(s).as_imm(), Span(s).as_imm()))
    assert_false(has_suffix(Span(s), Span(enc("bef"))))
    assert_false(has_suffix(Span(s), Span(enc("aabcdef"))))


@fieldwise_init
struct FoldPair(Copyable, Movable):
    """Two slices and whether they are equal under simple folding."""

    var a: String
    var b: String
    var want: Bool


def test_equal_fold() raises:
    """Go's `TestEqualFold`, run in both directions as Go does.

    The rows that matter are the last four. U+212A KELVIN SIGN folds to `k`,
    so `k` and it are equal and a one byte comparison of case-mapped bytes is
    not enough; and the two rows after that are the same pair with a trailing
    character that differs, which catches a fold that stopped at the first
    multibyte rune.
    """
    var cases = List[FoldPair]()
    cases.append(FoldPair("abc", "abc", True))
    cases.append(FoldPair("ABcd", "ABcd", True))
    cases.append(FoldPair("123abc", "123ABC", True))
    cases.append(FoldPair("αβδ", "ΑΒΔ", True))
    cases.append(FoldPair("abc", "xyz", False))
    cases.append(FoldPair("abc", "XYZ", False))
    cases.append(FoldPair("abcdefghijk", "abcdefghijX", False))
    cases.append(FoldPair("abcdefghijk", "abcdefghijK", True))
    cases.append(FoldPair("abcdefghijK", "abcdefghijK", True))
    cases.append(FoldPair("abcdefghijkz", "abcdefghijKy", False))
    cases.append(FoldPair("abcdefghijKz", "abcdefghijKy", False))
    for row in cases:
        var a = enc(row.a)
        var b = enc(row.b)
        assert_equal(equal_fold(Span(a), Span(b)), row.want)
        assert_equal(equal_fold(Span(b), Span(a)), row.want)
