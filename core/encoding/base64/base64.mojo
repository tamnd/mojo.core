"""The encoding itself: an alphabet, a padding rule and a strictness flag.

Go keeps the four standard encodings as package level variables and hands out
pointers to them. There is no package level `var` here, design.md section 3, so
each of the four is a function that builds one, in the way `time.utc()` is a
function for the same reason. An `Encoding` is 324 bytes of tables and no
allocation, so building one per call costs a memcpy rather than a heap trip, and
a caller in a loop can hoist it into a local and get Go's cost exactly.

The tables are the point. Encoding is a lookup of six bits into 64 symbols and
decoding is a lookup of one byte into 256 slots, 255 of which say no. Both are
built once in the constructor, which is also the only place an alphabet is
checked, so nothing downstream of it has to ask whether a symbol is real.

## What a decoder accepts

Carriage returns and line feeds are skipped anywhere in the input, including in
the middle of a four character group and in the middle of padding. That is Go's
behaviour and it is not obviously right, since it means the same bytes decode
whether or not somebody wrapped them at 76 columns on the way past. It is kept
because base64 is what MIME and PEM are made of and both of those wrap, so a
decoder that refused a newline would refuse most of the base64 in the world.

Everything else is refused at the byte that caused it, and the offset of that
byte is on the error. `corrupt.mojo` says how to read it back.

Strictness is the one thing a caller can turn up. RFC 4648 section 3.5 says the
bits of the final character that fall outside the decoded bytes must be zero,
and an encoder that emits them non zero has produced an alternative spelling of
the same data. Go's default accepts those and `Strict` refuses them; this is
the same pair, because the default is what reads other people's base64 and the
strict one is what a protocol uses when two spellings of one value would be a
security bug rather than an inconvenience.
"""

from std.os import abort

from core.errors import Report, partial
from core.errors.codes import ErrBadAlphabet
from core.io import Byte

from .corrupt import _corrupt

comptime STD_PADDING = Int32(ord("="))
"""The padding character RFC 4648 asks for. Go's `StdPadding`."""

comptime NO_PADDING = Int32(-1)
"""Padding turned off, for the raw encodings. Go's `NoPadding`."""

comptime _INVALID = Byte(0xFF)
"""What a decode table slot holds when the byte is not in the alphabet."""

comptime _CR = Byte(ord("\r"))
"""A carriage return, skipped wherever a decoder meets one."""

comptime _LF = Byte(ord("\n"))
"""A line feed, skipped wherever a decoder meets one."""

comptime _STD_ALPHABET = (
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
)
"""The alphabet of RFC 4648 section 4."""

comptime _URL_ALPHABET = (
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
)
"""The alphabet of RFC 4648 section 5, safe in a URL and in a file name."""


