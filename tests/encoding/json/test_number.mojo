"""`Number`, which is the text of a number and not a number.

Go has no test file for the type itself, only for the validity check that goes
with it, so this is the three methods and the two reasons the type exists: the
values no machine type holds, and the round trip.
"""

from std.testing import assert_equal, assert_true

from core.encoding.json import Number


def test_the_text_comes_back_as_it_went_in() raises:
    """Go's `String`, which is the conversion written out."""
    assert_equal(Number("1.50").string(), "1.50")
    assert_equal(Number("-0").string(), "-0")
    assert_equal(String(Number("1e9")), "1e9")


def test_a_whole_number_reads_as_both() raises:
    assert_equal(Number("42").int64(), 42)
    assert_equal(Number("42").float64(), 42.0)
    assert_equal(Number("-42").int64(), -42)


def test_a_fraction_is_not_an_integer() raises:
    """Base ten and nothing else, so `1.0` is refused even though its value is
    a whole number. Go refuses it in the same place for the same reason."""
    var raised = False
    try:
        _ = Number("1.0").int64()
    except:
        raised = True
    assert_true(raised)
    assert_equal(Number("1.0").float64(), 1.0)


def test_an_exponent_is_not_an_integer_either() raises:
    var raised = False
    try:
        _ = Number("1e3").int64()
    except:
        raised = True
    assert_true(raised)
    assert_equal(Number("1e3").float64(), 1000.0)


def test_a_number_too_big_for_an_integer_raises() raises:
    """The first of the two reasons the type exists: a document may hold a
    number no machine type can, and finding out is the caller's business."""
    var raised = False
    try:
        _ = Number("123456789012345678901234567890").int64()
    except:
        raised = True
    assert_true(raised)


def test_a_number_too_big_for_a_float_raises() raises:
    """Rather than quietly becoming an infinity, which is what reading every
    number as a float would do."""
    var raised = False
    try:
        _ = Number("1e400").float64()
    except:
        raised = True
    assert_true(raised)


def test_the_text_survives_a_round_trip() raises:
    """The second reason. A float loses the way a number was written, so
    anything that has to reproduce a document rather than understand it keeps
    the text."""
    assert_equal(Number("1.0").string(), "1.0")
    assert_equal(Number("1.500").string(), "1.500")
    assert_equal(Number("1e+2").string(), "1e+2")


def test_equality_compares_the_text_and_not_the_value() raises:
    """Which is what Go's `==` on a named string type does."""
    assert_true(Number("1.0") != Number("1"))
    assert_true(Number("1.0") == Number("1.0"))


def test_a_float_is_correctly_rounded() raises:
    """`core.strconv` does the parsing, so the result is the float nearest the
    value the text names rather than one accumulated digit by digit."""
    assert_equal(Number("0.1").float64(), 0.1)
    assert_equal(
        Number("2.2250738585072011e-308").float64(), 2.2250738585072011e-308
    )
    assert_equal(Number("1e-323").float64(), 1e-323)


def test_text_that_is_not_a_number_raises_when_it_is_read() raises:
    """Nothing checks on the way in, which is Go's arrangement: its encoder is
    where an invalid one is caught."""
    assert_equal(Number("not a number").string(), "not a number")
    var raised = False
    try:
        _ = Number("not a number").float64()
    except:
        raised = True
    assert_true(raised)
