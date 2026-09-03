"""Go's `TestProbablyPrime`, from `prime_test.go`.

The test is a primality test, so it can be wrong in two directions and the two
tables are there to catch each one. `primes` are numbers that must always come
back true, and a false there is a bug that no amount of rounds would fix. The
composites are the other direction, and most of them were chosen by somebody who
wanted a specific test to fail: strong pseudoprimes to every small base, and
extra strong Lucas pseudoprimes, which is why a number as small as 989 is in
there next to numbers of two hundred digits.

The test Go runs is Baillie-PSW, which is a few Miller-Rabin rounds followed by
a Lucas test, and no composite is known to pass it. The rounds argument only
adds Miller-Rabin rounds on top, so zero rounds is still the whole Baillie-PSW
test and every composite here has to fail at zero rounds too.
"""

from std.testing import assert_equal, assert_false, assert_true

import core.math.big as big
from core.errors import matches
from core.errors.codes import ErrInvalidArgument

from tests.math.big._fixtures import pb


def _primes() -> List[String]:
    """Go's `primes`."""
    return [
        "2",
        "3",
        "5",
        "7",
        "11",
        "13756265695458089029",
        "13496181268022124907",
        "10953742525620032441",
        "17908251027575790097",
        # Go issue 638.
        "18699199384836356663",
        (
            "98920366548084643601728869055592650835572950932266967461790948"
            "584315647051443"
        ),
        (
            "94560208308847015747498523884063394671606671904944666360068158"
            "221458669711639"
        ),
        # https://primes.utm.edu/lists/small/small3.html
        (
            "44941799905544149399470929709310851301537378704955849920549234"
            "78717299275731182628115083866559982990745669743737114725606550"
            "26288668094291699357843464363003144674940345912431129144354948"
            "751003607115263071543163"
        ),
        (
            "23097585999320415066642353898855783955556024392906541543498090"
            "42583105307530067238571397423346401225335985175976748070966489"
            "05501653461687601339782814316124971547968912893214002992086353"
            "183070342498989426570593"
        ),
        (
            "55217120996659062215404232070193333791252654621211696555634954"
            "03888449493493629943498064604536961775110765377745550377067893"
            "607246020694972959780839151452457728855382113555867743022746090"
            "187341871655890805971735385789993"
        ),
        (
            "20395687835640197740576586692903457728019399331434826309477264"
            "64532830627227012776329366160631440881733123728826771238795387"
            "09400158306567338328279154499698366071906766440037074217117805"
            "690872792848149112022286332144876183376326512083574821647933992"
            "961249917319836219304274280243803104015000563790123"
        ),
        # The ECC primes from https://tools.ietf.org/html/draft-ladd-safecurves-02
        # Curve1174, which is 2^251 - 9.
        (
            "36185027886661311069865932815214971204146870208012676262330495"
            "00247285301239"
        ),
        # Curve25519, which is 2^255 - 19.
        (
            "57896044618658097711785492504343953926634992332820282019728792"
            "003956564819949"
        ),
        # E-382, which is 2^382 - 105.
        (
            "98505015490986198030697600250359034512699348176163616669870733"
            "51061430442874302652853566563721228910201656997576599"
        ),
        # Curve41417, which is 2^414 - 17.
        (
            "42307582002575910332922579714097346549017899709713998034217522"
            "897561970639123926132812109468141778230245837569601494931472367"
        ),
        # E-521, which is 2^521 - 1.
        (
            "68647976601306097149819007990813932172694353001433054093944634"
            "59185543183397656052122559640661454554977296311391480858037121"
            "987999716643812574028291115057151"
        ),
    ]


