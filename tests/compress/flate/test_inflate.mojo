"""Reading DEFLATE streams somebody else wrote.

Go's `TestStreams` is the heart of this file and it is the reason the reader
half of this package is worth shipping before the writer half. Twenty nine hex
strings, most of them malformed, each one a way a Huffman table description can
be wrong that somebody found by fuzzing a decompressor until it crashed. Ten of
them are legal and the other nineteen have to be refused rather than crashed
on, and three carry a Go issue number in their description because that is what
they were.

The rest of the file is the same question asked in other ways: a stream cut off
at every possible point, a stream whose table claims more literal codes than
RFC 1951 allows, and streams from an encoder that is not Go's. The last of
those matter because a decompressor tested only against its own writer tests
that the two agree, not that either is right, and there is no writer here yet
anyway. Those streams come from zlib, through Python's `zlib` module at the
levels named beside each one, and the comment above each says how to make it
again.
"""

from std.testing import assert_equal, assert_true

from core.compress.flate import new_reader, new_reader_dict
from core.errors.codes import EOF, ErrUnexpectedEOF
from core.io import Byte, read_all

from ._fixtures import Bytes, Drip, as_bytes, as_hex, drain, unhex


struct _Stream(Copyable, Movable):
    """One row of Go's `TestStreams`."""

    var desc: String
    """What is wrong with it, or what is unusual about it."""

    var stream: String
    """The DEFLATE stream, in hex."""

    var want: String
    """What it decompresses to, in hex."""

    var fails: Bool
    """Whether it has to be refused. Go writes this as `want` being the string
    "fail", which is a value the hex column could in principle hold."""

    def __init__(out self, desc: String, stream: String, want: String):
        self.desc = desc
        self.stream = stream
        self.want = want
        self.fails = False

    @staticmethod
    def bad(desc: String, stream: String) -> Self:
        var s = Self(desc, stream, "")
        s.fails = True
        return s^


