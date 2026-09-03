"""Building a new byte slice out of an old one. Go's clone, repeat, replace,
map, runes and to-valid tables.

Everything here allocates and everything here returns owned bytes, so these
tests are about the contents and about the two failures Go says are panics and
this library says are raises: a negative repeat count and a length that
overflows.

`clone` gets one check Go writes with `unsafe.SliceData` and cannot be written
that way here: the copy is written into and the original is checked afterwards.
That is the same property — the result does not reference the input's memory —
stated in terms a safe language can observe.
"""

from std.testing import assert_equal, assert_raises, assert_true

from core.bytes import (
    clone,
    equal,
    join,
    map,
    repeat,
    replace,
    replace_all,
    runes,
    to_valid_utf8,
)
from core.io import Byte
from core.unicode import MAX_RUNE
from core.unicode.utf8 import append_rune

from tests.bytes._fixtures import enc, expect, quote


def test_clone_copies() raises:
    """Go's `TestClone`, minus the nil rows: an empty input clones to empty."""
    var cases = List[String]()
    cases.append("")
    cases.append("short")
    cases.append("a\\xffb")
    for row in cases:
        var b = enc(row)
        var copied = clone(Span(b))
        assert_equal(quote(Span(copied)), expect(row))


def test_clone_does_not_alias_its_argument() raises:
    """Go checks this with `unsafe.SliceData`; here the copy is written into.

    This is the whole reason the function exists. A span into someone else's
    bytes stops being usable when they are dropped, and `clone` is how a caller
    gets bytes of their own out of a borrowed view.
    """
    var b = enc("aaaa")
    var copied = clone(Span(b))
    copied[0] = Byte(ord("z"))
    assert_equal(quote(Span(b)), expect("aaaa"))
    assert_equal(quote(Span(copied)), expect("zaaa"))


def test_join() raises:
    """Not one of Go's tables — Go tests `Join` through the split round trip,
    which `test_split.mojo` does too. These are the three edges that round trip
    does not reach: no pieces, one piece, and a separator longer than anything
    it goes between.
    """
    var sep = enc(", ")
    # The empty list is given an origin of its own rather than the separator's:
    # a list of spans into `sep` and `sep` itself cannot both be handed to one
    # call, even when the list is empty and nothing is borrowed at run time.
    var elsewhere = List[Byte]()
    var none = List[Span[Byte, origin_of(elsewhere)].Immutable]()
    var nothing = join(none, Span(sep))
    assert_equal(len(nothing), 0)

    var one = enc("solo")
    var single = List[Span[Byte, origin_of(one)].Immutable]()
    single.append(Span(one).as_imm())
    var alone = join(single, Span(sep))
    assert_equal(quote(Span(alone)), expect("solo"))

    var a = enc("a")
    var pieces = List[Span[Byte, origin_of(a)].Immutable]()
    pieces.append(Span(a).as_imm())
    pieces.append(Span(a).as_imm())
    pieces.append(Span(a).as_imm())
    var wide = enc("<--->")
    var run = join(pieces, Span(wide))
    assert_equal(quote(Span(run)), expect("a<--->a<--->a"))


@fieldwise_init
struct RepeatCase(Copyable, Movable):
    """Go's `RepeatTest`."""

    var input: String
    var want: String
    var count: Int


def test_repeat() raises:
    """Go's `RepeatTests`, the short rows.

    The two long rows are in `test_repeat_over_the_chunk_limit` below, because
    they are what makes the doubling copy worth having and they are the only
    slow thing in this file.
    """
    var cases = List[RepeatCase]()
    cases.append(RepeatCase("", "", 0))
    cases.append(RepeatCase("", "", 1))
    cases.append(RepeatCase("", "", 2))
    cases.append(RepeatCase("-", "", 0))
    cases.append(RepeatCase("-", "-", 1))
    cases.append(RepeatCase("-", "----------", 10))
    cases.append(RepeatCase("abc ", "abc abc abc ", 3))
    cases.append(RepeatCase("\\xff", "\\xff\\xff\\xff", 3))
    for row in cases:
        var b = enc(row.input)
        var got = repeat(Span(b), row.count)
        assert_equal(quote(Span(got)), expect(row.want))


