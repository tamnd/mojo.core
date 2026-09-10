"""The table a Huffman code is decoded through. Go's `huffmanDecoder`.

The shape is zlib's and Go took it from there. There is one flat table of a
fixed width, nine bits, indexed by the next nine bits of the stream read
backwards, and every entry packs two numbers into a `UInt32`: the low four bits
say how many bits the code actually was, and the rest says what it decoded to.
A code shorter than nine bits fills every entry whose low bits match it, so one
lookup answers whatever the following bits happen to be, and the length in the
entry says how many to consume.

A code longer than nine bits cannot fit that way, so its entry in the flat
table is a link instead: the value half is an index into `links`, and the bits
above the ninth pick the row of that overflow table. The count half of a link
entry is ten, one more than the table is wide, which is what tells a lookup it
is looking at a link rather than at an answer.

The lookup works on an incomplete read, which is the property that makes the
whole arrangement worth having. DEFLATE writes codes least significant bit
first and shorter codes sort before longer ones, so the bits not yet read are
zero and the entry they land on still reports a length that is no larger than
the real one. The decompressor uses that to know how many more bits to pull.
"""

from core.math.bits import reverse16

comptime _MAX_CODE_LEN = 16
"""The longest Huffman code RFC 1951 allows, in bits."""

comptime _MAX_NUM_LIT = 286
"""Literal and length codes. RFC 1951 section 3.2.7."""

comptime _MAX_NUM_DIST = 30
"""Distance codes. Section 3.2.5 rules out codes 30 and 31, so 30 is the
count."""

comptime _NUM_CODES = 19
"""Codes in the meta code that describes the other two."""

comptime _CHUNK_BITS = 9
"""Width of the flat table, in bits."""

comptime _NUM_CHUNKS = 1 << _CHUNK_BITS
"""Entries in the flat table."""

comptime _COUNT_MASK = UInt32(15)
"""The low bits of an entry, which hold the code length."""

comptime _VALUE_SHIFT = 4
"""How far up an entry the decoded value sits."""


struct _HuffmanDecoder(Movable):
    """One Huffman code, in the form a lookup can use."""

    var min: Int
    """The shortest code in the table, which is how many bits a lookup needs
    before it can say anything at all. Zero means the table is empty."""

    var chunks: InlineArray[UInt32, _NUM_CHUNKS]
    """The flat table. An entry is `value << 4 | length`, and zero is never a
    valid entry because a length is between one and fifteen."""

    var links: List[List[UInt32]]
    """Overflow tables for codes longer than nine bits, one per flat entry that
    is a link."""

    var link_mask: UInt32
    """Masks the bits above the ninth down to a row of an overflow table."""

    def __init__(out self):
        self.min = 0
        self.chunks = InlineArray[UInt32, _NUM_CHUNKS](fill=0)
        self.links = List[List[UInt32]]()
        self.link_mask = 0

    def build[o: ImmOrigin](mut self, lengths: Span[Int, o]) -> Bool:
        """Fill the tables from a list of code lengths. Go's `init`.

        `lengths[i]` is how many bits symbol `i` was given, and zero means the
        symbol does not appear. False comes back when those lengths do not
        describe a complete tree, which RFC 1951 requires and which a corrupt
        stream is how you meet.

        One incomplete tree is accepted anyway, a single symbol of length one,
        because zlib writes it and Go accepts it for that reason. An empty
        tree is accepted too and fails later at the first lookup, which is
        where it has to fail: an empty distance tree is legal in a block that
        never uses a distance.
        """
        if self.min != 0:
            self.min = 0
            for i in range(_NUM_CHUNKS):
                self.chunks[i] = 0
            self.links = List[List[UInt32]]()
            self.link_mask = 0

        var count = InlineArray[Int, _MAX_CODE_LEN](fill=0)
        var low = 0
        var high = 0
        for i in range(len(lengths)):
            var n = lengths[i]
            if n == 0:
                continue
            if low == 0 or n < low:
                low = n
            if n > high:
                high = n
            count[n] += 1

        # An empty tree. Legal for the distance code of a block that has no
        # backward copies in it, and a lookup on one refuses, which is what
        # makes an empty literal tree a corrupt stream rather than a hang.
        if high == 0:
            return True

        var code = 0
        var next_code = InlineArray[Int, _MAX_CODE_LEN](fill=0)
        for i in range(low, high + 1):
            code <<= 1
            next_code[i] = code
            code += count[i]

        # Every bit pattern of the longest length has to be spoken for. Fewer
        # means a symbol would decode to nothing, more means two symbols would
        # decode to the same bits, and neither is a tree.
        if code != (1 << high) and not (code == 1 and high == 1):
            return False

        self.min = low
        if high > _CHUNK_BITS:
            var num_links = 1 << (high - _CHUNK_BITS)
            self.link_mask = UInt32(num_links - 1)

            var link = next_code[_CHUNK_BITS + 1] >> 1
            for _ in range(_NUM_CHUNKS - link):
                self.links.append(List[UInt32](length=num_links, fill=0))
            for j in range(link, _NUM_CHUNKS):
                var rev = Int(reverse16(UInt16(j))) >> (16 - _CHUNK_BITS)
                var off = j - link
                self.chunks[rev] = UInt32(
                    off << _VALUE_SHIFT | (_CHUNK_BITS + 1)
                )

        for i in range(len(lengths)):
            var n = lengths[i]
            if n == 0:
                continue
            var c = next_code[n]
            next_code[n] += 1
            var chunk = UInt32(i << _VALUE_SHIFT | n)
            var rev = Int(reverse16(UInt16(c))) >> (16 - n)
            if n <= _CHUNK_BITS:
                var off = rev
                while off < _NUM_CHUNKS:
                    self.chunks[off] = chunk
                    off += 1 << n
            else:
                var j = rev & (_NUM_CHUNKS - 1)
                var value = Int(self.chunks[j] >> _VALUE_SHIFT)
                var off = rev >> _CHUNK_BITS
                while off < len(self.links[value]):
                    self.links[value][off] = chunk
                    off += 1 << (n - _CHUNK_BITS)

        return True


def _fixed_decoder() -> _HuffmanDecoder:
    """The literal and length code every fixed Huffman block uses.

    RFC 1951 section 3.2.6 writes it out as four runs of lengths and this is
    those four runs. Go builds it once into a package variable behind a
    `sync.Once`; here it is built per decompressor, because a package variable
    is shared mutable state and building this is a few hundred stores against
    a decompression that will do far more than that.
    """
    var lengths = List[Int](length=288, fill=0)
    for i in range(0, 144):
        lengths[i] = 8
    for i in range(144, 256):
        lengths[i] = 9
    for i in range(256, 280):
        lengths[i] = 7
    for i in range(280, 288):
        lengths[i] = 8
    var h = _HuffmanDecoder()
    _ = h.build(Span(lengths))
    return h^
