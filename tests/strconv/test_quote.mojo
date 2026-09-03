"""Quoting and unquoting. Go's `quote_test.go`.

Go's tables are written with literals like `` `"\a\b"` ``, a backquoted string
holding the characters backslash and `a`. Mojo has no backquoted literal, so
every expectation here is built by concatenation from `DQ` and `SQ` and
doubled backslashes, which is uglier to write and identical to read.

Two of Go's rows cannot be written at all: the ones whose input holds a byte
that is not valid UTF-8. A Mojo `String` cannot carry one, so those go through
`quote_bytes` instead, which is why that function exists.
"""

from std.testing import assert_equal, assert_false, assert_raises, assert_true

from core.strconv import (
    append_quote,
    append_quote_rune,
    append_quote_rune_to_ascii,
    append_quote_rune_to_graphic,
    append_quote_to_ascii,
    append_quote_to_graphic,
    can_backquote,
    is_graphic,
    is_print,
    quote,
    quote_bytes,
    quote_rune,
    quote_rune_to_ascii,
    quote_rune_to_graphic,
    quote_to_ascii,
    quote_to_graphic,
    quoted_prefix,
    unquote,
    unquote_bytes,
    unquote_char,
)

comptime DQ = '"'
comptime SQ = "'"


struct Case(Copyable, Movable):
    """One row of Go's `quotetests`: the input and the three quotings."""

    var input: String
    var plain: String
    var ascii: String
    var graphic: String

    def __init__(
        out self,
        var input: String,
        var plain: String,
        var ascii: String,
        var graphic: String,
    ):
        self.input = input^
        self.plain = plain^
        self.ascii = ascii^
        self.graphic = graphic^


def quote_cases() -> List[Case]:
    """Go's `quotetests`, minus the row with a byte that is not UTF-8."""
    var cases = List[Case]()
    var controls = (
        chr(7) + chr(8) + chr(12) + chr(13) + chr(10) + chr(9) + chr(11)
    )
    var escaped = DQ + "\\a\\b\\f\\r\\n\\t\\v" + DQ
    cases.append(Case(controls, escaped, escaped, escaped))
    cases.append(
        Case("\\", DQ + "\\\\" + DQ, DQ + "\\\\" + DQ, DQ + "\\\\" + DQ)
    )
    cases.append(
        Case(
            chr(0x263A),
            DQ + chr(0x263A) + DQ,
            DQ + "\\u263a" + DQ,
            DQ + chr(0x263A) + DQ,
        )
    )
    cases.append(
        Case(
            chr(0x10FFFF),
            DQ + "\\U0010ffff" + DQ,
            DQ + "\\U0010ffff" + DQ,
            DQ + "\\U0010ffff" + DQ,
        )
    )
    cases.append(
        Case(chr(4), DQ + "\\x04" + DQ, DQ + "\\x04" + DQ, DQ + "\\x04" + DQ)
    )
    # Not printable, but graphic: three spaces that survive `quote_to_graphic`
    # and are escaped by the other two.
    var spaces = "!" + chr(0xA0) + "!" + chr(0x2000) + "!" + chr(0x3000) + "!"
    cases.append(
        Case(
            spaces,
            DQ + "!\\u00a0!\\u2000!\\u3000!" + DQ,
            DQ + "!\\u00a0!\\u2000!\\u3000!" + DQ,
            DQ + spaces + DQ,
        )
    )
    cases.append(
        Case(chr(0x7F), DQ + "\\x7f" + DQ, DQ + "\\x7f" + DQ, DQ + "\\x7f" + DQ)
    )
    return cases^


def test_quote() raises:
    """Go's `TestQuote`, with the append form checked against the same row."""
    for row in quote_cases():
        assert_equal(quote(row.input), row.plain)
        var dst = List[UInt8]()
        for byte in "abc".as_bytes():
            dst.append(byte)
        var n = append_quote(dst, row.input)
        assert_equal(n, row.plain.byte_length())
        assert_equal(String(from_utf8_lossy=Span(dst)), "abc" + row.plain)


def test_quote_to_ascii() raises:
    """Go's `TestQuoteToASCII`."""
    for row in quote_cases():
        assert_equal(quote_to_ascii(row.input), row.ascii)
        var dst = List[UInt8]()
        _ = append_quote_to_ascii(dst, row.input)
        assert_equal(String(from_utf8_lossy=Span(dst)), row.ascii)


def test_quote_to_graphic() raises:
    """Go's `TestQuoteToGraphic`. The three spaces are the whole point."""
    for row in quote_cases():
        assert_equal(quote_to_graphic(row.input), row.graphic)
        var dst = List[UInt8]()
        _ = append_quote_to_graphic(dst, row.input)
        assert_equal(String(from_utf8_lossy=Span(dst)), row.graphic)