def _streams() -> List[_Stream]:
    """Go's `testCases` from `TestStreams`, in Go's order.

    Go's comment on the table says how to check a row against C zlib, and it is
    worth repeating: `zlib.decompress(bytes.fromhex(s), -15)` in Python, where
    the negative window size means raw DEFLATE with no header.
    """
    var t = List[_Stream]()
    t.append(
        _Stream.bad(
            "degenerate HCLenTree",
            (
                "05e0010000000000100000000000000000000000000000000000000000000000"
                "00000000000000000004"
            ),
        )
    )
    t.append(
        _Stream.bad(
            "complete HCLenTree, empty HLitTree, empty HDistTree",
            (
                "05e0010400000000000000000000000000000000000000000000000000000000"
                "00000000000000000010"
            ),
        )
    )
    t.append(
        _Stream.bad(
            "empty HCLenTree",
            (
                "05e0010000000000000000000000000000000000000000000000000000000000"
                "00000000000000000010"
            ),
        )
    )
    t.append(
        _Stream.bad(
            (
                "complete HCLenTree, complete HLitTree, empty HDistTree, use"
                " missing HDist symbol"
            ),
            (
                "000100feff000de0010400000000100000000000000000000000000000000000"
                "0000000000000000000000000000002c"
            ),
        )
    )
    t.append(
        _Stream.bad(
            (
                "complete HCLenTree, complete HLitTree, degenerate HDistTree,"
                " use missing HDist symbol"
            ),
            (
                "000100feff000de0010000000000000000000000000000000000000000000000"
                "00000000000000000610000000004070"
            ),
        )
    )
    t.append(
        _Stream.bad(
            "complete HCLenTree, empty HLitTree, empty HDistTree",
            (
                "05e0010400000000100400000000000000000000000000000000000000000000"
                "0000000000000000000000000008"
            ),
        )
    )
    t.append(
        _Stream.bad(
            "complete HCLenTree, empty HLitTree, degenerate HDistTree",
            (
                "05e0010400000000100400000000000000000000000000000000000000000000"
                "0000000000000000000800000008"
            ),
        )
    )
    t.append(
        _Stream.bad(
            (
                "complete HCLenTree, degenerate HLitTree, degenerate HDistTree,"
                " use missing HLit symbol"
            ),
            (
                "05e0010400000000100000000000000000000000000000000000000000000000"
                "0000000000000000001c"
            ),
        )
    )
    t.append(
        _Stream.bad(
            "complete HCLenTree, complete HLitTree, too large HDistTree",
            (
                "edff870500000000200400000000000000000000000000000000000000000000"
                "000000000000000000080000000000000004"
            ),
        )
    )
    t.append(
        _Stream.bad(
            (
                "complete HCLenTree, complete HLitTree, empty HDistTree,"
                " excessive repeater code"
            ),
            (
                "edfd870500000000200400000000000000000000000000000000000000000000"
                "000000000000000000e8b100"
            ),
        )
    )
    t.append(
        _Stream(
            (
                "complete HCLenTree, complete HLitTree, empty HDistTree of"
                " normal length 30"
            ),
            (
                "05fd01240000000000f8ffffffffffffffffffffffffffffffffffffffffffff"
                "ffffffffffffffffff07000000fe01"
            ),
            "",
        )
    )
    t.append(
        _Stream.bad(
            (
                "complete HCLenTree, complete HLitTree, empty HDistTree of"
                " excessive length 31"
            ),
            (
                "05fe01240000000000f8ffffffffffffffffffffffffffffffffffffffffffff"
                "ffffffffffffffffff07000000fc03"
            ),
        )
    )
    t.append(
        _Stream.bad(
            "complete HCLenTree, over-subscribed HLitTree, empty HDistTree",
            (
                "05e001240000000000fcffffffffffffffffffffffffffffffffffffffffffff"
                "ffffffffffffffffff07f00f"
            ),
        )
    )
    t.append(
        _Stream.bad(
            "complete HCLenTree, under-subscribed HLitTree, empty HDistTree",
            (
                "05e001240000000000fcffffffffffffffffffffffffffffffffffffffffffff"
                "fffffffffcffffffff07f00f"
            ),
        )
    )
    t.append(
        _Stream(
            (
                "complete HCLenTree, complete HLitTree with single code, empty"
                " HDistTree"
            ),
            (
                "05e001240000000000f8ffffffffffffffffffffffffffffffffffffffffffff"
                "ffffffffffffffffff07f00f"
            ),
            "01",
        )
    )
    t.append(
        _Stream(
            (
                "complete HCLenTree, complete HLitTree with multiple codes,"
                " empty HDistTree"
            ),
            (
                "05e301240000000000f8ffffffffffffffffffffffffffffffffffffffffffff"
                "ffffffffffffffffff07807f"
            ),
            "01",
        )
    )
    t.append(
        _Stream(
            (
                "complete HCLenTree, complete HLitTree, degenerate HDistTree,"
                " use valid HDist symbol"
            ),
            (
                "000100feff000de0010400000000100000000000000000000000000000000000"
                "0000000000000000000000000000003c"
            ),
            "00000000",
        )
    )
    t.append(
        _Stream(
            "complete HCLenTree, degenerate HLitTree, degenerate HDistTree",
            (
                "05e0010400000000100000000000000000000000000000000000000000000000"
                "0000000000000000000c"
            ),
            "",
        )
    )
    t.append(
        _Stream(
            "complete HCLenTree, degenerate HLitTree, empty HDistTree",
            (
                "05e0010400000000100000000000000000000000000000000000000000000000"
                "00000000000000000004"
            ),
            "",
        )
    )
    t.append(
        _Stream(
            (
                "complete HCLenTree, complete HLitTree, empty HDistTree,"
                " spanning repeater code"
            ),
            (
                "edfd870500000000200400000000000000000000000000000000000000000000"
                "000000000000000000e8b000"
            ),
            "",
        )
    )
    t.append(
        _Stream(
            (
                "complete HCLenTree with length codes, complete HLitTree, empty"
                " HDistTree"
            ),
            (
                "ede0010400000000100000000000000000000000000000000000000000000000"
                "0000000000000000000400004000"
            ),
            "",
        )
    )
    t.append(
        _Stream(
            (
                "complete HCLenTree, complete HLitTree, degenerate HDistTree,"
                " use valid HLit symbol 284 with count 31"
            ),
            (
                "000100feff00ede0010400000000100000000000000000000000000000000000"
                "000000000000000000000000000000040000407f00"
            ),
            (
                "0000000000000000000000000000000000000000000000000000000000000000"
                "0000000000000000000000000000000000000000000000000000000000000000"
                "0000000000000000000000000000000000000000000000000000000000000000"
                "0000000000000000000000000000000000000000000000000000000000000000"
                "0000000000000000000000000000000000000000000000000000000000000000"
                "0000000000000000000000000000000000000000000000000000000000000000"
                "0000000000000000000000000000000000000000000000000000000000000000"
                "0000000000000000000000000000000000000000000000000000000000000000"
                "000000"
            ),
        )
    )
    t.append(
        _Stream(
            (
                "complete HCLenTree, complete HLitTree, degenerate HDistTree,"
                " use valid HLit and HDist symbols"
            ),
            "0cc2010d00000082b0ac4aff0eb07d27060000ffff",
            "616263616263",
        )
    )
    t.append(_Stream.bad("fixed block, use reserved symbol 287", "33180700"))
    t.append(_Stream("raw block", "010100feff11", "11"))
    t.append(
        _Stream.bad(
            "issue 10426 - over-subscribed HCLenTree causes a hang",
            "344c4a4e494d4b070000ff2e2eff2e2e2e2e2eff",
        )
    )
    t.append(
        _Stream(
            "issue 11030 - empty HDistTree unexpectedly leads to error",
            "05c0070600000080400fff37a0ca",
            "",
        )
    )
    t.append(
        _Stream(
            "issue 11033 - empty HDistTree unexpectedly leads to error",
            (
                "050fb109c020cca5d017dcbca044881ee1034ec149c8980bbc413c2ab35be9dc"
                "b1473449922449922411202306ee97b0383a521b4ffdcf3217f9f7d3adb701"
            ),
            (
                "3130303634342068652e706870005d05355f7ed957ff084a90925d19e3ebc6d0"
                "c6d7"
            ),
        )
    )
    return t^


