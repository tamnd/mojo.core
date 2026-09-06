"""Writing blocks. Go's `TestEncode` and `TestBadEncode`.

Encoding is the short half of this package and almost all of it is decided
rather than computed: where the newlines go, which header is written first, and
what happens to the rest. The rows here are those decisions, one at a time.
"""

from std.testing import assert_equal, assert_true

from core.encoding.pem import Block, decode, encode, encode_to_memory
from core.errors import matches
from core.errors.codes import ErrHeaderKeyColon
from core.io import Byte
from core.strings import repeat

from ._fixtures import Sink, as_text, bytes_of


def test_encode() raises:
    """A block with no headers, which is what a certificate is."""
    var b = Block("MESSAGE", bytes_of("hello world"))
    assert_equal(
        as_text(encode_to_memory(b)),
        String(
            "-----BEGIN MESSAGE-----\naGVsbG8gd29ybGQ=\n-----END MESSAGE-----\n"
        ),
    )


def test_encode_of_no_bytes_writes_no_body() raises:
    """Two lines and nothing between them, which is a block `decode` reads."""
    var b = Block("EMPTY", List[Byte]())
    var text = as_text(encode_to_memory(b))
    assert_equal(text, String("-----BEGIN EMPTY-----\n-----END EMPTY-----\n"))

    var got = decode(text.as_bytes())
    assert_true(Bool(got[0]))
    assert_equal(got[0].value().type, "EMPTY")
    assert_equal(len(got[0].value().bytes), 0)


def test_encode_writes_proc_type_first_then_sorts() raises:
    """RFC 1421 section 4.6.1.1 puts `Proc-Type` first and says nothing about
    the rest.

    The sort of the rest is not in the format. It is here because a map has no
    order, and without it the same block would encode to different bytes on
    different runs, which is the sort of thing that turns a signature check
    into a coin toss.
    """
    var headers = Dict[String, String]()
    headers["Zed"] = "26"
    headers["Alpha"] = "1"
    headers["Proc-Type"] = "4,ENCRYPTED"
    headers["Mid"] = "13"
    var b = Block("KEY", headers^, bytes_of("hi"))
    assert_equal(
        as_text(encode_to_memory(b)),
        String(
            "-----BEGIN KEY-----\n"
            "Proc-Type: 4,ENCRYPTED\n"
            "Alpha: 1\n"
            "Mid: 13\n"
            "Zed: 26\n"
            "\n"
            "aGk=\n"
            "-----END KEY-----\n"
        ),
    )


def test_encode_wraps_the_body_at_sixty_four() raises:
    """Forty eight bytes are sixty four characters, and one more is a new line.

    Go runs the base64 through a line breaker as it is produced. This encodes
    the whole body first and cuts it up afterwards, so the boundary is the one
    thing worth checking on both sides of.
    """
    var line = repeat("QUFB", 16)
    var full = Block("A", List[Byte](length=48, fill=Byte(ord("A"))))
    assert_equal(
        as_text(encode_to_memory(full)),
        String("-----BEGIN A-----\n") + line + "\n-----END A-----\n",
    )

    var over = Block("A", List[Byte](length=49, fill=Byte(ord("A"))))
    assert_equal(
        as_text(encode_to_memory(over)),
        String("-----BEGIN A-----\n") + line + "\nQQ==\n-----END A-----\n",
    )


def test_encode_round_trips() raises:
    """What went in comes back out, headers and all."""
    var headers = Dict[String, String]()
    headers["Proc-Type"] = "4,ENCRYPTED"
    headers["DEK-Info"] = "DES-EDE3-CBC,80C7C7A09690757A"
    var b = Block("RSA PRIVATE KEY", headers^, bytes_of("hello world"))

    var text = as_text(encode_to_memory(b))
    var got = decode(text.as_bytes())
    assert_true(Bool(got[0]))
    assert_equal(got[0].value().type, "RSA PRIVATE KEY")
    assert_equal(len(got[0].value().headers), 2)
    assert_equal(got[0].value().headers["Proc-Type"], "4,ENCRYPTED")
    assert_equal(
        got[0].value().headers["DEK-Info"], "DES-EDE3-CBC,80C7C7A09690757A"
    )
    assert_equal(as_text(got[0].value().bytes), "hello world")
    assert_equal(len(got[1]), 0)


def test_bad_encode() raises:
    """Go's `TestBadEncode`: a colon in a header key, refused before anything
    is written.

    The order matters as much as the refusal. A header line is a key, a colon,
    a space and a value, so `X:Y` would read back as the key `X` with the value
    `Y: Z`, and the block would not survive a round trip. Checking first means
    the writer is either left untouched or handed a whole block, never half of
    one.
    """
    var headers = Dict[String, String]()
    headers["X:Y"] = "Z"
    var b = Block("BAD", headers^, List[Byte]())

    var sink = Sink()
    var refused = False
    try:
        encode(sink, b)
    except e:
        refused = True
        assert_true(matches(e, ErrHeaderKeyColon))
    assert_true(refused)
    assert_equal(len(sink.got), 0)
    assert_equal(sink.writes, 0)

    var also_refused = False
    try:
        _ = encode_to_memory(b)
    except e:
        also_refused = True
        assert_true(matches(e, ErrHeaderKeyColon))
    assert_true(also_refused)


def test_a_colon_in_a_value_is_fine() raises:
    """Only the key is refused, because only the key is ambiguous."""
    var headers = Dict[String, String]()
    headers["DEK-Info"] = "a:b:c"
    var b = Block("A", headers^, bytes_of("hi"))
    var text = as_text(encode_to_memory(b))

    var got = decode(text.as_bytes())
    assert_true(Bool(got[0]))
    assert_equal(got[0].value().headers["DEK-Info"], "a:b:c")


def test_encode_stops_where_the_writer_stops() raises:
    """A failure from the writer is the caller's failure, not this package's.

    The second write is the type line, so a writer that refuses it has already
    taken the opening dashes and gets nothing after them.
    """
    var sink = Sink(nth=2)
    var b = Block("MESSAGE", bytes_of("hello world"))
    var refused = False
    try:
        encode(sink, b)
    except:
        refused = True
    assert_true(refused)
    assert_equal(sink.text(), "-----BEGIN ")


def test_the_message_is_gos() raises:
    """Word for word, because a message is an interface too."""
    var headers = Dict[String, String]()
    headers["X:Y"] = "Z"
    var b = Block("BAD", headers^, List[Byte]())
    var said = String()
    try:
        _ = encode_to_memory(b)
    except e:
        said = String(e)
    assert_equal(said, "pem: cannot encode a header key that contains a colon")
