"""Go's `TestExp`, `TestGcd`, `TestModInverse`, `TestModSqrt`, `TestJacobi`
and `TestSqrt`, from `int_test.go`.

These are the operations that work in a ring rather than on the number line, and
they are where Go's habit of returning a nil `Int` shows up: no modular inverse,
no modular square root, and a negative power of a number that has no inverse all
return nil there and raise here. A test for one of those asks that it raises
rather than reading a flag.
"""

from std.testing import assert_equal, assert_true

import core.math.big as big
from core.errors import matches
from core.errors.codes import ErrInvalidArgument

from tests.math.big._fixtures import p, pb


def _exp() -> List[List[String]]:
    """Go's `expTests`, as `x`, `y`, `m`, `out`. An empty `m` is Go's nil
    modulus and an empty `out` is Go's nil result, which is a raise here."""
    return [
        # y <= 0
        ["0", "0", "", "1"],
        ["1", "0", "", "1"],
        ["-10", "0", "", "1"],
        ["1234", "-1", "", "1"],
        ["1234", "-1", "0", "1"],
        ["17", "-100", "1234", "865"],
        ["2", "-100", "1234", ""],
        # m == 1
        ["0", "0", "1", "0"],
        ["1", "0", "1", "0"],
        ["-10", "0", "1", "0"],
        ["1234", "-1", "1", "0"],
        # misc
        ["5", "1", "3", "2"],
        ["5", "-7", "", "1"],
        ["-5", "-7", "", "1"],
        ["5", "0", "", "1"],
        ["-5", "0", "", "1"],
        ["5", "1", "", "5"],
        ["-5", "1", "", "-5"],
        ["-5", "1", "7", "2"],
        ["-2", "3", "2", "0"],
        ["5", "2", "", "25"],
        ["1", "65537", "2", "1"],
        [
            "0x8000000000000000",
            "2",
            "",
            "0x40000000000000000000000000000000",
        ],
        ["0x8000000000000000", "2", "6719", "4944"],
        ["0x8000000000000000", "3", "6719", "5447"],
        ["0x8000000000000000", "1000", "6719", "1603"],
        ["0x8000000000000000", "1000000", "6719", "3199"],
        # 3663 is the inverse of 3199 modulo 6719. Go issue 25865.
        ["0x8000000000000000", "-1000000", "6719", "3663"],
        [
            "0xffffffffffffffffffffffffffffffff",
            "0x12345678123456781234567812345678123456789",
            "0x01112222333344445555666677778889",
            "0x36168FA1DB3AAE6C8CE647E137F97A",
        ],
        [
            (
                "29384629384729834729836597263490172492874910265127462397645"
                "2561296529386529623947123987419328479238749827425612974619"
                "2347"
            ),
            "298472983472983471903246121093472394872319615612417471234712061",
            (
                "29834729834729834729347290846729561262544958723956495615629"
                "5692347298362592635981273423742893659124659013654982364921"
                "83464"
            ),
            (
                "23537740700184054162508175125554701713153216681790245129157"
                "1913913223215080558339085091858390694557492191314805888293"
                "46291"
            ),
        ],
        # Go issue 8822. A two thousand bit modulus, which is the size a
        # Diffie-Hellman group is and the only row here that reaches the
        # Montgomery path at its full width. The second of the pair is the
        # same calculation with a negative base.
        [
            (
                "11001289118363089646017359372117963499250546375269047542777928"
                "00610324687668875673576090568060464662435319686957275262328514"
                "04087554203740493176464281852700795553727635031156460546028675"
                "93662923894140940837479507194934267532831694565516466765025434"
                "90234831452562741851564658816095586283902205135365305294707313"
                "60847807427297278748034576438481974995482975700269269275025056"
                "34297079527299004267769780768565695459945235586892627059178884"
                "99877298939750506120639545559150377167750093126947750350815017"
                "57171218285189859019599195607008532262554207931489868543915528"
                "59459511723547532575574664944815966793196961286234040892865"
            ),
            (
                "0xB08FFB20760FFED58FADA86DFEF71AD72AA0FA763219618FE022C197E547"
                "08BB1191C66470250FCE8879487507CEE41381CA4D932F81C2B3F1AB20B539"
                "D50DCD"
            ),
            (
                "0xAC6BDB41324A9A9BF166DE5E1389582FAF72B6651987EE07FC3192943DB5"
                "6050A37329CBB4A099ED8193E0757767A13DD52312AB4B03310DCD7F48A9DA"
                "04FD50E8083969EDB767B0CF6095179A163AB3661A05FBD5FAAAE82918A996"
                "2F0B93B855F97993EC975EEAA80D740ADBF4FF747359D041D5C33EA71D281E"
                "446B14773BCA97B43A23FB801676BD207A436C6481F1D2B9078717461A5B9D"
                "32E688F87748544523B524B0D57D5EA77A2775D2ECFA032CFBDBF52FB37861"
                "60279004E57AE6AF874E7303CE53299CCC041C7BC308D82A5698F3A8D0C382"
                "71AE35F8E9DBFBB694B5C803D89F7AE435DE236D525F54759B65E372FCD68E"
                "F20FA7111F9E4AFF73"
            ),
            (
                "21484252197776302499639938883777710321993113097987201050501182"
                "90958135935761857956674655637258938536168361052473050904132885"
                "50665149633855225708948390358847130516401714741865487135466864"
                "76761306436434146475140156284389181808675016576845833340494848"
                "28368108888658421975055440806055676948662802902872072739329311"
                "16788263564804554339092335205041120744013761330771504712375494"
                "74149190242010469539006449596611576612573955754349042329130631"
                "12823463792478646658570348846054022847744085349339208625102122"
                "80870761247067788991796486552216637659939627246991352172121185"
                "35057766739392069738618682722216712319320435674779146070442"
            ),
        ],
        [
            (
                "-0x1BCE04427D8032319A89E5C4136456671AC620883F2C4139E57F91307C4"
                "85AD2D6204F4F87A58262652DB5DBBAC72B0613E51B835E7153BEC6068F5C8"
                "D696B74DBD18FEC316AEF73985CF0475663208EB46B4F17DD9DA55367B0332"
                "3E5491A70997B90C059FB34809E6EE55BCFBD5F2F52233BFE62E6AA9E4E26A"
                "1D4C2439883D14F2633D55D8AA66A1ACD5595E778AC3A280517F1157989E70"
                "C1A437B849F1877B779CC3CDDEDE2DAA6594A6C66D181A00A5F777EE60596D"
                "8773998F6E988DEAE4CCA60E4DDCF9590543C89F74F603259FCAD71660D302"
                "94FBBE6490300F78A9D63FA660DC9417B8B9DDA28BEB3977B621B988E23D4D"
                "954F322C3540541BC649ABD504C50FADFD9F0987D58A2BF689313A285E773F"
                "F02899A6EF887D1D4A0D2"
            ),
            (
                "0xB08FFB20760FFED58FADA86DFEF71AD72AA0FA763219618FE022C197E547"
                "08BB1191C66470250FCE8879487507CEE41381CA4D932F81C2B3F1AB20B539"
                "D50DCD"
            ),
            (
                "0xAC6BDB41324A9A9BF166DE5E1389582FAF72B6651987EE07FC3192943DB5"
                "6050A37329CBB4A099ED8193E0757767A13DD52312AB4B03310DCD7F48A9DA"
                "04FD50E8083969EDB767B0CF6095179A163AB3661A05FBD5FAAAE82918A996"
                "2F0B93B855F97993EC975EEAA80D740ADBF4FF747359D041D5C33EA71D281E"
                "446B14773BCA97B43A23FB801676BD207A436C6481F1D2B9078717461A5B9D"
                "32E688F87748544523B524B0D57D5EA77A2775D2ECFA032CFBDBF52FB37861"
                "60279004E57AE6AF874E7303CE53299CCC041C7BC308D82A5698F3A8D0C382"
                "71AE35F8E9DBFBB694B5C803D89F7AE435DE236D525F54759B65E372FCD68E"
                "F20FA7111F9E4AFF73"
            ),
            (
                "21484252197776302499639938883777710321993113097987201050501182"
                "90958135935761857956674655637258938536168361052473050904132885"
                "50665149633855225708948390358847130516401714741865487135466864"
                "76761306436434146475140156284389181808675016576845833340494848"
                "28368108888658421975055440806055676948662802902872072739329311"
                "16788263564804554339092335205041120744013761330771504712375494"
                "74149190242010469539006449596611576612573955754349042329130631"
                "12823463792478646658570348846054022847744085349339208625102122"
                "80870761247067788991796486552216637659939627246991352172121185"
                "35057766739392069738618682722216712319320435674779146070442"
            ),
        ],
        # Go issue 13907, where the modulus is one more than a power of two
        # times a power of two and the Montgomery path needs the carry.
        [
            "0xffffffff00000001",
            "0xffffffff00000001",
            "0xffffffff00000001",
            "0",
        ],
        [
            "0xffffffffffffffff00000001",
            "0xffffffffffffffff00000001",
            "0xffffffffffffffff00000001",
            "0",
        ],
        [
            "0xffffffffffffffffffffffff00000001",
            "0xffffffffffffffffffffffff00000001",
            "0xffffffffffffffffffffffff00000001",
            "0",
        ],
        [
            "0xffffffffffffffffffffffffffffffff00000001",
            "0xffffffffffffffffffffffffffffffff00000001",
            "0xffffffffffffffffffffffffffffffff00000001",
            "0",
        ],
        # The same modulus odd and even, which are the two halves of the
        # exponentiation: an odd modulus goes through Montgomery and an even
        # one through the split into the odd part and the power of two.
        [
            "2",
            (
                "0xB08FFB20760FFED58FADA86DFEF71AD72AA0FA763219618FE022C197E547"
                "08BB1191C66470250FCE8879487507CEE41381CA4D932F81C2B3F1AB20B539"
                "D50DCD"
            ),
            (
                "0xAC6BDB41324A9A9BF166DE5E1389582FAF72B6651987EE07FC3192943DB5"
                "6050A37329CBB4A099ED8193E0757767A13DD52312AB4B03310DCD7F48A9DA"
                "04FD50E8083969EDB767B0CF6095179A163AB3661A05FBD5FAAAE82918A996"
                "2F0B93B855F97993EC975EEAA80D740ADBF4FF747359D041D5C33EA71D281E"
                "446B14773BCA97B43A23FB801676BD207A436C6481F1D2B9078717461A5B9D"
                "32E688F87748544523B524B0D57D5EA77A2775D2ECFA032CFBDBF52FB37861"
                "60279004E57AE6AF874E7303CE53299CCC041C7BC308D82A5698F3A8D0C382"
                "71AE35F8E9DBFBB694B5C803D89F7AE435DE236D525F54759B65E372FCD68E"
                "F20FA7111F9E4AFF73"
            ),
            (
                "0x6AADD3E3E424D5B713FCAA8D8945B1E055166132038C57BBD2D51C833F0C"
                "5EA2007A2324CE514F8E8C2F008A2F36F44005A4039CB55830986F734C93DA"
                "F0EB4BAB54A6A8C7081864F44346E9BC6F0A3EB9F2C0146A00C6A05187D0C1"
                "01E1F2D038CDB70CB5E9E05A2D188AB6CBB46286624D4415E7D4DBFAD3BCC6"
                "009D915C406EED38F468B940F41E6BEDC0430DD78E6F19A7DA3A27498A4181"
                "E24D738B0072D8F6ADB8C9809A5B033A09785814FD9919F6EF9F83EEA519BE"
                "C593855C4C10CBEEC582D4AE0792158823B0275E6AEC35242740468FAF3D5C"
                "60FD1E376362B6322F78B7ED0CA1C5BBCD2B49734A56C0967A1D01A100932C"
                "837B91D592CE08ABFF"
            ),
        ],
        [
            "2",
            (
                "0xB08FFB20760FFED58FADA86DFEF71AD72AA0FA763219618FE022C197E547"
                "08BB1191C66470250FCE8879487507CEE41381CA4D932F81C2B3F1AB20B539"
                "D50DCD"
            ),
            (
                "0xAC6BDB41324A9A9BF166DE5E1389582FAF72B6651987EE07FC3192943DB5"
                "6050A37329CBB4A099ED8193E0757767A13DD52312AB4B03310DCD7F48A9DA"
                "04FD50E8083969EDB767B0CF6095179A163AB3661A05FBD5FAAAE82918A996"
                "2F0B93B855F97993EC975EEAA80D740ADBF4FF747359D041D5C33EA71D281E"
                "446B14773BCA97B43A23FB801676BD207A436C6481F1D2B9078717461A5B9D"
                "32E688F87748544523B524B0D57D5EA77A2775D2ECFA032CFBDBF52FB37861"
                "60279004E57AE6AF874E7303CE53299CCC041C7BC308D82A5698F3A8D0C382"
                "71AE35F8E9DBFBB694B5C803D89F7AE435DE236D525F54759B65E372FCD68E"
                "F20FA7111F9E4AFF72"
            ),
            (
                "0x7858794B5897C29F4ED0B40913416AB6C48588484E6A45F2ED3E26C941D8"
                "78E923575AAC434EE2750E6439A6976F9BB4D64CEDB2A53CE8D04DD48CADCD"
                "F8E46F22747C6B81C6CEA86C0D873FBF7CEF262BAAC43A522BD7F32F3CDAC5"
                "2B9337C77B3DCFB3DB3EDD80476331E82F4B1DF8EFDC1220C92656DFC9197B"
                "DC1877804E28D928A2A284B8DED506CBA304435C9D0133C246C98A7D890D1D"
                "E60CBC53A024361DA83A9B8775019083D22AC6820ED7C3C68F8E801DD4EC77"
                "9EE0A05C6EB682EF9840D285B838369BA7E148FA27691D524FAEAF7C6ECE2A"
                "4B99A294B9F2C241857B5B90CC8BFFCFCF18DFA7D676131D5CD3855A5A3E8E"
                "BFA0CDFADB4D198B4A"
            ),
        ],
    ]


