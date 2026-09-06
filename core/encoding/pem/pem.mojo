"""The PEM container, blocks of base64 between two dashed lines.

The format is four lines of shape:

```text
-----BEGIN Type-----
Header: value
base64 of the bytes, wrapped at sixty four characters
-----END Type-----
```

It came out of Privacy Enhanced Mail, which nobody ever used, and outlived it
because it is the wrapper every TLS key and certificate arrives in. RFC 1421
describes it; almost nothing that writes PEM today implements the rest of that
document.

`decode` finds the first block in a document and hands back the rest, so a file
holding a certificate chain is read with a loop rather than a split. It is
deliberately forgiving: text before the first block, text between blocks and
text after the last one is skipped, which is why a certificate can be pasted
into the middle of a mail message and still be read out of it.
"""

from core.bytes import (
    cut,
    has_prefix,
    has_suffix,
    index,
    index_byte,
    last_index,
    trim_right,
    trim_space,
)
from core.bytes import new_buffer
from core.encoding.base64 import std_encoding
from core.errors import Report
from core.errors.codes import ErrHeaderKeyColon
from core.io import Byte, Writer as IoWriter
from core.sort import strings as sort_strings

comptime _PEM_START = "\n-----BEGIN "
"""The opening line, newline and all. Go's `pemStart`.

The newline is part of it because a block has to start at the beginning of a
line, and the one place that rule is relaxed is the very start of the document,
which is why almost every use of this drops the first byte.
"""

comptime _PEM_END = "\n-----END "
"""The closing line, newline and all. Go's `pemEnd`."""

comptime _PEM_END_OF_LINE = "-----"
"""The five dashes that finish both lines. Go's `pemEndOfLine`."""

comptime _LINE_LENGTH = 64
"""How many base64 characters go on a line. Go's `pemLineLength`."""

comptime _PROC_TYPE = "Proc-Type"
"""The one header with an order rule. RFC 1421 section 4.6.1.1 puts it first."""

comptime _BLANKS = " \t"
"""What `_get_line` takes off the end of a line, and nothing else."""

comptime _COLON_TEXT = ":"
"""What separates a header key from its value."""

comptime _NEWLINE = Byte(ord("\n"))
"""What ends a line."""

comptime _RETURN = Byte(ord("\r"))
"""What comes before it in a document written on Windows."""

comptime _SPACE = Byte(ord(" "))
"""One of the two bytes `_remove_spaces_and_tabs` drops."""

comptime _TAB = Byte(ord("\t"))
"""The other one."""

comptime _COLON = Byte(ord(":"))
"""The byte a header key is refused for containing."""


struct Block(Copyable, Movable):
    """One PEM block: a type, some headers and the bytes. Go's `Block`.

    ```mojo
    from core.encoding.pem import Block, encode_to_memory

    def main():
        var b = Block("MESSAGE", List[UInt8](length=4, fill=0x41))
        print(String(from_utf8=Span(encode_to_memory(b))))
        # -----BEGIN MESSAGE-----
        # QUFBQQ==
        # -----END MESSAGE-----
    ```

    The bytes are what was between the two dashed lines, base64 decoded. For a
    certificate or a key that is a DER encoded ASN.1 structure, and reading it
    is somebody else's job.
    """

    var type: String
    """The word after `BEGIN`, such as `RSA PRIVATE KEY`. Go's `Type`."""

    var headers: Dict[String, String]
    """The `Key: value` lines between the opening line and the base64.

    Usually empty. They come from the encrypted private key format, where
    `Proc-Type` and `DEK-Info` say how the bytes were encrypted, and almost
    nothing else uses them.
    """

    var bytes: List[Byte]
    """The decoded contents. Go's `Bytes`."""

    def __init__(
        out self,
        var type: String,
        var headers: Dict[String, String],
        var bytes: List[Byte],
    ):
        self.type = type^
        self.headers = headers^
        self.bytes = bytes^

    def __init__(out self, var type: String, var bytes: List[Byte]):
        """A block with no headers, which is what a certificate is."""
        self.type = type^
        self.headers = Dict[String, String]()
        self.bytes = bytes^


def _text[o: Origin](data: Span[Byte, o]) -> Optional[String]:
    """`data` as a `String`, or nothing when it is not UTF-8.

    Go writes `string(data)` here and gets a string holding whatever bytes
    arrived. A Mojo `String` is UTF-8 by construction, so a type line or a
    header that is not UTF-8 has no `String` to become, and the block it
    belongs to is treated as one this cannot read.
    """
    try:
        return String(from_utf8=data)
    except:
        return None


