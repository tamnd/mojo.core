"""Go's `TestRegress`, the golden output of every method of a `Rand`.

Three hundred and forty values: twenty from each of seventeen methods of a
`Rand` built on `new_pcg(1, 2)`, with a fresh generator for each method so that
one method's draws do not shift the next one's. Go builds the list by walking
the methods with reflect and calling each twenty times with arguments taken
round robin from four tables, and its comment says not to change the numbers
under any circumstances, because a caller who seeded a generator to get a
reproducible answer is entitled to keep getting it.

There is no reflection here, so the seventeen calls are written out. They are
in the order reflect walks methods in, which is alphabetical by Go's name, so
this file reads against Go's golden list from top to bottom. `regressGolden` is
a `[]any` and comes out of the harvest as one list per Go type, so each method
reads the list its return type went into at the offset its group starts at; the
offsets are the running total of the groups above it, which is the one thing
here that has to be recomputed if Go ever adds a method.

`Perm` returns a slice, so its twenty values are harvested flattened with the
lengths beside them.
"""

from std.testing import assert_equal

from core.math.rand import new, new_pcg

from tests.generated.rand import (
    regress_golden_float32_rows,
    regress_golden_float64_rows,
    regress_golden_int32_rows,
    regress_golden_int64_rows,
    regress_golden_int_slice_rows,
    regress_golden_int_slice_sizes,
    regress_golden_uint32_rows,
    regress_golden_uint64_rows,
)

comptime REPEATS = 20
"""How many times each method is called. Go's `repeat` loop bound."""


def _int32s() -> List[Int32]:
    """Go's `int32s`, the arguments the `Int32N` calls take."""
    return [
        Int32(1),
        10,
        32,
        1 << 20,
        (1 << 20) + 1,
        1000000000,
        1 << 30,
        (1 << 31) - 2,
        (1 << 31) - 1,
    ]


def _uint32s() -> List[UInt32]:
    """Go's `uint32s`, which is `int32s` and the top two values as well."""
    return [
        UInt32(1),
        10,
        32,
        1 << 20,
        (1 << 20) + 1,
        1000000000,
        1 << 30,
        (1 << 31) - 2,
        (1 << 31) - 1,
        0xFFFFFFFE,
        0xFFFFFFFF,
    ]


def _int64s() -> List[Int64]:
    """Go's `int64s`, the arguments the `Int64N` and `IntN` calls take."""
    return [
        Int64(1),
        10,
        32,
        1 << 20,
        (1 << 20) + 1,
        1000000000,
        1 << 30,
        (1 << 31) - 2,
        (1 << 31) - 1,
        1000000000000000000,
        1 << 60,
        0x7FFFFFFFFFFFFFFE,
        0x7FFFFFFFFFFFFFFF,
    ]


def _uint64s() -> List[UInt64]:
    """Go's `uint64s`, which is `int64s` and the top two values as well."""
    return [
        UInt64(1),
        10,
        32,
        1 << 20,
        (1 << 20) + 1,
        1000000000,
        1 << 30,
        (1 << 31) - 2,
        (1 << 31) - 1,
        1000000000000000000,
        1 << 60,
        0x7FFFFFFFFFFFFFFE,
        0x7FFFFFFFFFFFFFFF,
        0xFFFFFFFFFFFFFFFE,
        0xFFFFFFFFFFFFFFFF,
    ]


def _perm_sizes() -> List[Int]:
    """Go's `permSizes`, the arguments the `Perm` calls take."""
    return [0, 1, 5, 8, 9, 10, 16]


def test_regress_exp_float64() raises:
    var want = regress_golden_float64_rows()
    var r = new(new_pcg(1, 2))
    for i in range(REPEATS):
        assert_equal(r.exp_float64(), want[i], "exp_float64 #" + String(i))


def test_regress_float32() raises:
    var want = regress_golden_float32_rows()
    var r = new(new_pcg(1, 2))
    for i in range(REPEATS):
        assert_equal(r.float32(), want[i], "float32 #" + String(i))


def test_regress_float64() raises:
    var want = regress_golden_float64_rows()
    var r = new(new_pcg(1, 2))
    for i in range(REPEATS):
        assert_equal(r.float64(), want[20 + i], "float64 #" + String(i))


def test_regress_int() raises:
    var want = regress_golden_int64_rows()
    var r = new(new_pcg(1, 2))
    for i in range(REPEATS):
        assert_equal(r.int(), want[i], "int #" + String(i))