def test_streams() raises:
    """Go's `TestStreams`, read in as few calls as the reader will make."""
    var rows = _streams()
    for i in range(len(rows)):
        var r = new_reader(Bytes(unhex(rows[i].stream)))
        var got = drain(r)
        if rows[i].fails:
            assert_true(
                not got.stopped_on(EOF),
                String("row ", i, " (", rows[i].desc, ") was accepted"),
            )
        else:
            assert_true(
                got.stopped_on(EOF),
                String("row ", i, " (", rows[i].desc, ") was refused"),
            )
            assert_equal(as_hex(got.data), rows[i].want, rows[i].desc)


def test_streams_one_byte_at_a_time() raises:
    """The same corpus through a reader that hands over one byte per call.

    Every state in the decompressor can be interrupted between two bytes, and
    the resumption paths are the half of the machine that the ordinary case
    never reaches. Running the whole corpus twice is cheap and this is the only
    thing that reaches them.
    """
    var rows = _streams()
    for i in range(len(rows)):
        var r = new_reader(Drip(unhex(rows[i].stream)))
        var got = drain(r)
        if rows[i].fails:
            assert_true(
                not got.stopped_on(EOF),
                String("row ", i, " (", rows[i].desc, ") was accepted"),
            )
        else:
            assert_true(
                got.stopped_on(EOF),
                String("row ", i, " (", rows[i].desc, ") was refused"),
            )
            assert_equal(as_hex(got.data), rows[i].want, rows[i].desc)


