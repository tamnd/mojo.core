"""Go string and rune literals, written and read back. Go's `quote.go`.

Two directions. `quote` and its family turn text into the literal a Go or Mojo
programmer would type to produce it, escaping whatever is not printable.
`unquote` and `unquote_char` read one back.

Go's `strconv` carries its own copy of the printable ranges in `isprint.go`,
generated from the Unicode database, and the comment above it says why: it
exists so that `strconv` does not have to import `unicode` and pull the whole
character database in behind it. That reason does not apply here, because
`core.unicode.RangeTable` is four integers naming a slice of one packed array
that lives in read only memory, so reaching for it costs nothing that is not
already paid for. `is_print` and `is_graphic` below call `core.unicode`, and
there is one copy of the answer rather than two that have to be kept agreeing.

The one place this cannot follow Go is the result of `unquote`. A Go string is
arbitrary bytes, so `Unquote("\\"\\\\xff\\"")` hands back a one byte string that
is not valid UTF-8. A Mojo `String` cannot hold that, so `unquote` raises there
and `unquote_bytes` is the sibling that never refuses, which is the same split
`bufio.Scanner` and `strings.Builder` already use.
"""

from core.unicode import is_graphic as _unicode_is_graphic
from core.unicode import is_print as _unicode_is_print
from core.unicode.utf8 import (
    RUNE_ERROR,
    RUNE_SELF,
    append_rune,
    decode_rune,
    valid_rune,
)

from core.errors import Report
from core.errors.codes import ErrSyntax

# The seven escapes Go writes as letters, by the byte each one stands for.
# Written as numbers because Mojo has no `\a` and no `\v` in a literal, and a
# table of `chr` calls would read no better than the code points do.
comptime _BELL = Int32(7)
comptime _BACKSPACE = Int32(8)
comptime _TAB = Int32(9)
comptime _NEWLINE = Int32(10)
comptime _VERTICAL_TAB = Int32(11)
comptime _FORM_FEED = Int32(12)
comptime _RETURN = Int32(13)

comptime _BACKSLASH = Int32(ord("\\"))
comptime _SINGLE_QUOTE = UInt8(ord("'"))
comptime _DOUBLE_QUOTE = UInt8(ord('"'))
comptime _BACKQUOTE = UInt8(ord("`"))


def _hex_digit(v: Int32) -> UInt8:
    """One lower case hexadecimal digit for a value in 0 through 15."""
    if v < 10:
        return UInt8(Int(v) + ord("0"))
    return UInt8(Int(v) - 10 + ord("a"))


def _append_literal(mut buf: List[UInt8], s: StringSlice[ImmStaticOrigin]):
    """Append the bytes of an ASCII literal. Every caller passes a constant."""
    var data = s.as_bytes()
    for i in range(len(data)):
        buf.append(data[i])


def is_print(r: Int32) -> Bool:
    """Whether `r` is printable: letters, marks, numbers, punctuation, symbols
    and the ASCII space. Go's `strconv.IsPrint`.

    The same answer as `core.unicode.is_print`, and by the same tables, which
    is what Go's own test asserts about its private copy.
    """
    return _unicode_is_print(r)


def is_graphic(r: Int32) -> Bool:
    """Whether `r` is graphic: everything `is_print` accepts, plus the spaces
    of category Zs. Go's `strconv.IsGraphic`.
    """
    return _unicode_is_graphic(r)


def _is_in_graphic_list(r: Int32) -> Bool:
    """Graphic but not printable, which is every Zs space but the ASCII one.

    Go keeps this as a list so that `quoteWith` does not call `IsPrint` twice.
    Here it is the subtraction it always was.
    """
    return _unicode_is_graphic(r) and not _unicode_is_print(r)