def test_regress_int32() raises:
    var want = regress_golden_int32_rows()
    var r = new(new_pcg(1, 2))
    for i in range(REPEATS):
        assert_equal(Int(r.int32()), want[i], "int32 #" + String(i))


def test_regress_int32_n() raises:
    var want = regress_golden_int32_rows()
    var args = _int32s()
    var r = new(new_pcg(1, 2))
    for i in range(REPEATS):
        var arg = args[i % len(args)]
        assert_equal(
            Int(r.int32_n(arg)),
            want[20 + i],
            "int32_n(" + String(arg) + ") #" + String(i),
        )


def test_regress_int64() raises:
    var want = regress_golden_int64_rows()
    var r = new(new_pcg(1, 2))
    for i in range(REPEATS):
        assert_equal(Int(r.int64()), want[20 + i], "int64 #" + String(i))


def test_regress_int64_n() raises:
    var want = regress_golden_int64_rows()
    var args = _int64s()
    var r = new(new_pcg(1, 2))
    for i in range(REPEATS):
        var arg = args[i % len(args)]
        assert_equal(
            Int(r.int64_n(arg)),
            want[40 + i],
            "int64_n(" + String(arg) + ") #" + String(i),
        )


def test_regress_int_n() raises:
    var want = regress_golden_int64_rows()
    var args = _int64s()
    var r = new(new_pcg(1, 2))
    for i in range(REPEATS):
        var arg = Int(args[i % len(args)])
        assert_equal(
            r.int_n(arg),
            want[60 + i],
            "int_n(" + String(arg) + ") #" + String(i),
        )


def test_regress_norm_float64() raises:
    var want = regress_golden_float64_rows()
    var r = new(new_pcg(1, 2))
    for i in range(REPEATS):
        assert_equal(
            r.norm_float64(), want[40 + i], "norm_float64 #" + String(i)
        )


def test_regress_perm() raises:
    var flat = regress_golden_int_slice_rows()
    var sizes = regress_golden_int_slice_sizes()
    var args = _perm_sizes()
    var r = new(new_pcg(1, 2))
    var at = 0
    for i in range(REPEATS):
        var arg = args[i % len(args)]
        var got = r.perm(arg)
        assert_equal(len(got), sizes[i], "perm(" + String(arg) + ") length")
        for k in range(sizes[i]):
            assert_equal(
                got[k],
                flat[at + k],
                "perm("
                + String(arg)
                + ") #"
                + String(i)
                + "["
                + String(k)
                + "]",
            )
        at += sizes[i]


def test_regress_uint() raises:
    var want = regress_golden_uint64_rows()
    var r = new(new_pcg(1, 2))
    for i in range(REPEATS):
        assert_equal(UInt64(r.uint()), want[i], "uint #" + String(i))


def test_regress_uint32() raises:
    var want = regress_golden_uint32_rows()
    var r = new(new_pcg(1, 2))
    for i in range(REPEATS):
        assert_equal(UInt64(r.uint32()), want[i], "uint32 #" + String(i))


def test_regress_uint32_n() raises:
    var want = regress_golden_uint32_rows()
    var args = _uint32s()
    var r = new(new_pcg(1, 2))
    for i in range(REPEATS):
        var arg = args[i % len(args)]
        assert_equal(
            UInt64(r.uint32_n(arg)),
            want[20 + i],
            "uint32_n(" + String(arg) + ") #" + String(i),
        )


def test_regress_uint64() raises:
    var want = regress_golden_uint64_rows()
    var r = new(new_pcg(1, 2))
    for i in range(REPEATS):
        assert_equal(r.uint64(), want[20 + i], "uint64 #" + String(i))


def test_regress_uint64_n() raises:
    var want = regress_golden_uint64_rows()
    var args = _uint64s()
    var r = new(new_pcg(1, 2))
    for i in range(REPEATS):
        var arg = args[i % len(args)]
        assert_equal(
            r.uint64_n(arg),
            want[40 + i],
            "uint64_n(" + String(arg) + ") #" + String(i),
        )


def test_regress_uint_n() raises:
    var want = regress_golden_uint64_rows()
    var args = _uint64s()
    var r = new(new_pcg(1, 2))
    for i in range(REPEATS):
        var arg = UInt(args[i % len(args)])
        assert_equal(
            UInt64(r.uint_n(arg)),
            want[60 + i],
            "uint_n(" + String(arg) + ") #" + String(i),
        )