def test_truncated_streams() raises:
    """Go's `TestTruncatedStreams`: one stored block, cut at every offset.

    Every prefix short of the whole thing has to raise `ErrUnexpectedEOF`,
    which is the difference between a stream that ended and a stream that
    stopped. There is no such thing as a DEFLATE stream that ends without
    saying so, so the end of input is never the end of the stream.
    """
    var whole = unhex("000c00f3ff68656c6c6f2c20776f726c64010000ffff")
    for cut in range(len(whole)):
        var head = List[Byte](Span(whole)[0:cut])
        var r = new_reader(Bytes(head^))
        var got = drain(r)
        assert_true(
            got.stopped_on(ErrUnexpectedEOF),
            String("cut at ", cut, " did not stop on ErrUnexpectedEOF"),
        )


def test_reader_truncated() raises:
    """Go's `TestReaderTruncated`: what a cut off stream produced first.

    The bytes before the cut are output and have to come out, because a caller
    reading a stream in pieces has already been handed them. This is the table
    that says the failure arrives after the good bytes rather than instead of
    them.
    """
    var inputs: List[String] = [
        "00",
        "000c",
        "000c00",
        "000c00f3ff",
        "000c00f3ff68656c6c6f",
        "000c00f3ff68656c6c6f2c20776f726c64",
        "02",
        "f248cd",
        "f248cd993061c28409",
        "f248cd993061c2840900",
    ]
    var outputs: List[String] = [
        "",
        "",
        "",
        "",
        "68656c6c6f",
        "68656c6c6f2c20776f726c64",
        "",
        "4865",
        "48656c9090909090",
        "48656c9090909090",
    ]
    for i in range(len(inputs)):
        var r = new_reader(Bytes(unhex(inputs[i])))
        var got = drain(r)
        assert_true(
            got.stopped_on(ErrUnexpectedEOF),
            String("row ", i, " did not stop on ErrUnexpectedEOF"),
        )
        assert_equal(as_hex(got.data), outputs[i], String("row ", i))


def test_nlit_out_of_range() raises:
    """Go's `TestNlitOutOfRange`: a table claiming 288 literal codes.

    RFC 1951 allows 286 and the two above that are the ones an encoder must
    never emit. Go's test only asks that this does not panic; here it also has
    to be refused, because there is no path on which those two codes mean
    anything.
    """
    var r = new_reader(
        Bytes(
            unhex(
                "fcfe36e75e1cefb3555877b656b543f46ff2d2e63d99a0858c48ebf8da83"
                "042a75c4f80f1211b9b44b09a0be8b914c"
            )
        )
    )
    var got = drain(r)
    assert_true(not got.stopped_on(EOF))


comptime _POEM = (
    "The Road Not Taken\nRobert Frost\n"
    + "\n"
    + "Two roads diverged in a yellow wood,\n"
    + "And sorry I could not travel both\n"
    + "And be one traveler, long I stood\n"
    + "And looked down one as far as I could\n"
    + "To where it bent in the undergrowth;\n"
    + "\n"
    + "Then took the other, as just as fair,\n"
    + "And having perhaps the better claim,\n"
    + "Because it was grassy and wanted wear;\n"
    + "Though as for that the passing there\n"
    + "Had worn them really about the same,\n"
    + "\n"
    + "And both that morning equally lay\n"
    + "In leaves no step had trodden black.\n"
    + "Oh, I kept the first for another day!\n"
    + "Yet knowing how way leads on to way,\n"
    + "I doubted if I should ever come back.\n"
    + "\n"
    + "I shall be telling this with a sigh\n"
    + "Somewhere ages and ages hence:\n"
    + "Two roads diverged in a wood, and I-\n"
    + "I took the one less traveled by,\n"
    + "And that has made all the difference.\n"
)
"""The same seven hundred and sixty three bytes the window test uses."""

