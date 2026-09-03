"""Unsigned multiple precision integers. Go's `nat.go`.

A natural number here is a `List[Word]` holding its digits smallest first, with
no leading zero digits, so zero is the empty list. Every function in this file
takes its operands as spans and returns a fresh list. That is the one deep
difference from Go, and it is worth being clear about why.

Go's `nat` is a slice, and every operation is written as a method on the
destination: `z.add(x, y)` fills `z` with `x + y` and hands `z` back, reusing
whatever capacity `z` already had. Callers lean on that hard, and they lean on
being allowed to pass the same slice twice, as in `z.add(z, y)`. Mojo will not
let two spans over one list reach the same call, and there is no way to write
`z.add(z, y)` at all. So the destination argument goes away: each function
allocates what it returns, and the loops that genuinely need to read and write
one vector are the `_into` forms in `arith.mojo`, which take one span and do
the aliasing inside a single loop where nothing has to be proved.

The cost is allocation. Go's exponentiation reuses four buffers for thousands
of multiplications; here each of those is a new list. The Montgomery loop is
the one place that mattered enough to keep Go's shape, and it does, with its
scratch allocated once outside the loop.

One porting hazard runs through the whole package. Go defines a shift by more
than the width of the type as zero. LLVM, and so Mojo, leaves it undefined.
Every variable shift here is therefore either masked to the width or guarded by
the test that made Go's version give zero, and the places where Go relied on
the wider rule are commented where they appear.
"""

from core.math.bits import len64, trailing_zeros64

from .arith import (
    _S,
    _W,
    _add_vv,
    _add_vw,
    _lsh_vu,
    _rsh_vu,
    _sub_vv,
    _sub_vw,
    Word,
)


def _zero() -> List[Word]:
    """The number zero, which is the empty list of digits."""
    return List[Word]()


def _one() -> List[Word]:
    """The number one. Go keeps `natOne` as a package variable; a list cannot
    be a compile time constant here, so the four small numbers the package
    needs are functions that build them."""
    return _set_word(1)


def _two() -> List[Word]:
    """The number two. Go's `natTwo`."""
    return _set_word(2)


def _five() -> List[Word]:
    """The number five. Go's `natFive`."""
    return _set_word(5)


def _ten() -> List[Word]:
    """The number ten. Go's `natTen`."""
    return _set_word(10)


def _norm(var z: List[Word]) -> List[Word]:
    """`z` with its leading zero digits dropped. Go's `nat.norm`.

    Every function here ends with this, because the rest of the package is
    written to assume that the top digit of a number is not zero: `_cmp`
    compares lengths first, and `_bit_len` reads only the top digit.
    """
    var i = len(z)
    while i > 0 and z[i - 1] == 0:
        i -= 1
    z.resize(i, Word(0))
    return z^


def _norm_len[o: ImmOrigin](x: Span[Word, o]) -> Int:
    """How long `x` would be with its leading zero digits dropped.

    The answer to `_norm` for a span, which cannot be resized. The caller
    slices with it.
    """
    var i = len(x)
    while i > 0 and x[i - 1] == 0:
        i -= 1
    return i


def _clone[o: ImmOrigin](x: Span[Word, o]) -> List[Word]:
    """A copy of `x` as a list of its own. Go's `nat.set`."""
    var z = List[Word](capacity=len(x))
    for i in range(len(x)):
        z.append(x[i])
    return z^


def _set_word(x: Word) -> List[Word]:
    """The one digit number `x`, or zero if `x` is zero. Go's `nat.setWord`."""
    if x == 0:
        return _zero()
    var z = List[Word](capacity=1)
    z.append(x)
    return z^


def _is_zero[o: ImmOrigin](x: Span[Word, o]) -> Bool:
    """Whether `x` is zero, which for a normalised number is being empty."""
    return len(x) == 0


def _cmp[
    o1: ImmOrigin, o2: ImmOrigin
](x: Span[Word, o1], y: Span[Word, o2]) -> Int:
    """`-1`, `0` or `1` as `x` is below, equal to or above `y`. Go's `nat.cmp`.

    Both have to be normalised, which is what makes the length comparison the
    first and usually the last thing this does.
    """
    var m = len(x)
    var n = len(y)
    if m != n or m == 0:
        if m < n:
            return -1
        if m > n:
            return 1
        return 0

    var i = m - 1
    while i > 0 and x[i] == y[i]:
        i -= 1

    if x[i] < y[i]:
        return -1
    if x[i] > y[i]:
        return 1
    return 0


