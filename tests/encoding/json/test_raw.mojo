"""`RawMessage`, a value kept as the bytes it was written with.

Go's own tests for it are all about decoding into a struct that has one, which
is `tools/codec/testdata/driver.mojo` here rather than anything in this file.
What is left is the type on its own: that an empty one is `null` both ways,
that the bytes are kept exactly as they arrived, and that `unmarshal_json`
refuses what Go's would have taken, which is the one place the two differ.
"""

from std.testing import assert_equal, assert_false, assert_raises, assert_true

from core.encoding.json import RawMessage, SyntaxError
from core.errors import matches
from core.errors.codes import ErrJSONSyntax
from core.io import Byte


def _held(m: RawMessage) -> String:
    """What a raw message holds, as text, without going through `write_to`."""
    return String(from_utf8_lossy=Span(m.bytes))


def test_an_empty_one_is_null_both_ways() raises:
    """Go's rule for a nil `RawMessage`, which is what a zero value has to be.

    A struct field nothing was read into still has to write a value where the
    document says there is one, and `null` is the value that reads back into
    an empty one again.
    """
    var empty = RawMessage()
    assert_equal(len(empty), 0)
    assert_equal(String(empty), "null")
    assert_equal(
        String(from_utf8_lossy=Span(empty.marshal_json())),
        "null",
    )


def test_the_bytes_are_kept_as_they_arrived() raises:
    """Whitespace and all, which is the whole point of the type.

    A payload somebody signed still verifies, and a number nothing could hold
    goes back out as the digits that came in.
    """
    var spaced = RawMessage('{ "a" : [ 1 , 2 ] }'.as_bytes())
    assert_equal(String(spaced), '{ "a" : [ 1 , 2 ] }')
    assert_equal(len(spaced), 19)
    var huge = RawMessage("1e400".as_bytes())
    assert_equal(String(huge), "1e400")


def test_the_constructor_checks_nothing() raises:
    """A decoder that has already walked the bytes does not pay for them
    twice.

    Go copies without looking for the same reason, and the difference is that
    Go's only caller is its own decoder while this one is a constructor anybody
    can reach.
    """
    var nonsense = RawMessage("} not json {".as_bytes())
    assert_equal(String(nonsense), "} not json {")


def test_unmarshal_checks_and_go_does_not() raises:
    """The one place the two disagree, and the deviations page says so.

    Go's `UnmarshalJSON` copies whatever it is handed. A value that is not one
    JSON value would write itself back out and break the document it went
    into, and finding that out at the far end of a wire is worse than finding
    it out here.
    """
    var m = RawMessage()
    m.unmarshal_json('{"a":[1,2]}'.as_bytes())
    assert_equal(String(m), '{"a":[1,2]}')

    with assert_raises(contains="unexpected end of JSON input"):
        m.unmarshal_json('{"a":'.as_bytes())
    with assert_raises(contains="invalid character"):
        m.unmarshal_json("{,}".as_bytes())
    with assert_raises(contains="unexpected end of JSON input"):
        m.unmarshal_json("".as_bytes())
    with assert_raises(contains="invalid character"):
        m.unmarshal_json("1 2".as_bytes())


def test_what_unmarshal_refuses_reads_as_a_syntax_error() raises:
    """The same failure `valid_or_raise` makes, since that is what it calls.

    Which means a caller who already handles the one the rest of the package
    raises handles this one too, offset and all.
    """
    var m = RawMessage()
    var said = Error()
    try:
        m.unmarshal_json("[1,]".as_bytes())
    except e:
        said = e.copy()
    assert_true(matches(said, ErrJSONSyntax))
    var failure = SyntaxError.of(said)
    assert_true(Bool(failure))
    assert_equal(
        failure.value().error(),
        "invalid character ']' looking for beginning of value",
    )
    assert_equal(failure.value().offset, 4)


def test_a_refused_value_leaves_the_old_one_alone() raises:
    """The check comes before the copy, so a failed call changes nothing."""
    var m = RawMessage()
    m.unmarshal_json("[1]".as_bytes())
    try:
        m.unmarshal_json("[".as_bytes())
    except:
        pass
    assert_equal(String(m), "[1]")


def test_it_holds_its_own_bytes() raises:
    """Which is why it is a struct rather than the slice Go has.

    The buffer it was made from is written over afterwards, and the message is
    still what it was.
    """
    var source = List[Byte]('"abc"'.as_bytes())
    var kept = RawMessage(Span(source))
    for i in range(len(source)):
        source[i] = Byte(ord("z"))
    assert_equal(String(kept), '"abc"')


def test_two_hold_equal_when_the_bytes_are_equal() raises:
    """Bytes rather than values, so equal documents are not equal messages.

    A caller who wanted the values compares what they read out of it, and a
    comparison that parsed would be a second decoder hiding inside `==`.
    """
    assert_equal(RawMessage("[1]".as_bytes()), RawMessage("[1]".as_bytes()))
    assert_true(RawMessage("[1]".as_bytes()) != RawMessage("[ 1 ]".as_bytes()))
    assert_true(RawMessage("1".as_bytes()) != RawMessage("1.0".as_bytes()))
    assert_true(RawMessage("1".as_bytes()) != RawMessage("11".as_bytes()))
    assert_equal(RawMessage(), RawMessage())
    assert_true(RawMessage() != RawMessage("null".as_bytes()))


def test_an_empty_one_and_a_null_one_are_different_messages() raises:
    """They write the same and they are not the same.

    One is a field the document did not carry and one is a field it carried as
    `null`, which is a difference a program is allowed to care about even
    though the document it writes back cannot show it.
    """
    var absent = RawMessage()
    var explicit = RawMessage("null".as_bytes())
    assert_equal(String(absent), String(explicit))
    assert_true(absent != explicit)
    assert_equal(len(absent), 0)
    assert_equal(len(explicit), 4)


def test_marshal_hands_back_a_copy() raises:
    """A caller writing a document is free to keep going with what they got."""
    var m = RawMessage("[1]".as_bytes())
    var written = m.marshal_json()
    written.append(Byte(ord("!")))
    assert_equal(String(m), "[1]")
    assert_equal(_held(m), "[1]")


def test_a_copy_of_one_is_its_own() raises:
    """It owns a list, so copying it copies the bytes."""
    var first = RawMessage("[1]".as_bytes())
    var second = first.copy()
    second.unmarshal_json("[2]".as_bytes())
    assert_equal(String(first), "[1]")
    assert_equal(String(second), "[2]")


def test_text_that_is_not_utf8_still_writes() raises:
    """A string is where the scanner stops caring what a document holds.

    JSONTestSuite has files like this and `valid` accepts them, so a raw
    message can end up holding them and printing one has to produce something
    rather than fail.
    """
    var quote = Byte(ord('"'))
    var lone: List[Byte] = [quote, Byte(0x80), quote]
    var m = RawMessage(Span(lone))
    assert_equal(len(m), 3)
    assert_equal(String(m), '"' + chr(0xFFFD) + '"')


def test_it_is_the_shape_a_field_needs() raises:
    """The four traits a generated codec relies on, exercised together."""
    var held = List[RawMessage]()
    held.append(RawMessage("1".as_bytes()))
    held.append(RawMessage())
    assert_equal(len(held[0]), 1)
    assert_false(Bool(len(held[1]) != 0))
    assert_equal(String(held[0]) + " " + String(held[1]), "1 null")