comptime _POEM_STORED = (
    "01fb0204fd54686520526f6164204e6f742054616b656e0a526f626572742046"
    "726f73740a0a54776f20726f61647320646976657267656420696e2061207965"
    "6c6c6f7720776f6f642c0a416e6420736f727279204920636f756c64206e6f74"
    "2074726176656c20626f74680a416e64206265206f6e652074726176656c6572"
    "2c206c6f6e6720492073746f6f640a416e64206c6f6f6b656420646f776e206f"
    "6e6520617320666172206173204920636f756c640a546f207768657265206974"
    "2062656e7420696e2074686520756e64657267726f7774683b0a0a5468656e20"
    "746f6f6b20746865206f746865722c206173206a75737420617320666169722c"
    "0a416e6420686176696e67207065726861707320746865206265747465722063"
    "6c61696d2c0a42656361757365206974207761732067726173737920616e6420"
    "77616e74656420776561723b0a54686f75676820617320666f72207468617420"
    "7468652070617373696e672074686572650a48616420776f726e207468656d20"
    "7265616c6c792061626f7574207468652073616d652c0a0a416e6420626f7468"
    "2074686174206d6f726e696e6720657175616c6c79206c61790a496e206c6561"
    "766573206e6f2073746570206861642074726f6464656e20626c61636b2e0a4f"
    "682c2049206b6570742074686520666972737420666f7220616e6f7468657220"
    "646179210a596574206b6e6f77696e6720686f7720776179206c65616473206f"
    "6e20746f207761792c0a4920646f756274656420696620492073686f756c6420"
    "6576657220636f6d65206261636b2e0a0a49207368616c6c2062652074656c6c"
    "696e6720746869732077697468206120736967680a536f6d6577686572652061"
    "67657320616e6420616765732068656e63653a0a54776f20726f616473206469"
    "76657267656420696e206120776f6f642c20616e6420492d0a4920746f6f6b20"
    "746865206f6e65206c6573732074726176656c65642062792c0a416e64207468"
    "617420686173206d61646520616c6c2074686520646966666572656e63652e0a"
)
"""The poem as one stored block. `zlib.compressobj(0, 8, -15)`."""

comptime _POEM_FAST = (
    "7552bb92d43010ccf515436eee03b808028a4da0ead88470bc1a5b6265cd3292"
    "57e5bfa7255f1511916db9d58fe9b906a137654fdfb5d295ef92dd9bce6295be"
    "9a96eadcb5291900857c7c8aade22966623a24256dd454fde43e674f45cd0eba"
    "d04df7e42983ae1a3f25d1ac350cc42ca459de8fc5264a9a57dc281524039154"
    "ef10f0daf28072a1858df078e77557a516c48462a55972ed662a32ecd9c39c69"
    "abe115a683e01864e31ff4bb1a587eefa5f6e7c2d14ed7819f11261e62811f65"
    "c067a9558c6e89e336b92f72e3bd0cbd869bab712907310237ce15669bb0bd42"
    "51f7350c6e35d030e2c3d603e8cedf1d88fb863937b5e17823134e0954b3ee27"
    "b8f026933b4705cf27cb067c67903ffb80273edc255312ccb660cc989e3c2880"
    "b99a7a8fdc73e2dbfdc5fd0813a67697c749be4443f605e618ddc00e793e3eb8"
    "5f52e99eb57589d0fbe4a373a36eed13ecdf93bba0917dee61e3d2fb4256542c"
    "5807b4bd09cd4310b012e011bd50c5769cb963a1161186a9c435b89fc09f05f2"
    "0aff7d8ee30585dde4d37fb76dacd9405f3e42e75fb5d8a72405c58d5d83c319"
    "7efb3a8e0a021adbd80b755bbd0f1f97054d40ebc5fd05"
)
"""The poem at the fastest level. `zlib.compressobj(1, 8, -15)`."""