def test_exp() raises:
    # slow: the last four rows raise a two thousand bit base to a five hundred
    # bit exponent
    # Go's `TestExp`, every row of it.
    for row in _exp():
        var x = p(row[0])
        var y = p(row[1])
        var m = big.Int()
        if row[2] != "":
            m = p(row[2])

        if row[3] == "":
            var raised = False
            try:
                _ = x.exp(y, m)
            except:
                raised = True
            assert_true(raised, row[0] + "^" + row[1] + " mod " + row[2])
            continue

        var want = p(row[3])
        assert_equal(
            x.exp(y, m).string(),
            want.string(),
            row[0] + "^" + row[1] + " mod " + row[2],
        )


def test_exp_agrees_with_repeated_multiplication() raises:
    # Not from Go. A small exponent worked out by multiplying in a loop is the
    # definition of a power, and it does not go anywhere near the windowed
    # square and multiply or the Montgomery path that `exp` uses.
    var bases: List[Int64] = [0, 1, 2, 3, 7, -2, -3, 255, 65537]
    var moduli: List[Int64] = [0, 1, 2, 3, 97, 1000, 65537]
    for b in bases:
        var x = big.Int(b)
        for mm in moduli:
            var m = big.Int(mm)
            for e in range(0, 12):
                var want = big.Int(Int64(1))
                for _ in range(e):
                    want = want.mul(x)
                if mm != 0:
                    want = want.mod(m)
                assert_equal(
                    x.exp(big.Int(Int64(e)), m).string(),
                    want.string(),
                    String(b) + "^" + String(e) + " mod " + String(mm),
                )