def test_repeat_over_the_chunk_limit() raises:
    """Go's last two `RepeatTests` rows, which are the ones about the copy.

    `repeat` fills the result by copying what it has already written, doubling
    each time and capped at eight kilobytes so the source stays in cache. Below
    that cap the cap never applies, so a result of 64 kilobytes is the smallest
    input that runs the loop it is there for.
    """
    # slow: two results of about 64 kilobytes each
    var zero = List[Byte]()
    zero.append(Byte(0))
    var many = repeat(Span(zero), 1 << 16)
    assert_equal(len(many), 1 << 16)
    for i in range(len(many)):
        assert_equal(Int(many[i]), 0)

    var long = List[Byte](length=(1 << 16) + 2, fill=0)
    long[0] = Byte(ord("a"))
    long[len(long) - 1] = Byte(ord("z"))
    var twice = repeat(Span(long), 2)
    assert_equal(len(twice), 2 * len(long))
    assert_true(equal(Span(twice)[0 : len(long)], Span(long)))
    assert_true(equal(Span(twice)[len(long) : len(twice)], Span(long)))


def test_repeat_refuses_a_negative_count() raises:
    """Go panics here. This raises, which is the library's rule: nothing aborts
    for something the caller could have checked."""
    var b = enc("-")
    with assert_raises(contains="negative repeat count"):
        _ = repeat(Span(b), -1)


def test_repeat_refuses_a_length_that_overflows() raises:
    """Go's `TestRepeatCatchesOverflow`, as a raise rather than a panic.

    The count is not absurd on its own and the input is four bytes; it is the
    product that does not fit, which is exactly the case a length check written
    as `total < 0` misses on some inputs and the division catches on all of
    them.
    """
    var b = enc("abcd")
    with assert_raises(contains="overflow"):
        _ = repeat(Span(b), (1 << 62) + 1)


@fieldwise_init
struct ReplaceCase(Copyable, Movable):
    """Go's `ReplaceTest`."""

    var input: String
    var old: String
    var new: String
    var n: Int
    var want: String


def replace_cases() -> List[ReplaceCase]:
    """Go's `ReplaceTests`.

    The block in the middle is the empty `old`, which inserts before every rune
    and once after the last, so six insertions into `banana` and not seven. The
    rows that limit it to 6, 5 and 1 are the ones that pin where the count runs
    out, and the last row is the same rule over runes that are three bytes
    wide.
    """
    var out = List[ReplaceCase]()
    out.append(ReplaceCase("hello", "l", "L", 0, "hello"))
    out.append(ReplaceCase("hello", "l", "L", -1, "heLLo"))
    out.append(ReplaceCase("hello", "x", "X", -1, "hello"))
    out.append(ReplaceCase("", "x", "X", -1, ""))
    out.append(ReplaceCase("radar", "r", "<r>", -1, "<r>ada<r>"))
    out.append(ReplaceCase("", "", "<>", -1, "<>"))
    out.append(ReplaceCase("banana", "a", "<>", -1, "b<>n<>n<>"))
    out.append(ReplaceCase("banana", "a", "<>", 1, "b<>nana"))
    out.append(ReplaceCase("banana", "a", "<>", 1000, "b<>n<>n<>"))
    out.append(ReplaceCase("banana", "an", "<>", -1, "b<><>a"))
    out.append(ReplaceCase("banana", "ana", "<>", -1, "b<>na"))
    out.append(ReplaceCase("banana", "", "<>", -1, "<>b<>a<>n<>a<>n<>a<>"))
    out.append(ReplaceCase("banana", "", "<>", 10, "<>b<>a<>n<>a<>n<>a<>"))
    out.append(ReplaceCase("banana", "", "<>", 6, "<>b<>a<>n<>a<>n<>a"))
    out.append(ReplaceCase("banana", "", "<>", 5, "<>b<>a<>n<>a<>na"))
    out.append(ReplaceCase("banana", "", "<>", 1, "<>banana"))
    out.append(ReplaceCase("banana", "a", "a", -1, "banana"))
    out.append(ReplaceCase("banana", "a", "a", 1, "banana"))
    out.append(ReplaceCase("☺☻☹", "", "<>", -1, "<>☺<>☻<>☹<>"))
    return out^


def test_replace() raises:
    """Go's `TestReplace`."""
    var cases = replace_cases()
    for row in cases:
        var s = enc(row.input)
        var old = enc(row.old)
        var new = enc(row.new)
        var got = replace(Span(s), Span(old), Span(new), row.n)
        assert_equal(quote(Span(got)), expect(row.want))


