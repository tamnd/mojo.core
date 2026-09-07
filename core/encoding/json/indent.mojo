"""Reshaping a document without changing what it says. Go's `indent.go`.

`compact` takes the whitespace out, `indent` puts it back in a chosen shape,
and `html_escape` rewrites the five characters that make a document unsafe to
drop into a script tag. All three run over `_Scanner`, so all three refuse
exactly the documents `valid` refuses and none of them decode anything.

Go writes into a `bytes.Buffer` and these append to a `List[Byte]`, which is
the shape `core.strconv.append_quote` and the rest of this library already use.
On a failure the list is cut back to the length it had, so a caller who reuses
one buffer for many documents never finds half of a bad one in it, which is
Go's rule as well.
"""

from core.io import Byte

from .scan import (
    _SCAN_END_ARRAY,
    _SCAN_END_OBJECT,
    _SCAN_ERROR,
    _SCAN_SKIP_SPACE,
    _Scanner,
    _COMMA,
    _COLON,
    _LBRACE,
    _LBRACKET,
    _NEWLINE,
    _RBRACE,
    _RBRACKET,
    _SPACE,
)

comptime _HEX = "0123456789abcdef"
"""The digits a `\\u` escape is written with, in lower case, which is Go's."""

comptime _AMPERSAND = Byte(38)
comptime _LESS = Byte(60)
comptime _GREATER = Byte(62)
comptime _BACKSLASH = Byte(92)
comptime _LOWER_U = Byte(117)
comptime _E2 = Byte(0xE2)
comptime _80 = Byte(0x80)
comptime _A8 = Byte(0xA8)


def _append_html_escape[o: Origin](mut dst: List[Byte], src: Span[Byte, o]):
    """Go's `appendHTMLEscape`, byte for byte.

    Nothing is parsed. The three ASCII characters and the two separators can
    only carry meaning inside a string literal, and rewriting them anywhere
    else would either change a document that was already fine or corrupt one
    that was not, so a single pass over the bytes is the whole of it.
    """
    var start = 0
    var hex = _HEX.as_bytes()
    for i in range(len(src)):
        var c = src[i]
        if c == _LESS or c == _GREATER or c == _AMPERSAND:
            dst.extend(src[start:i])
            dst.append(_BACKSLASH)
            dst.append(_LOWER_U)
            dst.append(Byte(ord("0")))
            dst.append(Byte(ord("0")))
            dst.append(hex[Int(c >> 4)])
            dst.append(hex[Int(c & 0xF)])
            start = i + 1
        # U+2028 and U+2029, which are E2 80 A8 and E2 80 A9. A browser reading
        # a script tag treats both as line terminators and JSON does not, so a
        # document holding one is valid and the page holding the document is
        # broken.
        if (
            c == _E2
            and i + 2 < len(src)
            and src[i + 1] == _80
            and (src[i + 2] & ~Byte(1)) == _A8
        ):
            dst.extend(src[start:i])
            dst.append(_BACKSLASH)
            dst.append(_LOWER_U)
            dst.append(Byte(ord("2")))
            dst.append(Byte(ord("0")))
            dst.append(Byte(ord("2")))
            dst.append(hex[Int(src[i + 2] & 0xF)])
            start = i + 3
    dst.extend(src[start:])


def html_escape[o: Origin](mut dst: List[Byte], src: Span[Byte, o]):
    """Append `src` to `dst` with the five unsafe characters spelled out.
    Go's `HTMLEscape`.

    ```mojo
    from core.encoding.json import html_escape
    from core.io import Byte

    def main():
        var out = List[Byte]()
        html_escape(out, '{"a":"<b>"}'.as_bytes())
        print(String(from_utf8_lossy=Span(out)))  # {"a":"\\u003cb\\u003e"}
    ```

    A browser does not honour HTML escaping inside a script tag, so a document
    holding `</script>` inside a string ends the tag when it is embedded in a
    page. Rewriting the three characters that can start such a thing, and the
    two separators a browser reads as line endings, makes the bytes safe to
    embed and leaves what they mean untouched.

    Nothing is validated. `src` that is not JSON comes out as it went in with
    those characters rewritten, which is Go's behaviour and is why this cannot
    fail.
    """
    _append_html_escape(dst, src)