struct Encoding(Copyable, Movable):
    """A radix 64 encoding scheme. Go's `Encoding`.

    ```mojo
    from core.encoding.base64 import std_encoding

    def main():
        print(std_encoding().encode_to_string("hello".as_bytes()))
    ```

    A value rather than a pointer to one. Go's methods take a `*Encoding` and
    its two modifiers return a new one, so a Go `Encoding` is already used as
    an immutable value behind a pointer; copying it here is 324 bytes and
    removes the question of who owns it.
    """

    var _encode: InlineArray[Byte, 64]
    """Symbol index to symbol byte. Go's `encode`."""

    var _decode_map: InlineArray[Byte, 256]
    """Symbol byte to symbol index, `_INVALID` for the 192 that are not one."""

    var _pad: Int32
    """The padding character, or `NO_PADDING`. Go's `padChar`."""

    var _strict: Bool
    """Whether the trailing bits of the last character must be zero."""

    def __init__(out self, alphabet: StringSlice) raises:
        """The encoding over `alphabet`, padded with `STD_PADDING`.

        `new_encoding` is the name Go gives this and the one to reach for; the
        constructor is here because Mojo spells construction this way and there
        is no reason to hide it.

        `alphabet` is 64 bytes, treated as bytes and not as characters, with no
        duplicates and no carriage return or line feed. Go panics on each of
        those and this raises `ErrBadAlphabet`, deviations.md has the row. The
        padding character is not checked against the alphabet here for the
        reason Go gives: the caller may be about to change it.
        """
        self._encode = InlineArray[Byte, 64](fill=0)
        self._decode_map = InlineArray[Byte, 256](fill=_INVALID)
        self._pad = STD_PADDING
        self._strict = False

        var symbols = alphabet.as_bytes()
        if len(symbols) != 64:
            raise (
                Report("base64: encoding alphabet is not 64 bytes long")
                .with_code(ErrBadAlphabet)
                .with_count(len(symbols))
                .error()
            )
        for i in range(64):
            var symbol = symbols[i]
            if symbol == _LF or symbol == _CR:
                raise (
                    Report("base64: encoding alphabet contains a newline")
                    .with_code(ErrBadAlphabet)
                    .with_field("at", String(i))
                    .error()
                )
            if self._decode_map[Int(symbol)] != _INVALID:
                raise (
                    Report("base64: encoding alphabet has a duplicate symbol")
                    .with_code(ErrBadAlphabet)
                    .with_field("at", String(i))
                    .error()
                )
            self._encode[i] = symbol
            self._decode_map[Int(symbol)] = Byte(i)

    def with_padding(self, padding: Int32) raises -> Self:
        """This encoding with a different padding character. Go's `WithPadding`.

        `NO_PADDING` turns padding off. Anything else has to be a byte, so not
        negative, not above 0xff, neither newline, and not already a symbol of
        the alphabet. A character above 0x7f is written as that one byte rather
        than as its UTF-8 encoding, which is Go's rule and is why this takes a
        rune and stores a rune but only ever writes one byte.
        """
        if (
            padding < NO_PADDING
            or padding == Int32(ord("\r"))
            or padding == Int32(ord("\n"))
            or padding > 0xFF
        ):
            raise (
                Report("base64: invalid padding character")
                .with_code(ErrBadAlphabet)
                .with_field("padding", String(padding))
                .error()
            )
        if padding != NO_PADDING and self._decode_map[Int(padding)] != _INVALID:
            raise (
                Report("base64: padding character is in the alphabet")
                .with_code(ErrBadAlphabet)
                .with_field("padding", String(padding))
                .error()
            )
        var next = self.copy()
        next._pad = padding
        return next^

    def strict(self) -> Self:
        """This encoding with the trailing bits check on. Go's `Strict`.

        The input is still malleable after this, because newlines are still
        skipped. Strictness is about the bits of the last character and nothing
        else, and RFC 4648 section 3.5 is the paragraph it comes from.
        """
        var next = self.copy()
        next._strict = True
        return next^

    def encoded_len(self, n: Int) -> Int:
        """How many bytes `encode` writes for `n` bytes of input.

        Go's `EncodedLen`. Padded, that is the next multiple of four; unpadded,
        it is one character per six bits with the last one rounded up.
        """
        if self._pad == NO_PADDING:
            return n // 3 * 4 + (n % 3 * 8 + 5) // 6
        return (n + 2) // 3 * 4

    def decoded_len(self, n: Int) -> Int:
        """The most bytes `decode` can write for `n` characters of input.

        Go's `DecodedLen`. The most, not the exact count, because newlines and
        padding both take space in the input and produce nothing.
        """
        return _decoded_len(n, self._pad)

    def encode[
        do: Origin[mut=True], so: Origin
    ](self, dst: Span[Byte, do], src: Span[Byte, so]) -> Int:
        """Encode `src` into `dst` and say how many bytes that took.

        Go's `Encode` returns nothing and this returns the count, which is
        always `encoded_len(len(src))`, for the reason `utf8.encode_rune`
        returns one: a caller that has to compute the length of what a call
        just wrote will get it wrong eventually.

        The caller has to have made room. A `dst` shorter than `encoded_len` is
        a bounds failure from the span rather than a short write, because half
        a group in a buffer is worse than not writing.

        The output is padded to a multiple of four, so this is not the call for
        one block of a larger stream. `new_encoder` is.
        """
        if len(src) == 0:
            return 0

        var di = 0
        var si = 0
        var n = len(src) // 3 * 3
        while si < n:
            var val = (
                (UInt32(src[si]) << 16)
                | (UInt32(src[si + 1]) << 8)
                | UInt32(src[si + 2])
            )
            dst[di] = self._encode[Int((val >> 18) & 0x3F)]
            dst[di + 1] = self._encode[Int((val >> 12) & 0x3F)]
            dst[di + 2] = self._encode[Int((val >> 6) & 0x3F)]
            dst[di + 3] = self._encode[Int(val & 0x3F)]
            si += 3
            di += 4

        var remain = len(src) - si
        if remain == 0:
            return di

        var val = UInt32(src[si]) << 16
        if remain == 2:
            val |= UInt32(src[si + 1]) << 8

        dst[di] = self._encode[Int((val >> 18) & 0x3F)]
        dst[di + 1] = self._encode[Int((val >> 12) & 0x3F)]
        di += 2

        if remain == 2:
            dst[di] = self._encode[Int((val >> 6) & 0x3F)]
            di += 1
            if self._pad != NO_PADDING:
                dst[di] = Byte(self._pad)
                di += 1
        else:
            if self._pad != NO_PADDING:
                dst[di] = Byte(self._pad)
                dst[di + 1] = Byte(self._pad)
                di += 2
        return di

    def append_encode[
        so: Origin
    ](self, mut dst: List[Byte], src: Span[Byte, so]) -> Int:
        """Encode `src` onto the end of `dst`, and say how many bytes that took.

        Go's `AppendEncode` returns the grown slice. Growing a `List` in place
        is the same operation without the return, so this hands back the count,
        which is the rule every appending call in this library follows.
        """
        var start = len(dst)
        var room = self.encoded_len(len(src))
        dst.resize(start + room, 0)
        return self.encode(Span(dst)[start:], src)

    def encode_to_string[so: Origin](self, src: Span[Byte, so]) -> String:
        """`src` encoded, as a `String`. Go's `EncodeToString`.

        The result is ASCII whatever the alphabet is, because an alphabet is 64
        bytes and a byte above 0x7f in one would make the output something a
        `String` should not hold. That is not checked here and it is the one
        thing `new_encoding` will let through.
        """
        var out = List[Byte](capacity=self.encoded_len(len(src)))
        _ = self.append_encode(out, src)
        return String(from_utf8_lossy=out)

    def decode[
        do: Origin[mut=True], so: Origin
    ](self, dst: Span[Byte, do], src: Span[Byte, so]) raises -> Int:
        """Decode `src` into `dst` and say how many bytes came out.

        Go's `Decode` returns a count and an error together. Here a refusal
        raises, the count is on `errors.partial`, and the bytes counted are
        already in `dst`: a caller that wants the good prefix of a bad document
        reads the count and keeps that much of `dst`.

        The caller has to have made room, `decoded_len` says how much, and a
        short `dst` is a bounds failure for the reason `encode` gives.

        Carriage returns and line feeds are skipped anywhere they appear.
        """
        var n = 0
        if len(src) == 0:
            return 0

        var si = 0
        while len(src) - si >= 8 and len(dst) - n >= 8:
            var group, ok = self._assemble64(src, si)
            if ok:
                _put_be64(dst, n, group)
                n += 6
                si += 8
            else:
                si = self._decode_quantum(dst, n, src, si)

        while len(src) - si >= 4 and len(dst) - n >= 4:
            var group, ok = self._assemble32(src, si)
            if ok:
                _put_be32(dst, n, group)
                n += 3
                si += 4
            else:
                si = self._decode_quantum(dst, n, src, si)

        while si < len(src):
            si = self._decode_quantum(dst, n, src, si)
        return n

    def append_decode[
        so: Origin
    ](self, mut dst: List[Byte], src: Span[Byte, so]) raises -> Int:
        """Decode `src` onto the end of `dst`, and say how many bytes came out.

        Go's `AppendDecode` returns the grown slice and, on a malformed input,
        the partially decoded one alongside the error. Both halves are here:
        `dst` ends up holding exactly what was decoded either way, and the
        count comes back from a good decode and off `errors.partial` from a bad
        one. This is the call to use when the prefix of a broken document is
        worth having, because `decode_string` cannot hand it back.
        """
        var trimmed = len(src)
        while trimmed > 0 and Int32(src[trimmed - 1]) == self._pad:
            trimmed -= 1

        var start = len(dst)
        dst.resize(start + _decoded_len(trimmed, NO_PADDING), 0)
        try:
            var got = self.decode(Span(dst)[start:], src)
            dst.resize(start + got, 0)
            return got
        except e:
            dst.resize(start + partial(e), 0)
            raise e

    def decode_string(self, s: StringSlice) raises -> List[Byte]:
        """The bytes `s` spells. Go's `DecodeString`.

        A malformed input raises and the partial decode is lost, which is the
        one place this package gives up something Go returns: the bytes were
        written into a list this call owns and a raise cannot hand it back.
        `append_decode` into a list of the caller's own keeps them.
        """
        var out = List[Byte](length=self.decoded_len(s.byte_length()), fill=0)
        var n = self.decode(Span(out), s.as_bytes())
        out.resize(n, 0)
        return out^

    def _assemble32[
        so: Origin
    ](self, src: Span[Byte, so], si: Int) -> Tuple[UInt32, Bool]:
        """Four characters as three bytes in the top of a `UInt32`.

        Go's `assemble32`. Nothing comes back if any of the four is not a
        symbol, and the caller falls into the slow path that works out which
        one and why. The four lookups are or'ed together and compared once,
        because `_INVALID` is 0xff and any one of them makes the or 0xff.
        """
        var n1 = self._decode_map[Int(src[si])]
        var n2 = self._decode_map[Int(src[si + 1])]
        var n3 = self._decode_map[Int(src[si + 2])]
        var n4 = self._decode_map[Int(src[si + 3])]
        if (n1 | n2 | n3 | n4) == _INVALID:
            return (UInt32(0), False)
        return (
            (UInt32(n1) << 26)
            | (UInt32(n2) << 20)
            | (UInt32(n3) << 14)
            | (UInt32(n4) << 8),
            True,
        )

    def _assemble64[
        so: Origin
    ](self, src: Span[Byte, so], si: Int) -> Tuple[UInt64, Bool]:
        """Eight characters as six bytes in the top of a `UInt64`.

        Go's `assemble64`, and the reason a decode of anything long runs at
        eight characters a round rather than four.
        """
        var n1 = self._decode_map[Int(src[si])]
        var n2 = self._decode_map[Int(src[si + 1])]
        var n3 = self._decode_map[Int(src[si + 2])]
        var n4 = self._decode_map[Int(src[si + 3])]
        var n5 = self._decode_map[Int(src[si + 4])]
        var n6 = self._decode_map[Int(src[si + 5])]
        var n7 = self._decode_map[Int(src[si + 6])]
        var n8 = self._decode_map[Int(src[si + 7])]
        if (n1 | n2 | n3 | n4 | n5 | n6 | n7 | n8) == _INVALID:
            return (UInt64(0), False)
        return (
            (UInt64(n1) << 58)
            | (UInt64(n2) << 52)
            | (UInt64(n3) << 46)
            | (UInt64(n4) << 40)
            | (UInt64(n5) << 34)
            | (UInt64(n6) << 28)
            | (UInt64(n7) << 22)
            | (UInt64(n8) << 16),
            True,
        )

    def _decode_quantum[
        do: Origin[mut=True], so: Origin
    ](
        self,
        dst: Span[Byte, do],
        mut n: Int,
        src: Span[Byte, so],
        start: Int,
    ) raises -> Int:
        """Decode up to four characters from `src[start:]`, and say where the
        input got to.

        Go's `decodeQuantum` returns three values, an index, a count and an
        error, and the count is the awkward one: it is how much this quantum
        wrote and the caller has to add it to a running total before it can
        raise, because the total is what goes on the error. So `n` is the
        running total and this advances it, which makes the raise here able to
        carry the right number without the caller doing anything.

        Everything else is Go's routine as it stands, padding rules and all.
        """
        var dbuf = InlineArray[Byte, 4](fill=0)
        var dlen = 4
        var si = start
        var garbage = -1

        var j = 0
        while j < 4:
            if len(src) == si:
                if j == 0:
                    return si
                if j == 1 or self._pad != NO_PADDING:
                    raise _corrupt(si - j, n)
                dlen = j
                break

            var c = src[si]
            si += 1

            var symbol = self._decode_map[Int(c)]
            if symbol != _INVALID:
                dbuf[j] = symbol
                j += 1
                continue

            if c == _LF or c == _CR:
                continue

            if Int32(c) != self._pad:
                raise _corrupt(si - 1, n)

            # The end of the input, with padding on it.
            if j < 2:
                raise _corrupt(si - 1, n)
            if j == 2:
                # A second `=` is expected. Newlines may be in the way of it.
                while si < len(src) and (src[si] == _LF or src[si] == _CR):
                    si += 1
                if si == len(src):
                    raise _corrupt(len(src), n)
                if Int32(src[si]) != self._pad:
                    raise _corrupt(si - 1, n)
                si += 1

            while si < len(src) and (src[si] == _LF or src[si] == _CR):
                si += 1
            if si < len(src):
                garbage = si
            dlen = j
            break

        # Four six bit symbols are three bytes, and `dlen` says how many of
        # them the input actually spelled.
        var val = (
            (UInt32(dbuf[0]) << 18)
            | (UInt32(dbuf[1]) << 12)
            | (UInt32(dbuf[2]) << 6)
            | UInt32(dbuf[3])
        )
        var b0 = Byte((val >> 16) & 0xFF)
        var b1 = Byte((val >> 8) & 0xFF)
        var b2 = Byte(val & 0xFF)

        if dlen == 4:
            dst[n + 2] = b2
            b2 = 0
        if dlen >= 3:
            dst[n + 1] = b1
            if self._strict and b2 != 0:
                raise _corrupt(si - 1, n)
            b1 = 0
        if dlen >= 2:
            dst[n] = b0
            if self._strict and (b1 != 0 or b2 != 0):
                raise _corrupt(si - 2, n)

        n += dlen - 1
        if garbage >= 0:
            raise _corrupt(garbage, n)
        return si