def test_quoting_bytes_that_are_not_text() raises:
    """Go's `abc\\xffdef` row, which needs the byte entry point here.

    Go writes it as a `string` because a Go string is bytes. A `StringSlice`
    cannot hold that byte, so the row goes through `quote_bytes`, and this is
    the test that keeps the `\\xNN` branch alive.
    """
    var raw = List[UInt8]()
    for byte in "abc".as_bytes():
        raw.append(byte)
    raw.append(0xFF)
    for byte in "def".as_bytes():
        raw.append(byte)
    assert_equal(quote_bytes(Span(raw)), DQ + "abc\\xffdef" + DQ)


def rune_cases() -> List[Case]:
    """Go's `quoterunetests`, with the rune written into the input field."""
    var cases = List[Case]()

    def row(r: Int32, plain: String, ascii: String, graphic: String) -> Case:
        return Case(String(Int(r)), plain, ascii, graphic)

    cases.append(
        row(Int32(ord("a")), SQ + "a" + SQ, SQ + "a" + SQ, SQ + "a" + SQ)
    )
    cases.append(
        row(Int32(7), SQ + "\\a" + SQ, SQ + "\\a" + SQ, SQ + "\\a" + SQ)
    )
    cases.append(
        row(
            Int32(ord("\\")),
            SQ + "\\\\" + SQ,
            SQ + "\\\\" + SQ,
            SQ + "\\\\" + SQ,
        )
    )
    cases.append(
        row(
            Int32(0xFF),
            SQ + chr(0xFF) + SQ,
            SQ + "\\u00ff" + SQ,
            SQ + chr(0xFF) + SQ,
        )
    )
    cases.append(
        row(
            Int32(0x263A),
            SQ + chr(0x263A) + SQ,
            SQ + "\\u263a" + SQ,
            SQ + chr(0x263A) + SQ,
        )
    )
    # A surrogate, the replacement character itself, and a code point past the
    # end of the space all come out as U+FFFD.
    cases.append(
        row(
            Int32(0xDEAD),
            SQ + chr(0xFFFD) + SQ,
            SQ + "\\ufffd" + SQ,
            SQ + chr(0xFFFD) + SQ,
        )
    )
    cases.append(
        row(
            Int32(0xFFFD),
            SQ + chr(0xFFFD) + SQ,
            SQ + "\\ufffd" + SQ,
            SQ + chr(0xFFFD) + SQ,
        )
    )
    cases.append(
        row(
            Int32(0x10FFFF),
            SQ + "\\U0010ffff" + SQ,
            SQ + "\\U0010ffff" + SQ,
            SQ + "\\U0010ffff" + SQ,
        )
    )
    cases.append(
        row(
            Int32(0x110000),
            SQ + chr(0xFFFD) + SQ,
            SQ + "\\ufffd" + SQ,
            SQ + chr(0xFFFD) + SQ,
        )
    )
    cases.append(
        row(Int32(4), SQ + "\\x04" + SQ, SQ + "\\x04" + SQ, SQ + "\\x04" + SQ)
    )
    cases.append(
        row(
            Int32(0xA0),
            SQ + "\\u00a0" + SQ,
            SQ + "\\u00a0" + SQ,
            SQ + chr(0xA0) + SQ,
        )
    )
    cases.append(
        row(
            Int32(0x2000),
            SQ + "\\u2000" + SQ,
            SQ + "\\u2000" + SQ,
            SQ + chr(0x2000) + SQ,
        )
    )
    cases.append(
        row(
            Int32(0x3000),
            SQ + "\\u3000" + SQ,
            SQ + "\\u3000" + SQ,
            SQ + chr(0x3000) + SQ,
        )
    )
    return cases^


def test_quote_rune() raises:
    """Go's `TestQuoteRune`, `TestQuoteRuneToASCII` and the graphic one."""
    for row in rune_cases():
        var r = Int32(Int(row.input))
        assert_equal(quote_rune(r), row.plain)
        assert_equal(quote_rune_to_ascii(r), row.ascii)
        assert_equal(quote_rune_to_graphic(r), row.graphic)

        var plain = List[UInt8]()
        _ = append_quote_rune(plain, r)
        assert_equal(String(from_utf8_lossy=Span(plain)), row.plain)

        var ascii = List[UInt8]()
        _ = append_quote_rune_to_ascii(ascii, r)
        assert_equal(String(from_utf8_lossy=Span(ascii)), row.ascii)

        var graphic = List[UInt8]()
        _ = append_quote_rune_to_graphic(graphic, r)
        assert_equal(String(from_utf8_lossy=Span(graphic)), row.graphic)


