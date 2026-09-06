"""The encoding itself: an alphabet of thirty two symbols and a padding rule.

Base32 is base64's less popular twin and this file is `base64.mojo` with the
group sizes changed, which is what Go's two files are. Five bytes go to eight
characters instead of three bytes to four, a symbol is five bits instead of
six, and there is no strict mode because Go's base32 does not have one.

The two standard alphabets are functions rather than package level variables
for the reason `time.utc()` is a function, design.md section 3. `std_encoding`
is the one RFC 4648 section 6 defines, the one in SASL and in TOTP keys, and
`hex_encoding` is the extended hex alphabet of section 7, whose symbols sort in
the same order as the values behind them, which is why DNSSEC uses it for
NSEC3 names.

## What a decoder accepts

Carriage returns and line feeds are skipped anywhere in the input, the same as
in base64 and for the same reason: base32 is written down in places that wrap.
Everything else is refused at the byte that caused it, and the offset of that
byte is on the error. `corrupt.mojo` says how to read it back.

Padding is the part that is fiddlier than base64's. A group is eight characters
and RFC 4648 section 6 allows five lengths of padding, so a quantum can hold
two, four, five, seven or eight symbols and nothing else. One, three and six
symbols carry no whole byte between them, so an input that ends that way is
refused rather than rounded down.
"""

from std.os import abort

from core.errors import Report, partial
from core.errors.codes import ErrBadAlphabet
from core.io import Byte

from .corrupt import _corrupt

comptime STD_PADDING = Int32(ord("="))
"""The padding character RFC 4648 asks for. Go's `StdPadding`."""

comptime NO_PADDING = Int32(-1)
"""Padding turned off. Go's `NoPadding`."""

comptime _INVALID = Byte(0xFF)
"""What a decode table slot holds when the byte is not in the alphabet."""

comptime _CR = Byte(ord("\r"))
"""A carriage return, skipped wherever a decoder meets one."""

comptime _LF = Byte(ord("\n"))
"""A line feed, skipped wherever a decoder meets one."""

comptime _STD_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
"""The alphabet of RFC 4648 section 6, which is what base32 usually means."""

comptime _HEX_ALPHABET = "0123456789ABCDEFGHIJKLMNOPQRSTUV"
"""The extended hex alphabet of RFC 4648 section 7, used in DNSSEC."""