def _add[
    o1: ImmOrigin, o2: ImmOrigin
](x: Span[Word, o1], y: Span[Word, o2]) -> List[Word]:
    """`x + y`. Go's `nat.add`."""
    var m = len(x)
    var n = len(y)

    if m < n:
        return _add(y, x)
    if m == 0:
        return _zero()
    if n == 0:
        return _clone(x)

    var z = List[Word](length=m + 1, fill=0)
    var c = _add_vv(Span(z)[0:n], x[0:n], y[0:n])
    if m > n:
        c = _add_vw(Span(z)[n:m], x[n:m], c)
    z[m] = c

    return _norm(z^)


def _sub[
    o1: ImmOrigin, o2: ImmOrigin
](x: Span[Word, o1], y: Span[Word, o2]) -> List[Word]:
    """`x - y`, which the caller has to know does not go below zero.

    Go panics here on underflow. This does not check, and returns the
    difference modulo two to the power of `len(x) * _W` instead, because a
    check would make the function raise and `Int.add` and `Int.sub` are built
    on it. Every call in this package compares with `_cmp` first and passes the
    larger side as `x`, which is the same thing Go's callers do and the reason
    Go's panic never fires either.
    """
    var m = len(x)
    var n = len(y)

    if m < n:
        return _zero()
    if m == 0:
        return _zero()
    if n == 0:
        return _clone(x)

    var z = List[Word](length=m, fill=0)
    var c = _sub_vv(Span(z)[0:n], x[0:n], y[0:n])
    if m > n:
        c = _sub_vw(Span(z)[n:m], x[n:m], c)
    _ = c

    return _norm(z^)


def _bit_len[o: ImmOrigin](x: Span[Word, o]) -> Int:
    """How many bits `x` needs. Go's `nat.bitLen`.

    Go smears the top digit downwards before counting, so that the count runs
    over a value whose low bits are all ones whatever the input was. That
    matters because `bits.Len` reads a lookup table on some of Go's targets and
    a table read is a cache access an attacker can time. The smearing costs six
    instructions and is kept, even though `len64` here is a single `clz` and
    reads no table, because this is the length a key is measured with and the
    next person to change it should have to argue with this comment.

    Unlike almost everything else here, this works on a number that has not
    been normalised.
    """
    var i = len(x) - 1
    if i < 0:
        return 0
    var top = x[i]
    top |= top >> 1
    top |= top >> 2
    top |= top >> 4
    top |= top >> 8
    top |= top >> 16
    top |= top >> 32
    return i * _W + len64(top)


def _trailing_zero_bits[o: ImmOrigin](x: Span[Word, o]) -> Int:
    """How many zero bits sit below the lowest set bit. Go's
    `nat.trailingZeroBits`.

    Zero has none, which is Go's answer and not the mathematical one.
    """
    if len(x) == 0:
        return 0
    var i = 0
    while x[i] == 0:
        i += 1
    return i * _W + trailing_zeros64(x[i])


def _is_pow2[o: ImmOrigin](x: Span[Word, o]) -> Tuple[Int, Bool]:
    """`(i, True)` when `x` is two to the `i`, `(0, False)` otherwise. Go's
    `nat.isPow2`."""
    if len(x) == 0:
        return (0, False)
    var i = 0
    while x[i] == 0:
        i += 1
    if i == len(x) - 1 and (x[i] & (x[i] - 1)) == 0:
        return (i * _W + trailing_zeros64(x[i]), True)
    return (0, False)


def _lsh[o: ImmOrigin](x: Span[Word, o], s: Int) -> List[Word]:
    """`x << s`. Go's `nat.lsh`."""
    var m = len(x)
    if m == 0:
        return _zero()

    var n = m + s // _W
    var z = List[Word](length=n + 1, fill=0)
    var sw = Word(s % _W)
    if sw == 0:
        for i in range(m):
            z[n - m + i] = x[i]
    else:
        z[n] = _lsh_vu(Span(z)[n - m : n], x, sw)

    return _norm(z^)