def _append_escaped_rune(
    mut buf: List[UInt8],
    r: Int32,
    mark: UInt8,
    ascii_only: Bool,
    graphic_only: Bool,
) -> None:
    """One rune, escaped if it has to be. `mark` is the quote in use, which is
    the one character that always gets a backslash.
    """
    if r == Int32(mark) or r == _BACKSLASH:
        buf.append(UInt8(ord("\\")))
        buf.append(UInt8(Int(r)))
        return

    if ascii_only:
        if r < Int32(RUNE_SELF) and is_print(r):
            buf.append(UInt8(Int(r)))
            return
    elif is_print(r) or (graphic_only and _is_in_graphic_list(r)):
        _ = append_rune(buf, r)
        return

    if r == _BELL:
        _append_literal(buf, "\\a")
        return
    if r == _BACKSPACE:
        _append_literal(buf, "\\b")
        return
    if r == _FORM_FEED:
        _append_literal(buf, "\\f")
        return
    if r == _NEWLINE:
        _append_literal(buf, "\\n")
        return
    if r == _RETURN:
        _append_literal(buf, "\\r")
        return
    if r == _TAB:
        _append_literal(buf, "\\t")
        return
    if r == _VERTICAL_TAB:
        _append_literal(buf, "\\v")
        return

    var value = r
    if value < Int32(0x20) or value == Int32(0x7F):
        _append_literal(buf, "\\x")
        buf.append(_hex_digit((value >> 4) & 0xF))
        buf.append(_hex_digit(value & 0xF))
        return
    if not valid_rune(value):
        value = RUNE_ERROR
    if value < Int32(0x10000):
        _append_literal(buf, "\\u")
        var shift = Int32(12)
        while shift >= 0:
            buf.append(_hex_digit((value >> shift) & 0xF))
            shift -= 4
        return
    _append_literal(buf, "\\U")
    var shift = Int32(28)
    while shift >= 0:
        buf.append(_hex_digit((value >> shift) & 0xF))
        shift -= 4


def _append_quoted_with[
    o: ImmOrigin
](
    mut buf: List[UInt8],
    s: Span[UInt8, o],
    mark: UInt8,
    ascii_only: Bool,
    graphic_only: Bool,
) -> Int:
    """The whole of `s` as a quoted literal, and how many bytes that took.

    Over bytes rather than over a `StringSlice` because a byte that begins
    nothing valid has to come out as `\\xNN`, and a `StringSlice` cannot hold
    one. The public entry points are all over text and lend their bytes.
    """
    var start = len(buf)
    buf.append(mark)
    var i = 0
    while i < len(s):
        var r, width = decode_rune(s[i : len(s)])
        if width == 1 and r == RUNE_ERROR:
            _append_literal(buf, "\\x")
            buf.append(_hex_digit(Int32(Int(s[i] >> 4))))
            buf.append(_hex_digit(Int32(Int(s[i] & 0xF))))
            i += 1
            continue
        _append_escaped_rune(buf, r, mark, ascii_only, graphic_only)
        i += width
    buf.append(mark)
    return len(buf) - start


def _append_quoted_rune_with(
    mut buf: List[UInt8],
    r: Int32,
    mark: UInt8,
    ascii_only: Bool,
    graphic_only: Bool,
) -> Int:
    """One rune as a quoted literal, and how many bytes that took."""
    var start = len(buf)
    buf.append(mark)
    var value = r
    if not valid_rune(value):
        value = RUNE_ERROR
    _append_escaped_rune(buf, value, mark, ascii_only, graphic_only)
    buf.append(mark)
    return len(buf) - start


def _to_string(var buf: List[UInt8]) -> String:
    """A quoted literal as text.

    Lossy rather than checked, and it never substitutes anything: every byte
    written above is either an escape, which is ASCII, or a rune that decoded
    from valid input and was encoded back. The lossy constructor is the one
    that does not oblige every quoting function to raise for a case that
    cannot arise.
    """
    return String(from_utf8_lossy=Span(buf))


def quote[o: ImmOrigin](s: StringSlice[o]) -> String:
    """`s` as a double quoted Go string literal. Go's `Quote`.

    Control characters and anything `is_print` refuses become `\\t`, `\\n`,
    `\\xff`, `\\u0100` and so on.
    """
    var buf = List[UInt8]()
    _ = _append_quoted_with(buf, s.as_bytes(), _DOUBLE_QUOTE, False, False)
    return _to_string(buf^)


def append_quote[o: ImmOrigin](mut dst: List[UInt8], s: StringSlice[o]) -> Int:
    """`quote(s)` onto the end of `dst`, and how many bytes that took.

    Go's `AppendQuote` returns the grown slice, which is what `append` does.
    The same rule as `utf8.append_rune`: the list grows in place and the count
    comes back.
    """
    return _append_quoted_with(dst, s.as_bytes(), _DOUBLE_QUOTE, False, False)


def quote_bytes[o: ImmOrigin](s: Span[UInt8, o]) -> String:
    """`s` as a double quoted literal, with anything that is not valid UTF-8
    written as `\\xNN`.

    Not in Go, which needs no such thing: `Quote` takes a `string` and a Go
    string is bytes, so `Quote("abc\\xffdef")` is an ordinary call there. Here
    text and bytes are different types, and this is the half of `quote` that
    the `\\xNN` escape exists for. The pair with `unquote_bytes` in the other
    direction.
    """
    var buf = List[UInt8]()
    _ = _append_quoted_with(buf, s, _DOUBLE_QUOTE, False, False)
    return _to_string(buf^)