def test_replace_all_is_replace_with_no_limit() raises:
    """Go's `TestReplaceAll` over the same table."""
    var cases = replace_cases()
    for row in cases:
        if row.n != -1:
            continue
        var s = enc(row.input)
        var old = enc(row.old)
        var new = enc(row.new)
        var got = replace_all(Span(s), Span(old), Span(new))
        assert_equal(quote(Span(got)), expect(row.want))


def test_replace_does_not_touch_its_argument() raises:
    """Go appends `<spare>` to the input and checks it after; the point is that
    `replace` never writes through the span it was given, which here is a type
    error to attempt and is worth one check anyway because the input can be
    reached again through the same list."""
    var s = enc("banana")
    var old = enc("a")
    var new = enc("<>")
    var got = replace(Span(s), Span(old), Span(new), -1)
    assert_equal(quote(Span(s)), expect("banana"))
    assert_equal(quote(Span(got)), expect("b<>n<>n<>"))


def _ten(r: Int32) raises -> List[Byte]:
    """Ten copies of one rune, encoded. Go's `tenRunes`."""
    var out = List[Byte]()
    for _ in range(10):
        _ = append_rune(out, r)
    return out^


def test_map_grows() raises:
    """Go's `TestMap` step 1: ten one byte runes become ten four byte ones."""

    @parameter
    def biggest(r: Int32) -> Int32:
        return MAX_RUNE

    var a = enc("aaaaaaaaaa")
    var got = map[biggest](Span(a))
    var want = _ten(MAX_RUNE)
    assert_equal(quote(Span(got)), quote(Span(want)))


def test_map_shrinks() raises:
    """Go's `TestMap` step 2, the same thing the other way."""

    @parameter
    def smallest(r: Int32) -> Int32:
        return Int32(ord("a"))

    var big = _ten(MAX_RUNE)
    var got = map[smallest](Span(big))
    assert_equal(quote(Span(got)), expect("aaaaaaaaaa"))


def _rot13(r: Int32) -> Int32:
    """Go's `rot13`. Letters move thirteen places and nothing else moves."""
    if r >= Int32(ord("a")) and r <= Int32(ord("z")):
        return Int32(ord("a")) + (r - Int32(ord("a")) + 13) % 26
    if r >= Int32(ord("A")) and r <= Int32(ord("Z")):
        return Int32(ord("A")) + (r - Int32(ord("A")) + 13) % 26
    return r


def test_map_rot13_and_back() raises:
    """Go's `TestMap` steps 3 and 4. Applying it twice is the identity, which
    is a property no table row can state."""

    @parameter
    def rot(r: Int32) -> Int32:
        return _rot13(r)

    var s = enc("a to zed")
    var once = map[rot](Span(s))
    assert_equal(quote(Span(once)), expect("n gb mrq"))
    var twice = map[rot](Span(once))
    assert_equal(quote(Span(twice)), expect("a to zed"))


def test_map_drops_a_rune_it_maps_to_negative() raises:
    """Go's `TestMap` step 5.

    Go's predicate keeps `unicode.Latin` and this one keeps ASCII letters,
    because the script tables are not in `core.unicode` and the step is about
    dropping rather than about which script. `Hello, 세계` loses the comma, the
    space and both Hangul syllables, and the result is shorter than the input
    by more than the runes removed, since two of them were three bytes each.
    """

    @parameter
    def ascii_letters(r: Int32) -> Int32:
        if r >= Int32(ord("a")) and r <= Int32(ord("z")):
            return r
        if r >= Int32(ord("A")) and r <= Int32(ord("Z")):
            return r
        return -1

    var s = enc("Hello, 세계")
    var got = map[ascii_letters](Span(s))
    assert_equal(quote(Span(got)), expect("Hello"))


def test_map_writes_the_replacement_for_a_rune_that_is_not_one() raises:
    """Go's `TestMap` step 6: a mapping to `MAX_RUNE + 1` encodes as U+FFFD.

    The result of `map` is always valid UTF-8, whatever the function returns
    and whatever went in, because encoding is where the check happens and there
    is nowhere else it could be done.
    """

    @parameter
    def too_big(r: Int32) -> Int32:
        return MAX_RUNE + 1

    var s = enc("x")
    var got = map[too_big](Span(s))
    assert_equal(quote(Span(got)), expect("\\xef\\xbf\\xbd"))