struct Encoding(Copyable, Movable):
    """A radix 32 encoding scheme. Go's `Encoding`.

    ```mojo
    from core.encoding.base32 import std_encoding

    def main():
        print(std_encoding().encode_to_string("hello".as_bytes()))
    ```

    A value rather than a pointer to one, the same as the base64 `Encoding`.
    It is 292 bytes of tables and no allocation, so building one per call costs
    a memcpy rather than a heap trip.
    """

    var _encode: InlineArray[Byte, 32]
    """Symbol index to symbol byte. Go's `encode`."""

    var _decode_map: InlineArray[Byte, 256]
    """Symbol byte to symbol index, `_INVALID` for the 224 that are not one."""

    var _pad: Int32
    """The padding character, or `NO_PADDING`. Go's `padChar`."""

    def __init__(out self, alphabet: StringSlice) raises:
        """The encoding over `alphabet`, padded with `STD_PADDING`.

        `new_encoding` is the name Go gives this and the one to reach for.

        `alphabet` is 32 bytes, treated as bytes and not as characters, with no
        duplicates and no carriage return or line feed. Go panics on each of
        those and this raises `ErrBadAlphabet`, deviations.md has the row. The
        padding character is not checked against the alphabet here for the
        reason Go gives: the caller may be about to change it.
        """
        self._encode = InlineArray[Byte, 32](fill=0)
        self._decode_map = InlineArray[Byte, 256](fill=_INVALID)
        self._pad = STD_PADDING

        var symbols = alphabet.as_bytes()
        if len(symbols) != 32:
            raise (
                Report("base32: encoding alphabet is not 32 bytes long")
                .with_code(ErrBadAlphabet)
                .with_count(len(symbols))
                .error()
            )
        for i in range(32):
            var symbol = symbols[i]
            if symbol == _LF or symbol == _CR:
                raise (
                    Report("base32: encoding alphabet contains a newline")
                    .with_code(ErrBadAlphabet)
                    .with_field("at", String(i))
                    .error()
                )
            if self._decode_map[Int(symbol)] != _INVALID:
                raise (
                    Report("base32: encoding alphabet has a duplicate symbol")
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
        than as its UTF-8 encoding, which is Go's rule.
        """
        if (
            padding < NO_PADDING
            or padding == Int32(ord("\r"))
            or padding == Int32(ord("\n"))
            or padding > 0xFF
        ):
            raise (
                Report("base32: invalid padding character")
                .with_code(ErrBadAlphabet)
                .with_field("padding", String(padding))
                .error()
            )
        if padding != NO_PADDING and self._decode_map[Int(padding)] != _INVALID:
            raise (
                Report("base32: padding character is in the alphabet")
                .with_code(ErrBadAlphabet)
                .with_field("padding", String(padding))
                .error()
            )
        var next = self.copy()
        next._pad = padding
        return next^

    def encoded_len(self, n: Int) -> Int:
        """How many bytes `encode` writes for `n` bytes of input.

        Go's `EncodedLen`. Padded, that is the next multiple of eight;
        unpadded, it is one character per five bits with the last one rounded
        up.
        """
        if self._pad == NO_PADDING:
            return n // 5 * 8 + (n % 5 * 8 + 4) // 5
        return (n + 4) // 5 * 8

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
        returns one.

        The caller has to have made room. A `dst` shorter than `encoded_len` is
        a bounds failure from the span rather than a short write.

        The output is padded to a multiple of eight, so this is not the call
        for one block of a larger stream. `new_encoder` is.
        """
        if len(src) == 0:
            return 0

        var di = 0
        var si = 0
        var n = len(src) // 5 * 5
        while si < n:
            # Two 32 bit loads rather than one 64 bit one, which is Go's
            # arrangement and gives the same code on a 32 bit machine.
            var hi = (
                (UInt32(src[si]) << 24)
                | (UInt32(src[si + 1]) << 16)
                | (UInt32(src[si + 2]) << 8)
                | UInt32(src[si + 3])
            )
            var lo = (hi << 8) | UInt32(src[si + 4])

            dst[di] = self._encode[Int((hi >> 27) & 0x1F)]
            dst[di + 1] = self._encode[Int((hi >> 22) & 0x1F)]
            dst[di + 2] = self._encode[Int((hi >> 17) & 0x1F)]
            dst[di + 3] = self._encode[Int((hi >> 12) & 0x1F)]
            dst[di + 4] = self._encode[Int((hi >> 7) & 0x1F)]
            dst[di + 5] = self._encode[Int((hi >> 2) & 0x1F)]
            dst[di + 6] = self._encode[Int((lo >> 5) & 0x1F)]
            dst[di + 7] = self._encode[Int(lo & 0x1F)]

            si += 5
            di += 8

        var remain = len(src) - si
        if remain == 0:
            return di

        # The last one to four bytes, written from the back forwards because
        # each byte added to `val` only affects the characters below it.
        var val = UInt32(0)
        if remain == 4:
            val |= UInt32(src[si + 3])
            dst[di + 6] = self._encode[Int((val << 3) & 0x1F)]
            dst[di + 5] = self._encode[Int((val >> 2) & 0x1F)]
        if remain >= 3:
            val |= UInt32(src[si + 2]) << 8
            dst[di + 4] = self._encode[Int((val >> 7) & 0x1F)]
        if remain >= 2:
            val |= UInt32(src[si + 1]) << 16
            dst[di + 3] = self._encode[Int((val >> 12) & 0x1F)]
            dst[di + 2] = self._encode[Int((val >> 17) & 0x1F)]
        val |= UInt32(src[si]) << 24
        dst[di + 1] = self._encode[Int((val >> 22) & 0x1F)]
        dst[di] = self._encode[Int((val >> 27) & 0x1F)]

        var characters = remain * 8 // 5 + 1
        if self._pad == NO_PADDING:
            return di + characters
        for i in range(characters, 8):
            dst[di + i] = Byte(self._pad)
        return di + 8

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
        """`src` encoded, as a `String`. Go's `EncodeToString`."""
        var out = List[Byte](capacity=self.encoded_len(len(src)))
        _ = self.append_encode(out, src)
        return String(from_utf8_lossy=out)

    def decode[
        do: Origin[mut=True], so: Origin
    ](self, dst: Span[Byte, do], src: Span[Byte, so]) raises -> Int:
        """Decode `src` into `dst` and say how many bytes came out.

        Go's `Decode` returns a count and an error together. Here a refusal
        raises, the count is on `errors.partial`, and the bytes counted are
        already in `dst`.

        The caller has to have made room, `decoded_len` says how much.

        Carriage returns and line feeds are skipped anywhere they appear. They
        are taken out into a buffer of their own first, which is what Go does
        and is why the offset on a failure counts characters rather than input
        bytes: with newlines in it, the two are different numbers and the one
        worth having is the one that says which symbol was wrong.
        """
        var stripped = List[Byte](capacity=len(src))
        for b in src:
            if b != _CR and b != _LF:
                stripped.append(b)
        var n, _ = self._decode(dst, Span(stripped))
        return n

    def append_decode[
        so: Origin
    ](self, mut dst: List[Byte], src: Span[Byte, so]) raises -> Int:
        """Decode `src` onto the end of `dst`, and say how many bytes came out.

        Go's `AppendDecode` returns the grown slice and, on a malformed input,
        the partially decoded one alongside the error. Both halves are here:
        `dst` ends up holding exactly what was decoded either way, and the
        count comes back from a good decode and off `errors.partial` from a bad
        one.
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

    def _decode[
        do: Origin[mut=True], so: Origin
    ](self, dst: Span[Byte, do], src: Span[Byte, so]) raises -> Tuple[
        Int, Bool
    ]:
        """Go's private `decode`: the count, and whether the input ended.

        `src` has already had its newlines taken out. The second half of the
        answer is what Go calls `end`, meaning a padded quantum closed the
        document, and it is the reason this is a separate function: a stream
        decoder has to refuse anything that arrives after that point and the
        public `decode` has nowhere to put the flag.

        The offsets on a refusal are Go's offsets, worked out the same way from
        how much of the input is left.
        """
        var dsti = 0
        var olen = len(src)
        var si = 0
        var n = 0
        var end = False

        while si < len(src) and not end:
            var dbuf = InlineArray[Byte, 8](fill=0)
            var dlen = 8

            var j = 0
            while j < 8:
                if si == len(src):
                    if self._pad != NO_PADDING:
                        # The end of the input, with the padding missing.
                        raise _corrupt(olen - j, n)
                    dlen = j
                    end = True
                    break

                var c = src[si]
                si += 1
                var left = len(src) - si

                if Int32(c) == self._pad and j >= 2 and left < 8:
                    # The end of the input, with padding on it.
                    if left + j < 8 - 1:
                        raise _corrupt(olen, n)
                    for k in range(8 - 1 - j):
                        if left > k and Int32(src[si + k]) != self._pad:
                            raise _corrupt(olen - left + k - 1, n)
                    dlen = j
                    end = True
                    # RFC 4648 section 6 lists the five padding lengths that
                    # exist, so 1, 3 and 6 symbols are not a quantum: the 1st,
                    # 3rd and 6th characters of a group carry no whole byte
                    # between them. Section 9 draws it.
                    if dlen == 1 or dlen == 3 or dlen == 6:
                        raise _corrupt(olen - left - 1, n)
                    break

                dbuf[j] = self._decode_map[Int(c)]
                if dbuf[j] == _INVALID:
                    raise _corrupt(olen - left - 1, n)
                j += 1

            # Eight five bit symbols are five bytes, and `dlen` says how many
            # of them the input actually spelled. Anything else spells none.
            var written = 0
            if dlen == 8:
                written = 5
            elif dlen == 7:
                written = 4
            elif dlen == 5:
                written = 3
            elif dlen == 4:
                written = 2
            elif dlen == 2:
                written = 1

            if written >= 5:
                dst[dsti + 4] = (dbuf[6] << 5) | dbuf[7]
            if written >= 4:
                dst[dsti + 3] = (dbuf[4] << 7) | (dbuf[5] << 2) | (dbuf[6] >> 3)
            if written >= 3:
                dst[dsti + 2] = (dbuf[3] << 4) | (dbuf[4] >> 1)
            if written >= 2:
                dst[dsti + 1] = (dbuf[1] << 6) | (dbuf[2] << 1) | (dbuf[3] >> 4)
            if written >= 1:
                dst[dsti] = (dbuf[0] << 3) | (dbuf[1] >> 2)
            n += written
            dsti += 5

        return (n, end)


def new_encoding(alphabet: StringSlice) raises -> Encoding:
    """A padded encoding over `alphabet`. Go's `NewEncoding`.

    ```mojo
    from core.encoding.base32 import new_encoding

    def main():
        var crockford = new_encoding("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        print(crockford.encode_to_string("hello".as_bytes()))
    ```

    The alphabet is 32 bytes with no duplicates and no newline, and this raises
    `ErrBadAlphabet` where Go panics. `with_padding` changes or removes the
    padding character afterwards.
    """
    return Encoding(alphabet)


def std_encoding() -> Encoding:
    """The standard encoding of RFC 4648, padded. Go's `StdEncoding`.

    ```mojo
    from core.encoding.base32 import std_encoding

    def main():
        print(std_encoding().encode_to_string("hi".as_bytes()))  # NBUQ====
    ```
    """
    return _built(_STD_ALPHABET, STD_PADDING)


def hex_encoding() -> Encoding:
    """The extended hex alphabet of RFC 4648, padded. Go's `HexEncoding`.

    The symbols are `0` to `9` and `A` to `V`, in that order, so a set of
    encoded strings sorts into the same order as the bytes behind them. That is
    the whole point of it and the reason DNSSEC names NSEC3 records this way.
    """
    return _built(_HEX_ALPHABET, STD_PADDING)


def _built(alphabet: StringSlice, padding: Int32) -> Encoding:
    """One of the two above, from an alphabet the library wrote down itself.

    `new_encoding` and `with_padding` both raise, and the standard encodings
    would then be raising calls forever after over a failure no caller can
    cause. So this aborts on it instead, which is the same trade
    `big.must_set_string` makes and is only ever reached if this file's own two
    alphabet constants are wrong.
    """
    try:
        return Encoding(alphabet).with_padding(padding)
    except:
        abort("base32: a built in alphabet was refused")


def _decoded_len(n: Int, padding: Int32) -> Int:
    """`decoded_len` for an encoding that may not exist yet.

    Go has this as a free function because `AppendDecode` wants the unpadded
    answer from a padded encoding, to size a buffer for input whose padding it
    has already trimmed off.
    """
    if padding == NO_PADDING:
        return n // 8 * 5 + n % 8 * 5 // 8
    return n // 8 * 5