def append_quote_bytes[
    o: ImmOrigin
](mut dst: List[UInt8], s: Span[UInt8, o]) -> Int:
    """`quote_bytes(s)` onto the end of `dst`, and how many bytes that took."""
    return _append_quoted_with(dst, s, _DOUBLE_QUOTE, False, False)


def quote_to_ascii[o: ImmOrigin](s: StringSlice[o]) -> String:
    """`s` as a double quoted literal with nothing outside ASCII left in it.

    Go's `QuoteToASCII`.
    """
    var buf = List[UInt8]()
    _ = _append_quoted_with(buf, s.as_bytes(), _DOUBLE_QUOTE, True, False)
    return _to_string(buf^)


def append_quote_to_ascii[
    o: ImmOrigin
](mut dst: List[UInt8], s: StringSlice[o]) -> Int:
    """`quote_to_ascii(s)` onto the end of `dst`. Go's `AppendQuoteToASCII`."""
    return _append_quoted_with(dst, s.as_bytes(), _DOUBLE_QUOTE, True, False)


def quote_to_graphic[o: ImmOrigin](s: StringSlice[o]) -> String:
    """`s` as a double quoted literal, keeping every graphic character.

    Go's `QuoteToGraphic`. The difference from `quote` is the spaces of
    category Zs, which are graphic but not printable and so survive here and
    are escaped there.
    """
    var buf = List[UInt8]()
    _ = _append_quoted_with(buf, s.as_bytes(), _DOUBLE_QUOTE, False, True)
    return _to_string(buf^)


def append_quote_to_graphic[
    o: ImmOrigin
](mut dst: List[UInt8], s: StringSlice[o]) -> Int:
    """`quote_to_graphic(s)` onto `dst`. Go's `AppendQuoteToGraphic`."""
    return _append_quoted_with(dst, s.as_bytes(), _DOUBLE_QUOTE, False, True)


def quote_rune(r: Int32) -> String:
    """`r` as a single quoted Go character literal. Go's `QuoteRune`.

    A code point that is not valid is written as U+FFFD, as Go does.
    """
    var buf = List[UInt8]()
    _ = _append_quoted_rune_with(buf, r, _SINGLE_QUOTE, False, False)
    return _to_string(buf^)


def append_quote_rune(mut dst: List[UInt8], r: Int32) -> Int:
    """`quote_rune(r)` onto the end of `dst`. Go's `AppendQuoteRune`."""
    return _append_quoted_rune_with(dst, r, _SINGLE_QUOTE, False, False)


def quote_rune_to_ascii(r: Int32) -> String:
    """`r` as a single quoted literal, escaped unless it is printable ASCII.

    Go's `QuoteRuneToASCII`.
    """
    var buf = List[UInt8]()
    _ = _append_quoted_rune_with(buf, r, _SINGLE_QUOTE, True, False)
    return _to_string(buf^)


def append_quote_rune_to_ascii(mut dst: List[UInt8], r: Int32) -> Int:
    """`quote_rune_to_ascii(r)` onto `dst`. Go's `AppendQuoteRuneToASCII`."""
    return _append_quoted_rune_with(dst, r, _SINGLE_QUOTE, True, False)


def quote_rune_to_graphic(r: Int32) -> String:
    """`r` as a single quoted literal, escaped unless it is graphic.

    Go's `QuoteRuneToGraphic`.
    """
    var buf = List[UInt8]()
    _ = _append_quoted_rune_with(buf, r, _SINGLE_QUOTE, False, True)
    return _to_string(buf^)


def append_quote_rune_to_graphic(mut dst: List[UInt8], r: Int32) -> Int:
    """`quote_rune_to_graphic(r)` onto `dst`. Go's `AppendQuoteRuneToGraphic`.
    """
    return _append_quoted_rune_with(dst, r, _SINGLE_QUOTE, False, True)


def can_backquote[o: ImmOrigin](s: StringSlice[o]) -> Bool:
    """Whether `s` can be written between backquotes unchanged.

    Go's `CanBackquote`. No control characters other than tab, no backquote,
    no delete, and no byte order mark, which is refused because it is
    invisible and a literal containing one would not read as what it is.
    """
    var data = s.as_bytes()
    var i = 0
    while i < len(data):
        var r, width = decode_rune(data[i : len(data)])
        i += width
        if width > 1:
            if r == Int32(0xFEFF):
                return False
            continue
        if r == RUNE_ERROR:
            return False
        if (
            (r < Int32(0x20) and r != _TAB)
            or r == Int32(ord("`"))
            or r == Int32(0x7F)
        ):
            return False
    return True