def test_can_backquote() raises:
    """Go's `canbackquotetests`. Tab is the only control that survives."""
    assert_false(can_backquote("`"))
    for i in range(0, 32):
        assert_equal(can_backquote(chr(i)), i == 9)
    assert_false(can_backquote(chr(0x7F)))
    assert_true(
        can_backquote(SQ + " !" + DQ + "#$%&'()*+,-./:;<=>?@[\\]^_{|}~")
    )
    assert_true(can_backquote("0123456789"))
    assert_true(can_backquote("ABCDEFGHIJKLMNOPQRSTUVWXYZ"))
    assert_true(can_backquote("abcdefghijklmnopqrstuvwxyz"))
    assert_true(can_backquote(chr(0x263A)))


def test_the_byte_order_mark_cannot_be_backquoted() raises:
    """Go refuses it because it is invisible, not because it is not printable.

    A literal that reads as `abc` and is not `abc` is exactly the failure the
    rule exists to prevent.
    """
    assert_false(can_backquote(chr(0xFEFF) + "abc"))
    assert_false(can_backquote("a" + chr(0xFEFF) + "z"))


def test_unquote() raises:
    """Go's `unquotetests`, minus the rows whose value is not valid UTF-8."""
    assert_equal(unquote(DQ + DQ), "")
    assert_equal(unquote(DQ + "a" + DQ), "a")
    assert_equal(unquote(DQ + "abc" + DQ), "abc")
    assert_equal(unquote(DQ + chr(0x263A) + DQ), chr(0x263A))
    assert_equal(unquote(DQ + "hello world" + DQ), "hello world")
    assert_equal(unquote(DQ + "\\u1234" + DQ), chr(0x1234))
    assert_equal(unquote(DQ + "\\U00010111" + DQ), chr(0x10111))
    assert_equal(unquote(DQ + "\\U0001011111" + DQ), chr(0x10111) + "11")
    assert_equal(
        unquote(DQ + "\\a\\b\\f\\n\\r\\t\\v\\\\\\" + DQ + DQ),
        chr(7)
        + chr(8)
        + chr(12)
        + chr(10)
        + chr(13)
        + chr(9)
        + chr(11)
        + "\\"
        + DQ,
    )
    assert_equal(unquote(DQ + SQ + DQ), SQ)

    assert_equal(unquote(SQ + "a" + SQ), "a")
    assert_equal(unquote(SQ + chr(0x2639) + SQ), chr(0x2639))
    assert_equal(unquote(SQ + "\\a" + SQ), chr(7))
    assert_equal(unquote(SQ + "\\x10" + SQ), chr(0x10))
    assert_equal(unquote(SQ + "\\u1234" + SQ), chr(0x1234))
    assert_equal(unquote(SQ + "\\U00010111" + SQ), chr(0x10111))
    assert_equal(unquote(SQ + "\\t" + SQ), chr(9))
    assert_equal(unquote(SQ + " " + SQ), " ")
    assert_equal(unquote(SQ + "\\" + SQ + SQ), SQ)
    assert_equal(unquote(SQ + DQ + SQ), DQ)


def test_unquote_raw() raises:
    """The backquoted rows. A carriage return inside one is dropped."""
    assert_equal(unquote("``"), "")
    assert_equal(unquote("`a`"), "a")
    assert_equal(unquote("`abc`"), "abc")
    assert_equal(unquote("`" + chr(0x263A) + "`"), chr(0x263A))
    assert_equal(unquote("`hello world`"), "hello world")
    assert_equal(unquote("`\\xFF`"), "\\xFF")
    assert_equal(unquote("`\\377`"), "\\377")
    assert_equal(unquote("`\\`"), "\\")
    assert_equal(unquote("`" + chr(10) + "`"), chr(10))
    assert_equal(unquote("`" + chr(9) + "`"), chr(9))
    assert_equal(unquote("` `"), " ")
    assert_equal(unquote("`a" + chr(13) + "b`"), "ab")


def test_unquote_round_trips_the_quoting_table() raises:
    """Go runs `quotetests` backwards through `Unquote`, and so does this."""
    for row in quote_cases():
        assert_equal(unquote(row.plain), row.input)


def test_a_literal_whose_value_is_not_text() raises:
    """`"\\xff"` is a legal Go literal and its value is one byte.

    Go hands that back as a `string`, which can hold it. `unquote` raises and
    `unquote_bytes` answers, which is this library's rule about bytes that are
    not text, applied to one more place.
    """
    with assert_raises():
        _ = unquote(DQ + "\\xFF" + DQ)
    var value = unquote_bytes(DQ + "\\xFF" + DQ)
    assert_equal(len(value), 1)
    assert_equal(Int(value[0]), 255)

    var octal = unquote_bytes(DQ + "\\377" + DQ)
    assert_equal(len(octal), 1)
    assert_equal(Int(octal[0]), 255)