def _rsh[o: ImmOrigin](x: Span[Word, o], s: Int) -> List[Word]:
    """`x >> s`. Go's `nat.rsh`."""
    var m = len(x)
    var n = m - s // _W
    if n <= 0:
        return _zero()

    var z = List[Word](length=n, fill=0)
    var sw = Word(s % _W)
    if sw == 0:
        for i in range(n):
            z[i] = x[m - n + i]
    else:
        _ = _rsh_vu(Span(z), x[m - n :], sw)

    return _norm(z^)


def _bit[o: ImmOrigin](x: Span[Word, o], i: Int) -> Int:
    """The `i`th bit of `x`, counting from zero at the bottom. Go's `nat.bit`.
    """
    var j = i // _W
    if j >= len(x):
        return 0
    return Int((x[j] >> Word(i % _W)) & 1)


def _set_bit[o: ImmOrigin](x: Span[Word, o], i: Int, b: Int) -> List[Word]:
    """`x` with its `i`th bit set to `b`, which has to be 0 or 1. Go's
    `nat.setBit`.

    Go panics on any other `b`; the check is in `Int.set_bit`, which is the
    only caller and the place a user's value arrives.
    """
    var j = i // _W
    var m = Word(1) << Word(i % _W)
    var n = len(x)

    if b == 0:
        var z = _clone(x)
        if j >= n:
            return z^
        z[j] &= ~m
        return _norm(z^)

    var size = n
    if j >= n:
        size = j + 1
    var z = List[Word](length=size, fill=0)
    for k in range(n):
        z[k] = x[k]
    z[j] |= m
    return z^


def _sticky[o: ImmOrigin](x: Span[Word, o], i: Int) -> Int:
    """`1` when any of the bottom `i` bits of `x` is set. Go's `nat.sticky`.

    The rounding of a `Float` is decided by this: it is what tells the
    difference between a value exactly on a halfway point and one just above
    it.
    """
    var j = i // _W
    if j >= len(x):
        if len(x) == 0:
            return 0
        return 1
    for k in range(j):
        if x[k] != 0:
            return 1
    # Go writes this as `x[j] << (_W - i%_W)`, which is a shift by the whole
    # width when `i` lands on a digit boundary and so is zero under Go's rule
    # and undefined under Mojo's. The guard is that case written out.
    var r = i % _W
    if r != 0 and (x[j] << Word(_W - r)) != 0:
        return 1
    return 0


def _and[
    o1: ImmOrigin, o2: ImmOrigin
](x: Span[Word, o1], y: Span[Word, o2]) -> List[Word]:
    """`x & y`. Go's `nat.and`."""
    var m = len(x)
    if len(y) < m:
        m = len(y)

    var z = List[Word](length=m, fill=0)
    for i in range(m):
        z[i] = x[i] & y[i]

    return _norm(z^)


def _and_not[
    o1: ImmOrigin, o2: ImmOrigin
](x: Span[Word, o1], y: Span[Word, o2]) -> List[Word]:
    """`x &^ y`, the bits of `x` that `y` does not have. Go's `nat.andNot`."""
    var m = len(x)
    var n = len(y)
    if n > m:
        n = m

    var z = List[Word](length=m, fill=0)
    for i in range(n):
        z[i] = x[i] & ~y[i]
    for i in range(n, m):
        z[i] = x[i]

    return _norm(z^)


def _or[
    o1: ImmOrigin, o2: ImmOrigin
](x: Span[Word, o1], y: Span[Word, o2]) -> List[Word]:
    """`x | y`. Go's `nat.or`."""
    var m = len(x)
    var n = len(y)
    var longer_is_x = True
    if m < n:
        var t = m
        m = n
        n = t
        longer_is_x = False

    var z = List[Word](length=m, fill=0)
    for i in range(n):
        z[i] = x[i] | y[i]
    for i in range(n, m):
        z[i] = x[i] if longer_is_x else y[i]

    return _norm(z^)