def test_map_sees_invalid_input_as_the_replacement_rune() raises:
    """Not a Go step, but the other half of the same rule: bad bytes decode to
    U+FFFD one byte at a time, so a mapping that passes everything through
    turns two bad bytes into two replacement characters."""

    @parameter
    def same(r: Int32) -> Int32:
        return r

    var s = enc("a\\xff\\xffb")
    var got = map[same](Span(s))
    assert_equal(quote(Span(got)), expect("a\\xef\\xbf\\xbd\\xef\\xbf\\xbdb"))


@fieldwise_init
struct RunesCase(Copyable, Movable):
    """Go's `RunesTest`. `lossy` marks the rows that cannot be reassembled."""

    var input: String
    var want: String
    """The code points as decimal numbers with a comma between them."""

    var lossy: Bool


def test_runes() raises:
    """Go's `TestRunes`, including its round trip for the rows that survive it.
    """
    var cases = List[RunesCase]()
    cases.append(RunesCase("", "", False))
    cases.append(RunesCase(" ", "32", False))
    cases.append(RunesCase("ABC", "65,66,67", False))
    cases.append(RunesCase("abc", "97,98,99", False))
    cases.append(RunesCase("日本語", "26085,26412,35486", False))
    cases.append(RunesCase("ab\\x80c", "97,98,65533,99", True))
    cases.append(RunesCase("ab\\xc0c", "97,98,65533,99", True))
    for row in cases:
        var b = enc(row.input)
        var got = runes(Span(b))
        var printed = String("")
        for i in range(len(got)):
            if i > 0:
                printed += ","
            printed += String(Int(got[i]))
        assert_equal(printed, row.want)

        if not row.lossy:
            var back = List[Byte]()
            for i in range(len(got)):
                _ = append_rune(back, got[i])
            assert_equal(quote(Span(back)), expect(row.input))


@fieldwise_init
struct ValidCase(Copyable, Movable):
    """Go's `toValidUTF8Tests`."""

    var input: String
    var repl: String
    var want: String


def test_to_valid_utf8() raises:
    """Go's `TestToValidUTF8`.

    A run of bad bytes becomes one replacement and not one per byte, which is
    the difference between this and decoding through `map`: the overlong
    five and six byte sequences at the end are five and six bad bytes and one
    replacement each. The surrogate row replaces with `abc` to show the
    replacement is arbitrary bytes rather than a rune.
    """
    var cases = List[ValidCase]()
    cases.append(ValidCase("", "\\xef\\xbf\\xbd", ""))
    cases.append(ValidCase("abc", "\\xef\\xbf\\xbd", "abc"))
    cases.append(
        ValidCase("\\xef\\xb7\\x9d", "\\xef\\xbf\\xbd", "\\xef\\xb7\\x9d")
    )
    cases.append(ValidCase("a\\xffb", "\\xef\\xbf\\xbd", "a\\xef\\xbf\\xbdb"))
    cases.append(ValidCase("a\\xffb\\xef\\xbf\\xbd", "X", "aXb\\xef\\xbf\\xbd"))
    cases.append(
        ValidCase(
            "a☺\\xffb☺\\xc0\\xafc☺\\xff",
            "",
            "a☺b☺c☺",
        )
    )
    cases.append(
        ValidCase(
            "a☺\\xffb☺\\xc0\\xafc☺\\xff",
            "日本語",
            "a☺日本語b☺日本語c☺日本語",
        )
    )
    cases.append(ValidCase("\\xc0\\xaf", "\\xef\\xbf\\xbd", "\\xef\\xbf\\xbd"))
    cases.append(
        ValidCase("\\xe0\\x80\\xaf", "\\xef\\xbf\\xbd", "\\xef\\xbf\\xbd")
    )
    cases.append(ValidCase("\\xed\\xa0\\x80", "abc", "abc"))
    cases.append(
        ValidCase("\\xed\\xbf\\xbf", "\\xef\\xbf\\xbd", "\\xef\\xbf\\xbd")
    )
    cases.append(ValidCase("\\xf0\\x80\\x80\\xaf", "☺", "☺"))
    cases.append(
        ValidCase(
            "\\xf8\\x80\\x80\\x80\\xaf", "\\xef\\xbf\\xbd", "\\xef\\xbf\\xbd"
        )
    )
    cases.append(
        ValidCase(
            "\\xfc\\x80\\x80\\x80\\x80\\xaf",
            "\\xef\\xbf\\xbd",
            "\\xef\\xbf\\xbd",
        )
    )
    for row in cases:
        var s = enc(row.input)
        var repl = enc(row.repl)
        var got = to_valid_utf8(Span(s), Span(repl))
        assert_equal(quote(Span(got)), expect(row.want))
