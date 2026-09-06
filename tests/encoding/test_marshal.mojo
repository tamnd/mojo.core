"""The six traits, and the six types in the library that implement them.

There is nothing to test in a trait with no default bodies. What can be tested,
and is the only thing that would ever break, is whether a type still satisfies
one: a method whose signature drifts stops conforming, and without a test that
names both the drift is only found by whichever codec tries to use it next.

So every function here takes its argument through a trait bound and every test
hands it a real type. The bodies are deliberately trivial, because the assertion
is that the call compiles at all. A type that stopped conforming would fail to
build this file rather than fail an assertion in it, which is the earliest the
mistake can be caught and is the reason the file is worth its length.

`Time` is the only type in the library that implements all six.
"""

from std.testing import assert_equal, assert_true

from core.encoding import (
    BinaryAppender,
    BinaryMarshaler,
    BinaryUnmarshaler,
    TextAppender,
    TextMarshaler,
    TextUnmarshaler,
)
from core.math.big import Float, new_int, new_rat
from core.math.rand import new_chacha8, new_pcg
from core.time import MARCH, date


def _text_of[T: TextMarshaler](value: T) raises -> String:
    return String(from_utf8_lossy=Span(value.marshal_text()))


def _text_onto[T: TextAppender](value: T, mut dst: List[UInt8]) raises -> Int:
    return value.append_text(dst)


def _text_into[
    T: TextUnmarshaler, o: ImmOrigin
](mut value: T, text: Span[UInt8, o]) raises:
    value.unmarshal_text(text)


def _bytes_of[T: BinaryMarshaler](value: T) raises -> List[UInt8]:
    return value.marshal_binary()


def _bytes_onto[
    T: BinaryAppender
](value: T, mut dst: List[UInt8]) raises -> Int:
    return value.append_binary(dst)


def _bytes_into[
    T: BinaryUnmarshaler, o: ImmOrigin
](mut value: T, data: Span[UInt8, o]) raises:
    value.unmarshal_binary(data)


def test_a_time_is_all_six() raises:
    var t = date(2024, MARCH, 9, 14, 5, 6, 0)
    assert_equal(_text_of(t), "2024-03-09T14:05:06Z")

    var text = List[UInt8]()
    assert_equal(_text_onto(t, text), 20)

    var read = date(1970, MARCH, 1, 0, 0, 0, 0)
    _text_into(read, Span(text))
    assert_true(read == t)

    var data = List[UInt8]()
    assert_equal(_bytes_onto(t, data), len(_bytes_of(t)))

    var back = date(1970, MARCH, 1, 0, 0, 0, 0)
    _bytes_into(back, Span(data))
    assert_true(back == t)


def test_a_big_int_is_the_three_text_traits() raises:
    var x = new_int(-1234567890123456789)
    assert_equal(_text_of(x), "-1234567890123456789")

    var text = List[UInt8]()
    assert_equal(_text_onto(x, text), 20)

    var back = new_int(0)
    _text_into(back, Span(text))
    assert_equal(back.cmp(x), 0)


def test_a_big_rat_is_the_three_text_traits() raises:
    var x = new_rat(3, 4)
    assert_equal(_text_of(x), "3/4")

    var text = List[UInt8]()
    assert_equal(_text_onto(x, text), 3)

    var back = new_rat(0, 1)
    _text_into(back, Span(text))
    assert_equal(back.cmp(x), 0)


def test_a_big_float_is_the_three_text_traits() raises:
    var x = Float()
    _ = x.set_float64(2.5)
    assert_equal(_text_of(x), "2.5")

    var text = List[UInt8]()
    assert_equal(_text_onto(x, text), 3)

    var back = Float()
    _text_into(back, Span(text))
    assert_equal(back.cmp(x), 0)


def test_a_pcg_is_the_three_binary_traits() raises:
    var source = new_pcg(1, 2)
    _ = source.uint64()
    var saved = _bytes_of(source)

    var appended = List[UInt8]()
    assert_equal(_bytes_onto(source, appended), len(saved))

    var restored = new_pcg(0, 0)
    _bytes_into(restored, Span(saved))
    assert_equal(restored.uint64(), source.uint64())


def test_a_chacha8_is_the_three_binary_traits() raises:
    var source = new_chacha8(Array[UInt8, 32](fill=7))
    _ = source.uint64()
    var saved = _bytes_of(source)

    var appended = List[UInt8]()
    assert_equal(_bytes_onto(source, appended), len(saved))

    var restored = new_chacha8(Array[UInt8, 32](fill=0))
    _bytes_into(restored, Span(saved))
    assert_equal(restored.uint64(), source.uint64())


def test_an_appender_adds_to_what_is_already_there() raises:
    """The count is what this call added and not the length of the list.

    Go returns the grown slice, so the distinction does not arise there and it
    is the one thing a reader translating an appending method is most likely to
    get wrong. Every appender in the library is checked against it here.
    """
    var dst = List[UInt8]()
    dst.append(UInt8(ord("!")))

    var t = date(2024, MARCH, 9, 14, 5, 6, 0)
    assert_equal(_text_onto(t, dst), 20)
    assert_equal(len(dst), 21)
    assert_equal(dst[0], UInt8(ord("!")))

    var x = new_int(7)
    assert_equal(_text_onto(x, dst), 1)
    assert_equal(len(dst), 22)