def _xor[
    o1: ImmOrigin, o2: ImmOrigin
](x: Span[Word, o1], y: Span[Word, o2]) -> List[Word]:
    """`x ^ y`. Go's `nat.xor`."""
    var m = len(x)
    var n = len(y)
    var longer_is_x = True
    if m < n:
        var t = m
        m = n
        n = t
        longer_is_x = False

    var z = List[Word](length=m, fill=0)
    for i in range(n):
        z[i] = x[i] ^ y[i]
    for i in range(n, m):
        z[i] = x[i] if longer_is_x else y[i]

    return _norm(z^)


def _trunc[o: ImmOrigin](x: Span[Word, o], n: Int) -> List[Word]:
    """`x` modulo two to the `n`. Go's `nat.trunc`."""
    var w = (n + _W - 1) // _W
    if len(x) < w:
        return _clone(x)

    var z = List[Word](length=w, fill=0)
    for i in range(w):
        z[i] = x[i]
    if n % _W != 0:
        z[w - 1] &= (Word(1) << Word(n % _W)) - 1

    return _norm(z^)


def _sub_mod_2n[
    o1: ImmOrigin, o2: ImmOrigin
](x: Span[Word, o1], y: Span[Word, o2], n: Int) -> List[Word]:
    """`(x - y)` modulo two to the `n`. Go's `nat.subMod2N`."""
    var xt = _trunc(x, n) if _bit_len(x) > n else _clone(x)
    var yt = _trunc(y, n) if _bit_len(y) > n else _clone(y)

    if _cmp(Span(xt), Span(yt)) >= 0:
        return _sub(Span(xt), Span(yt))

    # x - y is negative, and modulo 2ⁿ that is 1 + ^(y - x) truncated to n
    # bits. The complement is taken over a vector padded out to n bits first,
    # since the difference may be shorter than that.
    var z = _sub(Span(yt), Span(xt))
    while len(z) * _W < n:
        z.append(Word(0))
    for i in range(len(z)):
        z[i] = ~z[i]
    var t = _trunc(Span(z), n)
    return _add(Span(t), Span(_one()))


def _to_bytes[o: ImmOrigin](x: Span[Word, o]) -> List[UInt8]:
    """`x` as big endian bytes, as short as it can be. Go's `nat.bytes` with
    the buffer sized to fit.

    Zero comes back empty, which is what Go's `Int.Bytes` returns for it.
    """
    var n = (_bit_len(x) + 7) // 8
    var buf = List[UInt8](length=n, fill=0)
    var i = n
    for k in range(len(x)):
        var d = x[k]
        for _ in range(_S):
            i -= 1
            if i >= 0:
                buf[i] = UInt8(d & 0xFF)
            d >>= 8
    return buf^


def _fill_bytes[
    o1: ImmOrigin, o2: MutOrigin
](x: Span[Word, o1], buf: Span[UInt8, o2]) -> Bool:
    """Write `x` into `buf` big endian, zero padded, or answer `False` when it
    does not fit. Go's `nat.bytes`, which panics instead.

    `Int.fill_bytes` turns the `False` into a raise, because that is where the
    caller's buffer came from.
    """
    if (_bit_len(x) + 7) // 8 > len(buf):
        return False
    for i in range(len(buf)):
        buf[i] = 0
    var i = len(buf)
    for k in range(len(x)):
        var d = x[k]
        for _ in range(_S):
            i -= 1
            if i >= 0:
                buf[i] = UInt8(d & 0xFF)
            d >>= 8
    return True


def _set_bytes[o: ImmOrigin](buf: Span[UInt8, o]) -> List[Word]:
    """The number whose big endian bytes are `buf`. Go's `nat.setBytes`."""
    var z = List[Word](length=(len(buf) + _S - 1) // _S, fill=0)

    var i = len(buf)
    var k = 0
    while i >= _S:
        var d = Word(0)
        for j in range(_S):
            d = (d << 8) | Word(buf[i - _S + j])
        z[k] = d
        i -= _S
        k += 1
    if i > 0:
        var d = Word(0)
        var s = Word(0)
        while i > 0:
            d |= Word(buf[i - 1]) << s
            s += 8
            i -= 1
        z[len(z) - 1] = d

    return _norm(z^)