def new_encoding(alphabet: StringSlice) raises -> Encoding:
    """A padded encoding over `alphabet`. Go's `NewEncoding`.

    ```mojo
    from core.encoding.base64 import new_encoding

    def main():
        var hqx = new_encoding(
            "!\\"#$%&'()*+,-012345689@ABCDEFGHIJKLMNPQRSTUVXYZ[`abcdefhijklmpqr"
        )
        print(hqx.encode_to_string("hello".as_bytes()))
    ```

    The alphabet is 64 bytes with no duplicates and no newline, and this raises
    `ErrBadAlphabet` where Go panics. `with_padding` changes or removes the
    padding character afterwards.
    """
    return Encoding(alphabet)


def std_encoding() -> Encoding:
    """The standard encoding of RFC 4648, padded. Go's `StdEncoding`.

    ```mojo
    from core.encoding.base64 import std_encoding

    def main():
        print(std_encoding().encode_to_string("hi".as_bytes()))  # aGk=
    ```
    """
    return _built(_STD_ALPHABET, STD_PADDING)


def url_encoding() -> Encoding:
    """The URL and file name safe encoding, padded. Go's `URLEncoding`.

    The same as `std_encoding` with `-` and `_` in place of `+` and `/`, so
    that the output survives being pasted into a URL or used as a file name.
    """
    return _built(_URL_ALPHABET, STD_PADDING)