def _gcd() -> List[List[String]]:
    """Go's `gcdTests`, as `d`, `x`, `y`, `a`, `b`, where `d` is the divisor
    and `x` and `y` are the Bezout coefficients."""
    return [
        ["0", "0", "0", "0", "0"],
        ["7", "0", "1", "0", "7"],
        ["7", "0", "-1", "0", "-7"],
        ["11", "1", "0", "11", "0"],
        ["7", "-1", "-2", "-77", "35"],
        ["935", "-3", "8", "64515", "24310"],
        ["935", "-3", "-8", "64515", "-24310"],
        ["935", "3", "-8", "-64515", "-24310"],
        ["1", "-9", "47", "120", "23"],
        ["7", "1", "-2", "77", "35"],
        ["935", "-3", "8", "64515", "24310"],
        [
            "935000000000000000",
            "-3",
            "8",
            "64515000000000000000",
            "24310000000000000000",
        ],
        [
            "1",
            "-221",
            (
                "22059940471369027483332068679400581064239780177629666810348"
                "940098015901108344"
            ),
            (
                "98920366548084643601728869055592650835572950932266967461790"
                "948584315647051443"
            ),
            "991",
        ],
    ]


def test_gcd() raises:
    # Go's `TestGcd`. Go runs each row four times over the four combinations of
    # asking for the coefficients and not asking; here `gcd` is the one that
    # does not compute them and `gcd_ext` is the one that does, so each row
    # goes through both.
    for row in _gcd():
        var a = p(row[3])
        var b = p(row[4])
        assert_equal(a.gcd(b).string(), p(row[0]).string(), "gcd")

        var x = big.Int(Int64(1234567890))
        var y = big.Int(Int64(1234567890))
        var d = a.gcd_ext(b, x, y)
        assert_equal(d.string(), p(row[0]).string(), "gcd_ext divisor")
        assert_equal(x.string(), p(row[1]).string(), "gcd_ext x")
        assert_equal(y.string(), p(row[2]).string(), "gcd_ext y")

        # The coefficients are only worth anything if they satisfy the identity
        # they are named for.
        assert_equal(
            a.mul(x).add(b.mul(y)).string(), d.string(), "a*x + b*y = d"
        )