comptime _POEM_BEST = (
    "7552b1929d3010ebfd159b9edc07e4aabb2293d7243377af49b9e0053b182fb1"
    "cdf3f0f791cd6552a5028c2c69a5bd3ba137654bdfb5d09d5789e64d474985be"
    "26cdc5987b554a0064b2fe2169114b3e12d3292168a5aa6a07f3122d654de9a4"
    "1b4d7a044b117425f143028d5a5c478c421ae5e358d24041e3821bb980a42382"
    "ea0a01ab357628679a39b5c707afb92b552749c817f0c5d2cc14cc70440b7349"
    "6b71cf30ed04c720ebffa0dfd4c0f2ebc8e522f5e972edf8e1616297e478cf1d"
    "3e4a2992680aecb7c1bccac447ee7a153797c4399fc4b85a391698adc2e9198a"
    "7a2cae736b020d97ceb503ddf89b0331df9073d5d41d6f94844300d5a8c705ce"
    "bcc960aea8e0f962d9806f0cf2fbe8f0c0a7b9450a82103362467ab2630c8b5c"
    "d55acc3d069ed627f3c30d486d95fd229f7dc2eccd1cc71e08593e3f999f5268"
    "8d5a9b846b7df2d9b851b7b604dbf7606e68e418dbb07e6e7db95eb13c5a4aba"
    "21b12e68da1f786c3d176cc735b7cf543d8661ca7e71e61df8ab405ee0bfe5d8"
    "5f50d8245ffebb6d7dcd3afaf6193affaac59204c9f9ef5221b9f32ab687e7d0"
    "c7c61662b0d5f0d6cf33c4a1f564fe00"
)
"""The poem at the best level. `zlib.compressobj(9, 8, -15)`."""


def test_a_stream_from_another_encoder() raises:
    """The poem, stored and at both ends of zlib's level range.

    Three streams from an encoder that is not this library's, so that agreeing
    with them means being right rather than being self consistent. The stored
    one is the only one of the three that exercises `_data_block`, and it is
    two blocks long because a stored block carries a sixteen bit length and the
    encoder splits at its own boundary.
    """
    var want = as_bytes(_POEM)
    var levels: List[String] = [_POEM_STORED, _POEM_FAST, _POEM_BEST]
    for i in range(len(levels)):
        var r = new_reader(Bytes(unhex(levels[i])))
        var got = read_all(r)
        assert_equal(len(got), len(want), String("stream ", i))
        for j in range(len(want)):
            assert_equal(got[j], want[j], String("stream ", i, " byte ", j))