def _unhex(b: UInt8) -> Tuple[Int32, Bool]:
    """One hexadecimal digit as a value, and whether it was one."""
    var c = Int32(Int(b))
    if c >= Int32(ord("0")) and c <= Int32(ord("9")):
        return (c - Int32(ord("0")), True)
    if c >= Int32(ord("a")) and c <= Int32(ord("f")):
        return (c - Int32(ord("a")) + 10, True)
    if c >= Int32(ord("A")) and c <= Int32(ord("F")):
        return (c - Int32(ord("A")) + 10, True)
    return (Int32(0), False)


def _syntax() -> Error:
    """The one failure every reader in this file reports."""
    return (
        Report("strconv.unquote: invalid syntax").with_code(ErrSyntax).error()
    )


def unquote_char[
    o: ImmOrigin
](s: StringSlice[o], mark: UInt8) raises -> Tuple[Int32, Bool, StringSlice[o]]:
    """The first character of an escaped literal body, and what is left of it.

    Go's `UnquoteChar`. Three values rather than four: the decoded code point,
    whether it needs more than one byte of UTF-8, and the tail. Go's fourth is
    the error, which is a raise here.

    `mark` says which literal is being read and therefore which quote may
    appear escaped. A single quote permits `\\'` and refuses a bare `'`, a
    double quote permits `\\"` and refuses a bare `"`, and zero permits
    neither escape and allows both characters through unescaped.

    The value can be a byte rather than a code point: `\\xff` decodes to 255
    with the second result `False`, exactly as in Go, and a caller assembling
    text has to decide what to do about that.
    """
    var data = s.as_bytes()
    if len(data) == 0:
        raise _syntax()

    var c = data[0]
    if c == mark and (mark == _SINGLE_QUOTE or mark == _DOUBLE_QUOTE):
        raise _syntax()
    if c >= UInt8(RUNE_SELF):
        var r, size = decode_rune(data)
        return (r, True, s[byte = size : s.byte_length()])
    if c != UInt8(ord("\\")):
        return (Int32(Int(c)), False, s[byte = 1 : s.byte_length()])

    if len(data) <= 1:
        raise _syntax()
    var kind = data[1]
    var at = 2

    var value = Int32(0)
    var multibyte = False

    if kind == UInt8(ord("a")):
        value = _BELL
    elif kind == UInt8(ord("b")):
        value = _BACKSPACE
    elif kind == UInt8(ord("f")):
        value = _FORM_FEED
    elif kind == UInt8(ord("n")):
        value = _NEWLINE
    elif kind == UInt8(ord("r")):
        value = _RETURN
    elif kind == UInt8(ord("t")):
        value = _TAB
    elif kind == UInt8(ord("v")):
        value = _VERTICAL_TAB
    elif (
        kind == UInt8(ord("x"))
        or kind == UInt8(ord("u"))
        or kind == UInt8(ord("U"))
    ):
        var n = 2
        if kind == UInt8(ord("u")):
            n = 4
        elif kind == UInt8(ord("U")):
            n = 8
        if len(data) - at < n:
            raise _syntax()
        var v = Int32(0)
        for j in range(n):
            var digit, ok = _unhex(data[at + j])
            if not ok:
                raise _syntax()
            v = (v << 4) | digit
        at += n
        if kind == UInt8(ord("x")):
            # A single byte, which may be no part of any code point.
            value = v
        else:
            if not valid_rune(v):
                raise _syntax()
            value = v
            multibyte = True
    elif kind >= UInt8(ord("0")) and kind <= UInt8(ord("7")):
        var v = Int32(Int(kind) - ord("0"))
        if len(data) - at < 2:
            raise _syntax()
        for j in range(2):
            var digit = Int32(Int(data[at + j]) - ord("0"))
            if digit < 0 or digit > 7:
                raise _syntax()
            v = (v << 3) | digit
        at += 2
        if v > 255:
            raise _syntax()
        value = v
    elif kind == UInt8(ord("\\")):
        value = _BACKSLASH
    elif kind == _SINGLE_QUOTE or kind == _DOUBLE_QUOTE:
        if kind != mark:
            raise _syntax()
        value = Int32(Int(kind))
    else:
        raise _syntax()

    return (value, multibyte, s[byte = at : s.byte_length()])


def _index_byte[o: ImmOrigin](s: Span[UInt8, o], c: UInt8, at: Int) -> Int:
    """The first `c` at or after `at`, or -1. A loop rather than a dependency
    on `core.bytes`, which would put this package a tier further up for four
    lines.
    """
    var i = at
    while i < len(s):
        if s[i] == c:
            return i
        i += 1
    return -1