def test_gcd_is_symmetric_and_divides() raises:
    # Not from Go. The divisor does not care about the order or the signs of
    # its arguments, and it has to divide both of them exactly.
    for row in _gcd():
        var a = p(row[3])
        var b = p(row[4])
        var d = a.gcd(b)
        assert_equal(b.gcd(a).string(), d.string(), "order does not matter")
        assert_equal(
            a.neg().gcd(b.neg()).string(), d.string(), "sign does not matter"
        )
        if d.sign() != 0:
            assert_equal(a.rem(d).sign(), 0, "d divides a")
            assert_equal(b.rem(d).sign(), 0, "d divides b")


def test_mod_inverse() raises:
    # Go's `TestModInverse`, the table half. The inverse is checked by
    # multiplying rather than against a written down answer, which is how Go
    # writes it too.
    var rows: List[List[String]] = [
        ["1234567", "458948883992"],
        [
            "239487239847",
            (
                "2410312426921032588552076022197566074856950548502459942654"
                "1169419581088316826122288900938582613416146732271414779040"
                "1219650364895705058263194273070680500922306273474534107340"
                "6696246014589361659774041027169249453200378729434170325843"
                "7786591981437631937768598695240889401955773461198435453015"
                "4704374720774996976375008430892633929555996888245787241299"
                "3810129130294592999947926365264059284647209730384947211681"
                "434464714438488520940127459844288859336526896320919633919"
            ),
        ],
        # Go issue 16984, a negative element.
        ["-10", "13"],
        ["10", "-13"],
        ["-17", "-13"],
    ]
    var one = big.Int(Int64(1))
    for row in rows:
        var element = pb(row[0], 10)
        var modulus = pb(row[1], 10)
        var inverse = element.mod_inverse(modulus)
        assert_equal(
            inverse.mul(element).mod(modulus).string(),
            one.string(),
            row[0] + " inverse mod " + row[1],
        )