comptime _POEM_X200 = (
    "edd23bb2e3441400d05cab6872330b60a221a07809540d2f99b06db52d61596d"
    "24f9a9bc7baee4a18888494e645bbebadff3de95f4b5e636fd5697f49eaf656c"
    "bed6639996f4cb54e7a569ded79aa6089853db7f94e952dad48f29a7671986ba"
    "a6b5d6f6d07c19db34d7697aa6b774aa8fa14d63a45ba6fc518674ac4bb7471c"
    "4baa63f9feb84c8734d4f1126fcc4b24d923865aaf51a0adebb887e6399df3b4"
    "7d7ccfdbbcd7b476652aa95f22dfb86ccd2c31c3636ca3b9a9ae4bf7399aee4a"
    "3c8e64fb7f517fab1659fe7ccccb2b693fbdbaeef2471f4ddccbd4e5fbbc871f"
    "cbb294299d86dcdf0ecdcfe5941ff35e6f8d372f539ee767caf1ea9ac7259a5d"
    "4b9e3e47c5fab8747bee3a459abcecb9ee11bde5df3a28cdafb1e7b54e7bc7b7"
    "34953c0c91ea581fafe039dfcaa179ad2a7a7e65b945fc96a1fcf5d8c387fc6c"
    "dec6349458e21c6b8eed957b8cd1c65e6bdbc6dcc7219fae9f9adfbb436ced5a"
    "eeafe4e77e8ad9b7e6f2b82f24b5f9f943f3ad2ce93ad6752bd16df7cccf2d77"
    "9cbb6e1bdc7e1f9ab7b8c8e3b80ddb9fb77b75fb89cbc7b6a57a8b8ded059bed"
    "9fe871bbf3123a5e73f7735afb1826a7b9bf74cd1f11ff3a60be44ffdb1ef72f"
    "71b053f9e93fb5edccf6e8b71fa3cebfa70d244399e77f50c5e69eafc3eecbeb"
    "e21eb7dc46b1686b8b6ffbf3398a47ad4f1b12f4d1471f7df4d1471f7df4d147"
    "1f7df4d1471f7df4d1471f7df4d1471f7df4d1471f7df4d1471f7df4d1471f7d"
    "f4d1471f7df4d1471f7df4d1471f7df4d1471f7df4d1471f7df4d1471f7df4d1"
    "471f7df4d1471f7df4d1471f7df4d1471f7df4d1471f7df4d1471f7df4d1471f"
    "7df4d1471f7df4d1471f7df4d1471f7df4d1471f7df4d1471f7df4d1471f7df4"
    "d1471f7df4d1471f7df4d1471f7df4d1471f7df4d1471f7df4d1471f7df4d147"
    "1f7df4d1471f7df4d1471f7df4d1471f7df4d1471f7df4d1471f7df4d1471f7d"
    "f4d1471f7df4d1471f7df4d1471f7df4d1471f7df4d1471f7df4d1471f7df4d1"
    "471f7df4d1471f7df4d1471f7df4d1471f7df4d1471f7df4d1471f7df4d1471f"
    "7df4d1471f7df4d1471f7df4d1471f7df4d1471f7df4d1471f7df4d1471f7df4"
    "d1471f7df4d1471f7df4d1471f7df4d1471f7df4d1471f7df4d1471f7df4d147"
    "1f7df4d1471f7df4d1471f7df4d1471f7df4d1471f7df4d1471f7df4d1471f7d"
    "f4d1471f7df4d1471f7df4d1471f7df4d1471f7df4d1471f7df4d1471f7df4d1"
    "471f7df4d1471f7df4d1471f7df4d1471f7df4d1471f7df4d1471f7df4d1471f"
    "7df4d1471f7df4d1471f7df4d1471f7df4d1471f7df4d1471f7df4d1471f7df4"
    "d1471f7df4d1471f7df4d1471f7df4d1471f7df4d1471f7df4d1471f7df4d147"
    "1f7df4d1471f7df4d1471f7df4d1471f7df4d1471f7df4d1471f7df4d1471f7d"
    "f4d1471f7df4d1471f7df4d1471f7df4d1471f7df4d1471f7df4d1471f7df4d1"
    "471f7df4d1471f7df4d1471f7df4d1471f7df4d1471f7df4d1471f7df4d1471f"
    "7df4d1471f7df4d1471f7df4d1471f7df4d1471f7df4d1471f7df4d1471f7df4"
    "d1471f7df4d1471f7df4d1471f7df4d1471f7df4d1471f7df4d1471f7df4d147"
    "1f7df4d1471f7df4d1471f7df4d1471f7df4d1471f7df4d1471f7df4d1471f7d"
    "f4d1471f7df4d1471f7df4d1471f7df4d1471f7df4d1471f7df4d1471f7df4d1"
    "471f7df4d1471f7df4d1471f7df4d1471ffdff9ffedf"
)
"""Two hundred copies of the poem, 152,600 bytes, in 1,238.
`zlib.compressobj(6, 8, -15)`."""