def _get_line[
    o: Origin
](data: Span[Byte, o]) -> Tuple[
    Span[Byte, o].Immutable, Span[Byte, o].Immutable, Int
]:
    """The first line of `data`, the rest, and how many bytes were used.

    Go's `getLine`. The line comes back without its trailing whitespace and
    without the line ending, and both `\\r\\n` and a bare `\\n` end a line. The
    rest is always shorter than the argument, which is what makes the header
    loop in `decode` terminate.
    """
    var v = data.as_imm()
    var i = index_byte(v, _NEWLINE)
    var j = 0
    if i < 0:
        i = len(v)
        j = i
    else:
        j = i + 1
        if i > 0 and v[i - 1] == _RETURN:
            i -= 1
    return (trim_right(v[0:i], _BLANKS.as_bytes()), v[j : len(v)], j)


def _remove_spaces_and_tabs[o: Origin](data: Span[Byte, o]) -> List[Byte]:
    """A copy of `data` with every space and tab taken out.

    Go's `removeSpacesAndTabs`, which returns its argument unchanged when there
    is nothing to take out so that the common case costs nothing. There is no
    returning the argument here, because the answer is owned and the argument
    is borrowed, so the copy happens either way and the check for whether it is
    needed would only cost a second pass.

    Newlines are left in, because the base64 decoder skips those itself.
    """
    var out = List[Byte](capacity=len(data))
    for i in range(len(data)):
        var b = data[i]
        if b == _SPACE or b == _TAB:
            continue
        out.append(b)
    return out^


def decode[
    o: Origin
](data: Span[Byte, o]) -> Tuple[Optional[Block], Span[Byte, o].Immutable]:
    """The first block in `data`, and everything after it. Go's `Decode`.

    ```mojo
    from core.encoding.pem import decode

    def main():
        var doc = String(
            "-----BEGIN MESSAGE-----\\naGVsbG8=\\n-----END MESSAGE-----\\n"
        )
        var got = decode(doc.as_bytes())
        if got[0]:
            print(got[0].value().type)  # MESSAGE
        print(len(got[1]))  # 0, there was nothing after the block
    ```

    The two answers come back as a pair rather than as two names, because a
    `Block` holds a list and this library does not copy one of those without
    being asked. `got[0]` is the block and `got[1]` is the rest.

    Nothing comes back and the whole of `data` is handed back as the rest when
    there is no block in it, which is the condition a loop over a certificate
    chain stops on. A block has to start and end at the beginning of a line.

    Text this cannot read is skipped rather than refused, and the search
    carries on after the `END` line that failed, so one damaged block in a file
    does not hide the ones after it.
    """
    var whole = data.as_imm()
    var rest = whole
    var pem_start = _PEM_START.as_bytes()
    var pem_end = _PEM_END.as_bytes()
    var end_of_line = _PEM_END_OF_LINE.as_bytes()

    # Where to start the next attempt: just past the `END` line of the block
    # that was tried and rejected. Zero to begin with, so the first attempt
    # looks at the whole document.
    var end_trailer_index = 0
    while True:
        if end_trailer_index < 0 or end_trailer_index > len(rest):
            return (None, whole)
        rest = rest[end_trailer_index : len(rest)]

        # The first `END` line, and then the last `BEGIN` line before it. That
        # order is what lets a run of `BEGIN` lines with no `END` between them
        # be skipped in one pass rather than one per line, which is the fix for
        # the quadratic parse that was CVE-2022-24675.
        var end_index = index(rest, pem_end)
        if end_index < 0:
            return (None, whole)
        end_trailer_index = end_index + len(pem_end)
        var begin_index = last_index(
            rest[0:end_index], pem_start[1 : len(pem_start)]
        )
        if begin_index < 0 or (
            begin_index > 0 and rest[begin_index - 1] != _NEWLINE
        ):
            continue
        var skip = begin_index + len(pem_start) - 1
        rest = rest[skip : len(rest)]
        end_index -= skip
        end_trailer_index -= skip

        var opening = _get_line(rest)
        var type_line = opening[0]
        rest = opening[1]
        end_index -= opening[2]
        end_trailer_index -= opening[2]
        if not has_suffix(type_line, end_of_line):
            continue
        type_line = type_line[0 : len(type_line) - len(end_of_line)]
        var type_text = _text(type_line)
        if not type_text:
            continue

        var headers = Dict[String, String]()
        var readable = True
        while True:
            # This terminates because `_get_line` hands back something shorter
            # than it was given.
            if len(rest) == 0:
                return (None, whole)
            var got = _get_line(rest)
            var parts = cut(got[0], _COLON_TEXT.as_bytes())
            if not parts[2]:
                break
            var key = _text(trim_space(parts[0]))
            var value = _text(trim_space(parts[1]))
            if not key or not value:
                readable = False
                break
            headers[key.value()] = value.value()
            rest = got[1]
            end_index -= got[2]
            end_trailer_index -= got[2]
        if not readable:
            continue

        # With headers there has to be a blank line between them and the `END`
        # line, so the offset of that line cannot have gone negative.
        if len(headers) > 0 and end_index < 0:
            continue
        # Go indexes straight into `rest` here and would panic on a document
        # that made this run past the end. Nothing is known to, but a slice out
        # of range in Mojo is not a panic, so it is checked.
        if end_trailer_index < 0 or end_trailer_index > len(rest):
            continue

        # After the dashes of the closing line comes the same type again and
        # then five more dashes, and then nothing but whitespace.
        var end_trailer = rest[end_trailer_index : len(rest)]
        var trailer_len = len(type_line) + len(end_of_line)
        if len(end_trailer) < trailer_len:
            continue
        var rest_of_end_line = end_trailer[trailer_len : len(end_trailer)]
        end_trailer = end_trailer[0:trailer_len]
        if not has_prefix(end_trailer, type_line) or not has_suffix(
            end_trailer, end_of_line
        ):
            continue
        if len(_get_line(rest_of_end_line)[0]) != 0:
            continue

        var decoded = List[Byte]()
        if end_index > 0:
            var body = _remove_spaces_and_tabs(rest[0:end_index])
            var enc = std_encoding()
            var buf = List[Byte](length=enc.decoded_len(len(body)), fill=0)
            var written = 0
            var good = True
            try:
                written = enc.decode(Span(buf), Span(body))
            except:
                good = False
            if not good:
                continue
            buf.resize(written, 0)
            decoded = buf^

        var block = Block(type_text.value(), headers^, decoded^)
        # The minus one is because the `END` may have been matched without its
        # leading newline, which happens when the block held no bytes at all.
        var after = rest[end_index + len(pem_end) - 1 : len(rest)]
        return (Optional[Block](block^), _get_line(after)[1])