def test_mod_inverse_exhaustive() raises:
    # Go's `TestModInverse`, the exhaustive half. Every element of every ring
    # up to a hundred that has an inverse, checked by multiplying, and every
    # element that does not, checked by raising.
    var one = big.Int(Int64(1))
    for n in range(2, 100):
        var modulus = big.Int(Int64(n))
        for x in range(1, n):
            var element = big.Int(Int64(x))
            if element.gcd(modulus).cmp(one) != 0:
                var raised = False
                try:
                    _ = element.mod_inverse(modulus)
                except:
                    raised = True
                assert_true(
                    raised,
                    String(x) + " mod " + String(n) + " has no inverse",
                )
                continue
            var inverse = element.mod_inverse(modulus)
            assert_equal(
                inverse.mul(element).mod(modulus).string(),
                one.string(),
                String(x) + " inverse mod " + String(n),
            )


def test_mod_sqrt_exhaustive() raises:
    # Go's `TestModSqrt`, the exhaustive half. For every odd prime under a
    # hundred, every element is squared and the square root taken back, and
    # then every element that is not a square is asked for its root and has to
    # refuse. Go returns nil there; this raises.
    for n in range(3, 100):
        var modulus = big.Int(Int64(n))
        if not modulus.probably_prime(10):
            continue

        var is_square = List[Bool](length=n, fill=False)
        for x in range(1, n):
            var element = big.Int(Int64(x))
            var square = element.mul(element).mod(modulus)
            var root = square.mod_sqrt(modulus)
            # The root Go picks is one of the two, so squaring is the check
            # rather than comparing against the element.
            assert_equal(
                root.mul(root).mod(modulus).string(),
                square.string(),
                String(x) + " mod " + String(n),
            )
            assert_true(root.sign() >= 0, "the root is not negative")
            assert_true(root.cmp(modulus) < 0, "the root is reduced")
            is_square[Int(square.uint64())] = True

        for x in range(1, n):
            if is_square[x]:
                continue
            var square = big.Int(Int64(x))
            var raised = False
            try:
                _ = square.mod_sqrt(modulus)
            except:
                raised = True
            assert_true(raised, String(x) + " is not a square mod " + String(n))