def raw_std_encoding() -> Encoding:
    """The standard encoding without padding. Go's `RawStdEncoding`.

    RFC 4648 section 3.2. Padding is only worth having when base64 is being
    concatenated with something else, and a format that knows its own lengths
    is better off without it.
    """
    return _built(_STD_ALPHABET, NO_PADDING)


def raw_url_encoding() -> Encoding:
    """The URL safe encoding without padding. Go's `RawURLEncoding`.

    This is the one in a JSON web token and in most things that put base64 in
    a URL, because `=` has a meaning there.
    """
    return _built(_URL_ALPHABET, NO_PADDING)


def _built(alphabet: StringSlice, padding: Int32) -> Encoding:
    """One of the four above, from an alphabet the library wrote down itself.

    `new_encoding` and `with_padding` both raise, and the four standard
    encodings would then be raising calls forever after over a failure no
    caller can cause. So this aborts on it instead, which is the same trade
    `big.must_set_string` makes and is only ever reached if this file's own
    two alphabet constants are wrong.
    """
    try:
        return Encoding(alphabet).with_padding(padding)
    except:
        abort("base64: a built in alphabet was refused")


def _decoded_len(n: Int, padding: Int32) -> Int:
    """`decoded_len` for an encoding that may not exist yet.

    Go has this as a free function because `AppendDecode` wants the unpadded
    answer from a padded encoding, to size a buffer for input whose padding it
    has already trimmed off.
    """
    if padding == NO_PADDING:
        return n // 4 * 3 + n % 4 * 6 // 8
    return n // 4 * 3


def _put_be32[o: Origin[mut=True]](dst: Span[Byte, o], at: Int, v: UInt32):
    """Write `v` at `at`, most significant byte first.

    Four bytes for three bytes of output, because the fourth holds the low
    eight bits of the assembled group and they are always zero. The caller has
    checked there is room for all four.
    """
    for i in range(4):
        dst[at + i] = Byte((v >> UInt32(24 - i * 8)) & 0xFF)


def _put_be64[o: Origin[mut=True]](dst: Span[Byte, o], at: Int, v: UInt64):
    """Write `v` at `at`, most significant byte first.

    Eight bytes for six bytes of output, for the reason `_put_be32` writes
    four for three, and it is why the fast path in `decode` asks for eight
    bytes of room to produce six.
    """
    for i in range(8):
        dst[at + i] = Byte((v >> UInt64(56 - i * 8)) & 0xFF)
