"""The document the decoding tests are read against, and two conversions.

`document` is Go's `pemData` with the two long bodies cut down. Every
structural oddity in Go's fixture is kept, in order and byte for byte: the line
of text before the first block, the four `BEGIN CERTIFICATE` lines with no
`END` between them, the indented one that does not start at the beginning of a
line, the text between the blocks, the three empty blocks written three
different ways, the headers with no blank line after them that make a block
unreadable, and the ones with a blank line that do not. What is gone is the
four kilobyte certificate and the thirteen line encrypted key, which are two
long base64 bodies and are the one thing in that fixture the decoder has
nothing special to say about.
"""

from core.errors import Report
from core.errors.codes import EOF
from core.io import Byte, Writer


def as_text(data: List[Byte]) raises -> String:
    """`data` as a string, for an assertion that prints something readable."""
    return String(from_utf8=Span(data))


def bytes_of(s: String) -> List[Byte]:
    """`s` as a list, which is what the calls here take."""
    var out = List[Byte]()
    for b in s.as_bytes():
        out.append(b)
    return out^


def document() -> String:
    """Go's `pemData`, shortened. Six readable blocks and a lot of noise."""
    return String(
        "verify return:0\n"
        "-----BEGIN CERTIFICATE-----\n"
        "sdlfkjskldfj\n"
        "  -----BEGIN CERTIFICATE-----\n"
        "---\n"
        "Certificate chain\n"
        " 0 s:/C=AU/ST=Somewhere/L=Someplace/O=Foo Bar/CN=foo.example.com\n"
        "   i:/C=ZA/O=CA Inc./CN=CA Inc\n"
        "-----BEGIN CERTIFICATE-----\n"
        "testing\n"
        "-----BEGIN CERTIFICATE-----\n"
        "-----BEGIN CERTIFICATE-----\n"
        "aGVsbG8gd29ybGQ=\n"
        "-----END CERTIFICATE-----\n"
        " 1 s:/C=ZA/O=Ca Inc./CN=CA Inc\n"
        "\n"
        "-----BEGIN RSA PRIVATE KEY-----\n"
        "Proc-Type: 4,ENCRYPTED\n"
        "DEK-Info: DES-EDE3-CBC,80C7C7A09690757A\n"
        "\n"
        "eQp5ZkH6CyHBz7BZfUPxyLCC\n"
        "-----END RSA PRIVATE KEY-----\n"
        "\n"
        "\n"
        "-----BEGIN EMPTY-----\n"
        "-----END EMPTY-----\n"
        "\n"
        "-----BEGIN EMPTY-----\n"
        "\n"
        "-----END EMPTY-----\n"
        "\n"
        "-----BEGIN EMPTY-----\n"
        "\n"
        "\n"
        "-----END EMPTY-----\n"
        "\n"
        "# This shouldn't be recognised because of the missing newline after"
        " the\n"
        "headers.\n"
        "-----BEGIN INVALID HEADERS-----\n"
        "Header: 1\n"
        "-----END INVALID HEADERS-----\n"
        "\n"
        "# This should be valid, however.\n"
        "-----BEGIN VALID HEADERS-----\n"
        "Header: 1\n"
        "\n"
        "-----END VALID HEADERS-----"
    )


struct Sink(Copyable, Movable, Writer):
    """A writer that refuses the `nth` call and keeps everything before it.

    Go's `Encode` returns whatever the writer returned and stops there, and the
    only way to see that it stopped in the right place is to have a writer that
    can fail on purpose.
    """

    var got: List[Byte]
    var writes: Int
    var nth: Int

    def __init__(out self, nth: Int = -1):
        self.got = List[Byte]()
        self.writes = 0
        self.nth = nth

    def write[o: Origin](mut self, data: Span[Byte, o]) raises -> Int:
        self.writes += 1
        if self.writes == self.nth:
            raise Report("sink: refused").with_code(EOF).error()
        for b in data:
            self.got.append(b)
        return len(data)

    def text(self) raises -> String:
        return String(from_utf8=Span(self.got))