def test_mod_sqrt_large_primes() raises:
    # Go's `TestModSqrt`, the random half, written out with fixed elements
    # rather than a generator. The three primes pick out the three branches:
    # `p = 3 mod 4`, `p = 5 mod 8`, and Tonelli-Shanks for everything else.
    # Go's own comment is that the last branch is the one nothing else reaches.
    var moduli: List[String] = [
        "13756265695458089029",  # 3 mod 4
        "13496181268022124907",  # 3 mod 4
        "10953742525620032441",  # 1 mod 8, Tonelli-Shanks
        "17908251027575790097",  # 1 mod 16, Tonelli-Shanks
        "18699199384836356663",  # 3 mod 4, Go issue 638
        (
            "98920366548084643601728869055592650835572950932266967461790948"
            "584315647051443"
        ),
        (  # Curve25519, 5 mod 8
            "57896044618658097711785492504343953926634992332820282019728792"
            "003956564819949"
        ),
    ]
    var elements: List[Int64] = [1, 2, 3, 4, 12345, 1000000007]
    for s in moduli:
        var modulus = pb(s, 10)
        for e in elements:
            var element = big.Int(e)
            # Squaring first guarantees there is a root to find, whatever the
            # element was.
            var square = element.mul(element).mod(modulus)
            var root = square.mod_sqrt(modulus)
            assert_equal(
                root.mul(root).mod(modulus).string(), square.string(), s
            )
            assert_true(root.sign() >= 0 and root.cmp(modulus) < 0, "reduced")

            # A negative element is reduced first, which is the range Go's own
            # test covers by drawing from `[-mod, 3*mod)`.
            var shifted = square.sub(modulus)
            var shifted_root = shifted.mod_sqrt(modulus)
            assert_equal(shifted_root.string(), root.string(), "negative input")