def _unquote[
    o: ImmOrigin
](s: StringSlice[o], mut out: List[UInt8], unescape: Bool) raises -> Int:
    """The literal at the front of `s`, decoded, and how many bytes it filled.

    Go's private `unquote`, with the same `unescape` switch: with it off
    nothing is decoded and only the length matters, which is what
    `quoted_prefix` wants and is the reason the flag exists rather than two
    functions that would have to agree.

    The decoded value lands in `out`, which is a list of bytes rather than a
    `String` because `\\xff` is a legal escape whose value is no part of any
    code point. The return is how many bytes of `s` the literal filled, which
    is where the caller's tail begins.
    """
    var data = s.as_bytes()
    if len(data) < 2:
        raise _syntax()

    var mark = data[0]
    var end = _index_byte(data, mark, 1)
    if end < 0:
        raise _syntax()
    end += 1  # Past the closing quote, unless an escape moves it.

    if mark == _BACKQUOTE:
        if unescape:
            # A carriage return inside a raw literal is dropped, which is what
            # the language specification says the value of one is.
            for i in range(1, end - 1):
                if data[i] != UInt8(Int(_RETURN)):
                    out.append(data[i])
        return end

    if mark != _DOUBLE_QUOTE and mark != _SINGLE_QUOTE:
        raise _syntax()

    # The fast path: no escape and no newline, so the body is the value. Go
    # also checks the body is valid UTF-8, which here it always is, because
    # `s` is text rather than bytes.
    var escape_at = _index_byte(data, UInt8(ord("\\")), 0)
    var newline_at = _index_byte(data, UInt8(Int(_NEWLINE)), 0)
    var simple = (escape_at < 0 or escape_at >= end) and (
        newline_at < 0 or newline_at >= end
    )
    if simple:
        var valid = True
        if mark == _SINGLE_QUOTE:
            var r, n = decode_rune(data[1 : end - 1])
            valid = 1 + n + 1 == end and (r != RUNE_ERROR or n != 1)
        if valid:
            if unescape:
                for i in range(1, end - 1):
                    out.append(data[i])
            return end

    var rest = s[byte = 1 : s.byte_length()]
    while rest.byte_length() > 0 and rest.as_bytes()[0] != mark:
        if rest.as_bytes()[0] == UInt8(Int(_NEWLINE)):
            raise _syntax()
        var r, multibyte, tail = unquote_char(rest, mark)
        rest = tail
        if unescape:
            if r < Int32(RUNE_SELF) or not multibyte:
                out.append(UInt8(Int(r)))
            else:
                _ = append_rune(out, r)
        if mark == _SINGLE_QUOTE:
            break

    if rest.byte_length() == 0 or rest.as_bytes()[0] != mark:
        raise _syntax()
    return s.byte_length() - rest.byte_length() + 1


def unquote[o: ImmOrigin](s: StringSlice[o]) raises -> String:
    """The value of the Go string or character literal `s`. Go's `Unquote`.

    Single quoted, double quoted or backquoted, and the whole of `s` has to be
    the literal: trailing text is a syntax error.

    Raises when the value is not valid UTF-8, which `"\\xff"` is not. Go hands
    those bytes back because a Go string is bytes; `unquote_bytes` is the
    sibling here that never refuses, and it is what a caller reading unknown
    encodings wants anyway.
    """
    var value = List[UInt8]()
    var end = _unquote(s, value, True)
    if end != s.byte_length():
        raise _syntax()
    return String(from_utf8=Span(value))


def unquote_bytes[o: ImmOrigin](s: StringSlice[o]) raises -> List[UInt8]:
    """`unquote` without the UTF-8 check, so `"\\xff"` gives one byte.

    Not in Go, which needs no such thing: `Unquote` returns a `string` and a Go
    string is bytes. It is here because a Mojo `String` is validated, so the
    two answers are different types and both have to have a name.
    """
    var value = List[UInt8]()
    var end = _unquote(s, value, True)
    if end != s.byte_length():
        raise _syntax()
    return value^


def quoted_prefix[o: ImmOrigin](s: StringSlice[o]) raises -> StringSlice[o]:
    """The quoted literal at the front of `s`, quotes included, undecoded.

    Go's `QuotedPrefix`. A view into `s` rather than a copy, which is what
    Go's substring is too.
    """
    var ignored = List[UInt8]()
    var end = _unquote(s, ignored, False)
    return s[byte=0:end]