def _write_header[W: IoWriter](mut out: W, key: String, value: String) raises:
    """One `Key: value` line. Go's `writeHeader`."""
    var line = key + ": " + value + "\n"
    _ = out.write(line.as_bytes())


def encode[W: IoWriter](mut out: W, b: Block) raises:
    """Write `b` to `out` in PEM form. Go's `Encode`.

    The base64 is wrapped at sixty four characters, headers are written one to
    a line with `Proc-Type` first and the rest sorted by key, and there is a
    blank line between the headers and the body. Sorting is not in the format;
    it is here so that encoding the same block twice gives the same bytes,
    which a map iteration on its own would not.

    A header key with a colon in it raises `ErrHeaderKeyColon`, and it is
    checked before anything is written, so `out` is either left untouched or
    handed a whole block.
    """
    for k in b.headers.keys():
        if index_byte(k.as_bytes(), _COLON) >= 0:
            raise (
                Report("pem: cannot encode a header key that contains a colon")
                .with_code(ErrHeaderKeyColon)
                .error()
            )

    # Everything from here on can only fail because `out` did.
    var pem_start = _PEM_START.as_bytes()
    var pem_end = _PEM_END.as_bytes()
    _ = out.write(pem_start[1 : len(pem_start)])
    var opening = b.type + "-----\n"
    _ = out.write(opening.as_bytes())

    if len(b.headers) > 0:
        var others = List[String]()
        var has_proc_type = False
        for k in b.headers.keys():
            if k == _PROC_TYPE:
                has_proc_type = True
                continue
            others.append(k.copy())
        if has_proc_type:
            var proc = String(_PROC_TYPE)
            _write_header(out, proc, b.headers[proc])
        sort_strings(Span(others))
        for i in range(len(others)):
            _write_header(out, others[i], b.headers[others[i]])
        _ = out.write("\n".as_bytes())

    # Go runs the bytes through a streaming base64 encoder into a line breaker
    # that wraps at sixty four. The whole input is already in memory here, so
    # this encodes it in one call and cuts the result into lines, which is the
    # same output for a quarter of the moving parts.
    var body = std_encoding().encode_to_string(Span(b.bytes))
    var text = body.as_bytes()
    var at = 0
    while at < len(text):
        var stop = at + _LINE_LENGTH
        if stop > len(text):
            stop = len(text)
        _ = out.write(text[at:stop])
        _ = out.write("\n".as_bytes())
        at = stop

    _ = out.write(pem_end[1 : len(pem_end)])
    var closing = b.type + "-----\n"
    _ = out.write(closing.as_bytes())


def encode_to_memory(b: Block) raises -> List[Byte]:
    """`b` in PEM form, as bytes. Go's `EncodeToMemory`.

    Go returns nil when the block cannot be encoded and says in its own
    documentation to use `Encode` if the reason matters. This raises instead,
    so the reason always matters and there is no second function to reach for.
    """
    var buf = new_buffer(List[Byte]())
    encode(buf, b)
    return buf.bytes()