def test_jacobi() raises:
    # Go's `TestJacobi`. The symbol is defined for an odd second argument of
    # either sign, and the table covers every combination of signs.
    var rows: List[List[Int64]] = [
        [0, 1, 1],
        [0, -1, 1],
        [1, 1, 1],
        [1, -1, 1],
        [0, 5, 0],
        [1, 5, 1],
        [2, 5, -1],
        [-2, 5, -1],
        [2, -5, -1],
        [-2, -5, 1],
        [3, 5, -1],
        [5, 5, 0],
        [-5, 5, 0],
        [6, 5, 1],
        [6, -5, 1],
        [-6, 5, 1],
        [-6, -5, -1],
    ]
    for row in rows:
        var x = big.Int(row[0])
        var y = big.Int(row[1])
        assert_equal(
            Int64(big.jacobi(x, y)),
            row[2],
            "jacobi " + String(row[0]) + " " + String(row[1]),
        )


def test_jacobi_matches_euler() raises:
    # Not from Go. For an odd prime the symbol is the Legendre symbol, which
    # Euler's criterion computes as `x^((p-1)/2) mod p` read as 0, 1 or -1.
    # That is a completely different calculation from the reciprocity loop.
    var primes: List[Int64] = [3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 97, 101]
    var one = big.Int(Int64(1))
    var two = big.Int(Int64(2))
    for q in primes:
        var y = big.Int(q)
        var e = y.sub(one).quo(two)
        for xi in range(-20, 21):
            var x = big.Int(Int64(xi))
            var want = 0
            var raised = x.mod(y).sign() == 0
            if not raised:
                var r = x.mod(y).exp(e, y)
                if r.cmp(one) == 0:
                    want = 1
                else:
                    want = -1
            assert_equal(
                big.jacobi(x, y),
                want,
                "jacobi " + String(xi) + " " + String(q),
            )


def test_jacobi_rejects_an_even_second_argument() raises:
    # Go's `TestJacobiPanic`. The symbol is not defined for an even modulus.
    var x = big.Int(Int64(1))
    var evens: List[Int64] = [0, 2, -2, 4, 100]
    for e in evens:
        var raised = False
        var err = Error()
        try:
            _ = big.jacobi(x, big.Int(e))
        except err_:
            raised = True
            err = err_
        assert_true(raised, "jacobi with " + String(e))
        assert_true(matches(err, ErrInvalidArgument))


def test_sqrt_small() raises:
    # slow: ten thousand square roots, one per number
    # Go's `TestSqrt`, the first loop. The root is tracked alongside rather
    # than computed, so the expected answer never goes through the code it is
    # checking.
    var root = 0
    for i in range(10000):
        if (root + 1) * (root + 1) <= i:
            root += 1
        assert_equal(big.Int(Int64(i)).sqrt().int64(), Int64(root), String(i))


def test_sqrt_powers_of_ten() raises:
    # Go's `TestSqrt`, the second loop. Numbers far past what a machine integer
    # holds, where the answer is known because the exponent is even.
    for i in range(0, 1000, 10):
        var n = pb("1" + "0" * i, 10)
        var want = pb("1" + "0" * (i // 2), 10)
        assert_equal(n.sqrt().string(), want.string(), "1e" + String(i))


def test_sqrt_brackets_the_answer() raises:
    # Not from Go. The floor of the square root is defined by two inequalities,
    # and checking both catches an off by one that a table of exact squares
    # never reaches.
    var values: List[String] = [
        "0",
        "1",
        "2",
        "3",
        "8",
        "9",
        "10",
        "18446744073709551615",
        "18446744073709551616",
        "18446744073709551617",
        "340282366920938463463374607431768211455",
        "298472983472983471903246121093472394872319615612417471234712061",
    ]
    var one = big.Int(Int64(1))
    for s in values:
        var n = p(s)
        var r = n.sqrt()
        assert_true(r.mul(r).cmp(n) <= 0, s + ": r*r <= n")
        var up = r.add(one)
        assert_true(up.mul(up).cmp(n) > 0, s + ": (r+1)*(r+1) > n")


def test_sqrt_rejects_a_negative_number() raises:
    # Go panics with "square root of negative number".
    var values: List[Int64] = [-1, -2, -100]
    for v in values:
        var raised = False
        var err = Error()
        try:
            _ = big.Int(v).sqrt()
        except e:
            raised = True
            err = e
        assert_true(raised, "sqrt " + String(v))
        assert_true(matches(err, ErrInvalidArgument))