def _append_compact[
    o: Origin
](mut dst: List[Byte], src: Span[Byte, o], escape: Bool) raises:
    """Go's `appendCompact`. `escape` is what `Encoder.set_escape_html` sets."""
    var orig_len = len(dst)
    var scan = _Scanner()
    scan.reset()
    var hex = _HEX.as_bytes()
    var start = 0
    for i in range(len(src)):
        var c = src[i]
        if escape and (c == _LESS or c == _GREATER or c == _AMPERSAND):
            if start < i:
                dst.extend(src[start:i])
            dst.append(_BACKSLASH)
            dst.append(_LOWER_U)
            dst.append(Byte(ord("0")))
            dst.append(Byte(ord("0")))
            dst.append(hex[Int(c >> 4)])
            dst.append(hex[Int(c & 0xF)])
            start = i + 1
        if (
            escape
            and c == _E2
            and i + 2 < len(src)
            and src[i + 1] == _80
            and (src[i + 2] & ~Byte(1)) == _A8
        ):
            if start < i:
                dst.extend(src[start:i])
            dst.append(_BACKSLASH)
            dst.append(_LOWER_U)
            dst.append(Byte(ord("2")))
            dst.append(Byte(ord("0")))
            dst.append(Byte(ord("2")))
            dst.append(hex[Int(src[i + 2] & 0xF)])
            start = i + 3
        scan.bytes += 1
        var v = scan.next(c)
        if v >= _SCAN_SKIP_SPACE:
            if v == _SCAN_ERROR:
                break
            if start < i:
                dst.extend(src[start:i])
            start = i + 1
    if scan.eof() == _SCAN_ERROR:
        dst.resize(orig_len, 0)
        raise scan.error()
    if start < len(src):
        dst.extend(src[start:])


def compact[o: Origin](mut dst: List[Byte], src: Span[Byte, o]) raises:
    """Append `src` to `dst` with the insignificant whitespace gone. Go's
    `Compact`.

    ```mojo
    from core.encoding.json import compact
    from core.io import Byte

    def main() raises:
        var out = List[Byte]()
        compact(out, '{ "a" : [ 1, 2 ] }'.as_bytes())
        print(String(from_utf8_lossy=Span(out)))  # {"a":[1,2]}
    ```

    Insignificant means between values: whitespace inside a string literal is
    part of the string and is left alone. A document that is not JSON raises
    and `dst` is left the length it was.

    Go's `Compact` reports an offset of zero on every failure, because the loop
    that feeds the scanner is the one loop in that file that forgets to count
    the bytes it fed. This counts, so the offset means what the field says it
    means. `docs/deviations.md` has the row.
    """
    _append_compact(dst, src, False)


def _append_newline[
    o1: ImmOrigin, o2: ImmOrigin
](
    mut dst: List[Byte],
    prefix: StringSlice[o1],
    indent: StringSlice[o2],
    depth: Int,
):
    """A line ending, the prefix, and one indent per level. Go's
    `appendNewline`."""
    dst.append(_NEWLINE)
    dst.extend(prefix.as_bytes())
    for _ in range(depth):
        dst.extend(indent.as_bytes())


def indent[
    o1: Origin, o2: ImmOrigin, o3: ImmOrigin
](
    mut dst: List[Byte],
    src: Span[Byte, o1],
    prefix: StringSlice[o2],
    indent: StringSlice[o3],
) raises:
    """Append `src` to `dst` with every element on its own line. Go's `Indent`.

    ```mojo
    from core.encoding.json import indent
    from core.io import Byte

    def main() raises:
        var out = List[Byte]()
        indent(out, "[1,2]".as_bytes(), "", "  ")
        print(String(from_utf8_lossy=Span(out)))
        # [
        #   1,
        #   2
        # ]
    ```

    Each line begins with `prefix` and then one copy of `indent` per level of
    nesting. The first line gets neither, so the result drops straight into
    other formatted JSON at whatever level it is already at, which is what Go's
    documentation promises.

    An empty object or array stays on one line, because the newline after an
    opening brace is delayed until something turns up that is not the matching
    closing one. Whitespace at the front of `src` is dropped and whitespace at
    the end is copied, so a document ending in a newline still does.

    A document that is not JSON raises and `dst` is left the length it was.
    """
    var orig_len = len(dst)
    var scan = _Scanner()
    scan.reset()
    var need_indent = False
    var depth = 0
    for i in range(len(src)):
        var c = src[i]
        scan.bytes += 1
        var v = scan.next(c)
        if v == _SCAN_SKIP_SPACE:
            continue
        if v == _SCAN_ERROR:
            break
        if need_indent and v != _SCAN_END_OBJECT and v != _SCAN_END_ARRAY:
            need_indent = False
            depth += 1
            _append_newline(dst, prefix, indent, depth)
        # Punctuation inside a string is not punctuation, and the scanner is
        # what knows the difference, so anything it calls uninteresting is
        # copied without being looked at.
        if v == 0:
            dst.append(c)
            continue
        if c == _LBRACE or c == _LBRACKET:
            need_indent = True
            dst.append(c)
        elif c == _COMMA:
            dst.append(c)
            _append_newline(dst, prefix, indent, depth)
        elif c == _COLON:
            dst.append(c)
            dst.append(_SPACE)
        elif c == _RBRACE or c == _RBRACKET:
            if need_indent:
                need_indent = False
            else:
                depth -= 1
                _append_newline(dst, prefix, indent, depth)
            dst.append(c)
        else:
            dst.append(c)
    if scan.eof() == _SCAN_ERROR:
        dst.resize(orig_len, 0)
        raise scan.error()