def misquoted() -> List[String]:
    """Go's `misquoted`, every one of which is a syntax error."""
    var out = List[String]()
    out.append("")
    out.append(DQ)
    out.append(DQ + "a")
    out.append(DQ + SQ)
    out.append("b" + DQ)
    out.append(DQ + "\\" + DQ)
    out.append(DQ + "\\9" + DQ)
    out.append(DQ + "\\19" + DQ)
    out.append(DQ + "\\129" + DQ)
    out.append(SQ + "\\" + SQ)
    out.append(SQ + "\\9" + SQ)
    out.append(SQ + "\\19" + SQ)
    out.append(SQ + "\\129" + SQ)
    out.append(SQ + "ab" + SQ)
    out.append(DQ + "\\x1!" + DQ)
    out.append(DQ + "\\U12345678" + DQ)
    out.append(DQ + "\\z" + DQ)
    out.append("`")
    out.append("`xxx")
    out.append("``x" + chr(13))
    out.append("`" + DQ)
    out.append(DQ + "\\" + SQ + DQ)
    out.append(SQ + "\\" + DQ + SQ)
    out.append(DQ + chr(10) + DQ)
    out.append(DQ + "\\n" + chr(10) + DQ)
    out.append(SQ + chr(10) + SQ)
    out.append(DQ + "\\udead" + DQ)
    out.append(DQ + "\\ud83d\\ude4f" + DQ)
    return out^


def test_misquoted() raises:
    """Every row raises, and none of them aborts."""
    for bad in misquoted():
        with assert_raises():
            _ = unquote(bad)


def test_quoted_prefix() raises:
    """Go's `QuotedPrefix`, which stops at the end of the literal.

    The suffix is Go's: the characters most likely to end a literal early if
    the scan were wrong.
    """
    var suffix = chr(10) + chr(13) + "\\" + DQ + "`" + SQ
    assert_equal(quoted_prefix(DQ + "abc" + DQ + suffix), DQ + "abc" + DQ)
    assert_equal(quoted_prefix("`abc`" + DQ), "`abc`")
    assert_equal(quoted_prefix(SQ + "a" + SQ + "bcd"), SQ + "a" + SQ)
    assert_equal(
        quoted_prefix(DQ + "\\u1234" + DQ + "tail"), DQ + "\\u1234" + DQ
    )
    with assert_raises():
        _ = quoted_prefix(DQ + "abc")


def test_unquote_char() raises:
    """Go's `UnquoteChar`, one character at a time, with the tail.

    The `\\xff` row is the one that shows why the value is a code point and a
    flag rather than a piece of text: 255 is not a character.
    """
    var value, multibyte, tail = unquote_char("abc", UInt8(ord(DQ)))
    assert_equal(Int(value), ord("a"))
    assert_false(multibyte)
    assert_equal(tail, "bc")

    var v2, m2, t2 = unquote_char("\\n rest", UInt8(ord(DQ)))
    assert_equal(Int(v2), 10)
    assert_false(m2)
    assert_equal(t2, " rest")

    var v3, m3, t3 = unquote_char("\\u263a!", UInt8(ord(DQ)))
    assert_equal(Int(v3), 0x263A)
    assert_true(m3)
    assert_equal(t3, "!")

    var v4, m4, t4 = unquote_char("\\xff", UInt8(ord(DQ)))
    assert_equal(Int(v4), 255)
    assert_false(m4)
    assert_equal(t4, "")

    var v5, m5, t5 = unquote_char(chr(0x263A) + "z", UInt8(ord(DQ)))
    assert_equal(Int(v5), 0x263A)
    assert_true(m5)
    assert_equal(t5, "z")

    # The quote in use is the one that may not appear bare.
    with assert_raises():
        _ = unquote_char(DQ, UInt8(ord(DQ)))
    var v6, m6, t6 = unquote_char(DQ, UInt8(ord(SQ)))
    assert_equal(Int(v6), ord(DQ))
    assert_false(m6)
    assert_equal(t6, "")


def test_is_print_and_is_graphic_agree_with_unicode() raises:
    """Go's `TestIsPrint` and `TestIsGraphic`, which compare its private copy
    of the tables against `unicode`. There is one copy here, so what is left
    to check is the handful of answers everything else depends on.
    """
    assert_true(is_print(Int32(ord("a"))))
    assert_true(is_print(Int32(ord(" "))))
    assert_false(is_print(Int32(0)))
    assert_false(is_print(Int32(0x7F)))
    assert_false(is_print(Int32(0xAD)))
    assert_false(is_print(Int32(0xA0)))
    assert_true(is_graphic(Int32(0xA0)))
    assert_true(is_graphic(Int32(0x3000)))
    assert_false(is_graphic(Int32(0)))