def _composites() -> List[String]:
    """Go's `composites`."""
    return [
        "0",
        "1",
        (
            "21284175091214687912771199898307297748211672914763848041968395"
            "774954376176754"
        ),
        (
            "60847666549219189074279002435093723809542900991725592904327444"
            "50051395395951"
        ),
        (
            "84594350493221918389213352992032324280367711247940675652888030"
            "554255915464401"
        ),
        "82793403787388584738507275144194252681",
        # Arnault, "Rabin-Miller Primality Test: Composite Numbers Which Pass
        # It". A strong pseudoprime to every prime base from 2 through 29.
        "1195068768795265792518361315725116351898245581",
        # A strong pseudoprime to every prime base up to 200, which is what
        # makes a fixed set of bases the wrong way to write this test.
        (
            "80383745745363949125707961434194210813883768828755814583748891"
            "75222974273765333652186502336163960045457915042023603208766569"
            "96676098728404396540823292873879185086916685732826776177102938"
            "96977394701670823042868710999743997654414484534115587245063340"
            "92790222752962294149842306881685404326457534018329786111298960"
            "644845216191652872597534901"
        ),
        # The extra strong Lucas pseudoprimes, https://oeis.org/A217719. These
        # are here because the Lucas half of Baillie-PSW is what catches them.
        "989",
        "3239",
        "5777",
        "10877",
        "27971",
        "29681",
        "30739",
        "31631",
        "39059",
        "72389",
        "73919",
        "75077",
        "100127",
        "113573",
        "125249",
        "137549",
        "137801",
        "153931",
        "155819",
        "161027",
        "162133",
        "189419",
        "218321",
        "231703",
        "249331",
        "370229",
        "429479",
        "430127",
        "459191",
        "473891",
        "480689",
        "600059",
        "621781",
        "632249",
        "635627",
        "3673744903",
        "3281593591",
        "2385076987",
        "2738053141",
        "2009621503",
        "1502682721",
        "255866131",
        "117987841",
        "587861",
        "6368689",
        "8725753",
        "80579735209",
        "105919633",
    ]


def test_primes() raises:
    # slow: twenty Miller-Rabin rounds on numbers up to five hundred bits
    # Go's `TestProbablyPrime`, the first loop. Twenty rounds, one round and
    # zero rounds all have to agree, because zero rounds is still the whole
    # Baillie-PSW test and a prime passes that unconditionally.
    for s in _primes():
        var n = pb(s, 10)
        assert_true(n.probably_prime(20), s + " at twenty rounds")
        assert_true(n.probably_prime(1), s + " at one round")
        assert_true(n.probably_prime(0), s + " at zero rounds")


def test_composites() raises:
    # slow: the same rounds against numbers built to survive them
    # Go's `TestProbablyPrime`, the second loop.
    for s in _composites():
        var n = pb(s, 10)
        assert_false(n.probably_prime(20), s + " at twenty rounds")
        assert_false(n.probably_prime(1), s + " at one round")
        assert_false(n.probably_prime(0), s + " at zero rounds")


def test_small_numbers() raises:
    # Not from Go. Every number under a thousand against a sieve, which covers
    # the paths for the small primes and the divisibility shortcut that no
    # number in either table above reaches.
    var sieve = List[Bool](length=1000, fill=True)
    sieve[0] = False
    sieve[1] = False
    for i in range(2, 1000):
        if not sieve[i]:
            continue
        for j in range(i * i, 1000, i):
            sieve[j] = False

    for i in range(1000):
        assert_equal(big.Int(Int64(i)).probably_prime(20), sieve[i], String(i))


def test_negative_numbers_are_not_prime() raises:
    # Go's `ProbablyPrime` returns false for anything not positive, and its
    # documentation says so rather than leaving it to the reader.
    var values: List[Int64] = [-1, -2, -3, -7, -11, -1000003]
    for v in values:
        assert_false(big.Int(v).probably_prime(20), String(v))


def test_negative_rounds_raise() raises:
    # Go panics for a negative round count and accepts zero, which asks for
    # Baillie-PSW on its own.
    var n = big.Int(Int64(11))
    assert_true(n.probably_prime(0), "zero rounds is allowed")
    assert_true(n.probably_prime(1), "one round is allowed")

    var raised = False
    var err = Error()
    try:
        _ = n.probably_prime(-1)
    except e:
        raised = True
        err = e
    assert_true(raised, "a negative round count has to raise")
    assert_true(matches(err, ErrInvalidArgument))
