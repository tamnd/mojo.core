"""Go's `TestFloatSqrt64`, `TestFloatSqrt` and `TestFloatSqrtSpecial`, from
`sqrt_test.go`.

Two ways of checking a square root without a second square root to compare
against. At fifty three bits the answer has to be the one the machine gives,
which is a different algorithm reaching the same number. Above that the answer
is squared again and the distance back to the number it came from has to be
smaller than the last bit of the precision asked for, which is what a correctly
rounded root means and needs nothing to compare against at all.

The long decimal expansions in the second test are Go's, generated on Wolfram
Alpha at three hundred and fifty digits, which is a thousand binary digits and
so covers every precision the test runs at.
"""

from std.testing import assert_equal, assert_true

from core.math import inf, sqrt
from core.math.rand import new, new_pcg
from core.strconv import format_int
import core.math.big as big


def _prec_list() -> List[Int]:
    """The precisions Go runs the square root over. Go's list in
    `TestFloatSqrt`.

    The machine widths, the numbers on either side of them, and a few well
    above where the iteration has to have converged.
    """
    var out: List[Int] = [
        24,
        53,
        64,
        65,
        100,
        128,
        129,
        200,
        256,
        400,
        600,
        800,
        1000,
    ]
    return out^


def test_sqrt_at_53_bits_matches_float64() raises:
    # Go's `TestFloatSqrt64`. At a `Float64` precision the answer has to be
    # the machine's own square root, bit for bit, on every number.
    #
    # Go draws a hundred thousand numbers and stops at a hundred under `-short`.
    # This draws ten thousand, which is enough to be sure and quick enough to
    # sit in a suite that runs on every change. The generator is seeded, so a
    # failure here is the same failure next time.
    var r = new(new_pcg(1, 2))
    for _ in range(10000):
        var x = r.float64()

        var f = big.Float()
        f.set_prec(53)
        f.set_float64(x)
        var got = f.sqrt(53)

        var want = big.Float()
        want.set_prec(53)
        want.set_float64(sqrt(x))
        assert_equal(got.cmp(want), 0, got.string() + " " + want.string())


def test_sqrt() raises:
    # Go's `TestFloatSqrt`. Each row is checked twice: against the expansion
    # Go's table holds, and by squaring the answer and measuring how far it
    # landed from the number it came from.
    var xs: List[String] = [
        "0.03125",
        "0.125",
        "0.5",
        "2.0",
        "3.0",
        "4.0",
        # Powers of two, where the root is exact and the exponent halves.
        "1p512",
        "4p1024",
        "9p2048",
        "1p-1024",
        "4p-2048",
        "9p-4096",
    ]
    var wants: List[String] = [
        _sqrt_0_03125(),
        _sqrt_0_125(),
        _sqrt_0_5(),
        _sqrt_2(),
        _sqrt_3(),
        "2.0",
        "1p256",
        "2p512",
        "3p1024",
        "1p-512",
        "2p-1024",
        "3p-2048",
    ]
    var precs = _prec_list()
    for i in range(len(xs)):
        for prec in precs:
            var label = xs[i] + " at " + format_int(Int64(prec), 10)

            var x = big.Float()
            x.set_prec(prec)
            _ = x.parse(xs[i], 10)

            var got = x.sqrt(prec)

            var want = big.Float()
            want.set_prec(prec)
            _ = want.parse(wants[i], 10)
            assert_equal(got.cmp(want), 0, label)

            # The squaring check, which needs no table at all. If `got` is the
            # root of `x` to `prec` bits then `got` is the true root plus some
            # `k` smaller than two to the minus `prec`, so squaring gives
            # `x + 2k√x + k²` and the distance back to `x` is about `2k√x`,
            # which is under two to the minus `prec` plus one times the root.
            # The `k²` term is small enough to ignore.
            #
            # The intermediate steps carry thirty two guard bits so that the
            # rounding in the check cannot be mistaken for error in the root.
            var sq = got.mul(got, prec + 32)
            var diff = sq.sub(x)
            var err = diff.abs()
            err.set_prec(prec)

            var one = big.Float()
            one.set_prec(prec)
            one.set_int64(1)
            var ulp = big.Float()
            ulp.set_mant_exp(one, -prec + 1)
            var max_err = ulp.mul(got)

            assert_true(err.cmp(max_err) < 0, label)


def test_sqrt_of_a_special_value() raises:
    # Go's `TestFloatSqrtSpecial`. Both zeros and a positive infinity come
    # back as themselves, sign and all. Go reads the `neg` and `form` fields
    # directly; from outside the package the sign bit and the infinity test say
    # the same thing.
    var zero = big.Float()
    zero.set_float64(0.0)
    var got = zero.sqrt()
    assert_equal(got.sign(), 0, "sqrt of a zero")
    assert_true(not got.signbit(), "sqrt of a zero keeps its sign")

    var neg_zero = big.Float()
    neg_zero.set_float64(-0.0)
    got = neg_zero.sqrt()
    assert_equal(got.sign(), 0, "sqrt of a negative zero")
    assert_true(got.signbit(), "sqrt of a negative zero keeps its sign")

    var infinity = big.Float()
    infinity.set_float64(inf(1))
    got = infinity.sqrt()
    assert_true(got.is_inf(), "sqrt of an infinity")
    assert_true(not got.signbit(), "sqrt of an infinity keeps its sign")


# The expansions below are Go's, three hundred and fifty decimal digits each.
# They are functions rather than table entries because a single line that long
# is not readable and a wrapped string literal cannot sit in a list literal
# without hiding the rest of the row.


def _sqrt_0_03125() -> String:
    return String(
        "0.17677669529663688110021109052621225982120898442211850914708496724"
        "884155980776337985629844179095519659187673077886403712811560450698"
        "134215158051518713749197892665283324093819909447499381264409775757"
        "143376369499645074628431682460775184106467733011114982619404115381"
        "053858929018135497032545349940642599871090667456829147610370507757"
        "690729404938184321879"
    )


def _sqrt_0_125() -> String:
    return String(
        "0.35355339059327376220042218105242451964241796884423701829416993449"
        "768311961552675971259688358191039318375346155772807425623120901396"
        "268430316103037427498395785330566648187639818894998762528819551514"
        "286752738999290149256863364921550368212935466022229965238808230762"
        "107717858036270994065090699881285199742181334913658295220741015515"
        "381458809876368643757"
    )


def _sqrt_0_5() -> String:
    return String(
        "0.70710678118654752440084436210484903928483593768847403658833986899"
        "536623923105351942519376716382078636750692311545614851246241802792"
        "536860632206074854996791570661133296375279637789997525057639103028"
        "573505477998580298513726729843100736425870932044459930477616461524"
        "215435716072541988130181399762570399484362669827316590441482031030"
        "762917619752737287514"
    )


def _sqrt_2() -> String:
    return String(
        "1.41421356237309504880168872420969807856967187537694807317667973799"
        "073247846210703885038753432764157273501384623091229702492483605585"
        "073721264412149709993583141322266592750559275579995050115278206057"
        "147010955997160597027453459686201472851741864088919860955232923048"
        "430871432145083976260362799525140798968725339654633180882964062061"
        "52583523950547457503"
    )


def _sqrt_3() -> String:
    return String(
        "1.73205080756887729352744634150587236694280525381038062805580697945"
        "193301690880003708114618675724857567562614141540670302996994509499"
        "895247881165551209437364852809323190230558206797482010108467492326"
        "501531234326690332288665067225466892183797122704713166036786158801"
        "904998653737985938946765034750657605075661834812960610094760218719"
        "03250831458295239598"
    )