def test_a_stream_longer_than_the_window() raises:
    """A hundred and fifty kilobytes out of twelve hundred bytes in.

    The window is thirty two kilobytes and this output is nearly five times
    that, so it wraps four times, and every wrap is a flush the caller has to
    be handed before the decompressor can carry on. Nothing shorter reaches
    that path. This is also the closest thing here to a decompression bomb, at
    a hundred and twenty three to one, and it is worth knowing what that ratio
    looks like in a file this small.
    """
    var poem = as_bytes(_POEM)
    var r = new_reader(Bytes(unhex(_POEM_X200)))
    var got = read_all(r)
    assert_equal(len(got), 200 * len(poem))
    for i in range(len(got)):
        assert_equal(got[i], poem[i % len(poem)], String("byte ", i))


comptime _LOREM_PLAIN = "cbc92f4acd55c82c282e0592555539a90a69f90a45601600"
"""`lorem ipsum izzle fo rizzle` at level 1, with no dictionary."""

comptime _FOX_PLAIN = (
    "2bc94855282ccd4cce56482aca2fcf5348cbaf50c82acd2d484d51c82f4b2d0200"
)
"""`the quick brown fox jumped over` at level 1, with no dictionary."""

comptime _LOREM_DICT = "8330320b8a4b816455554e2a5050a108cc0200"
"""The same sentence with `the lorem fox` preset. Nineteen bytes rather than
twenty four, which is the whole argument for a preset dictionary."""

comptime _FOX_DICT = (
    "2b01720a4b3393b315928af2cbf340420a59a5b905a9290af965a94500"
)
"""The other sentence with the same dictionary."""

comptime _LOREM = "lorem ipsum izzle fo rizzle"
"""Go's first string in `TestReset`."""

comptime _FOX = "the quick brown fox jumped over"
"""Go's second one."""


def test_reset() raises:
    """Go's `TestReset`: two streams through one decompressor.

    Go reaches the reset through a `Resetter` interface, which cannot be
    written here: a `Decompressor[R]` only accepts a reader of its own `R`, and
    an interface whose method takes an arbitrary reader needs a parametrized
    trait. So `reset` is a method and this calls it. `docs/deviations.md` has
    the row.
    """
    var r = new_reader(Bytes(unhex(_LOREM_PLAIN)))
    var first = read_all(r)
    assert_equal(String(from_utf8=Span(first)), _LOREM)

    var none = List[Byte]()
    r.reset(Bytes(unhex(_FOX_PLAIN)), Span(none))
    var second = read_all(r)
    assert_equal(String(from_utf8=Span(second)), _FOX)
    r.close()


def test_reset_dict() raises:
    """Go's `TestResetDict`: the same, with a preset dictionary each time.

    The dictionary has to be handed over again on every reset, because it is
    part of what the stream means rather than part of the decompressor. Getting
    that wrong gives no error at all, just different bytes, which is why both
    of these are checked against the sentence rather than against a length.
    """
    var dict = as_bytes("the lorem fox")
    var r = new_reader_dict(Bytes(unhex(_LOREM_DICT)), Span(dict))
    var first = read_all(r)
    assert_equal(String(from_utf8=Span(first)), _LOREM)

    r.reset(Bytes(unhex(_FOX_DICT)), Span(dict))
    var second = read_all(r)
    assert_equal(String(from_utf8=Span(second)), _FOX)
    r.close()


def test_the_bytes_after_the_last_block_are_left_alone() raises:
    """What `gzip` and `zlib` need, and the reason `new_reader` is shaped so.

    Both formats put a checksum after the DEFLATE stream and both find it by
    reading on from the same reader, so a decompressor that consumed a trailer
    it did not need would break them without failing. This appends four bytes
    to a complete stream and reads them back afterwards.
    """
    var src = Bytes(unhex("010100feff11deadbeef"))
    var r = new_reader(src^)
    var got = read_all(r)
    assert_equal(as_hex(got), "11")
    var rest = List[Byte]()
    for _ in range(4):
        rest.append(r.r.read_byte())
    assert_equal(as_hex(rest), "deadbeef")
