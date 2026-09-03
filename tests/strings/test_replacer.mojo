"""Many replacements in one pass. Go's `replace_test.go`.

Go's table, near enough in full. It is worth transcribing carefully because a
trie with compressed edges has four cases in its insert and the tests are what
tell them apart: `gen1` has pairwise common prefixes and no overall one, `gen2`
has none at all, `gen3` has one shared by every key, and `foo1` through `foo4`
walk the edge splitting code with keys that agree for four bytes and then
disagree in the fifth.

Two of Go's groups are missing. `genAll` maps all 256 byte values to one string
and cannot be written here, because the keys go through a `String`, and
`tests/bytes` is where input that is not text belongs. Go's tests on which of
its four implementations got picked are not ported either, since there is one
implementation.
"""

from std.testing import assert_equal

from core.strings import Builder, new_replacer


def pairs(items: List[Tuple[String, String]]) -> List[Tuple[String, String]]:
    """The list as it is. A name for what a replacer is built from."""
    return items.copy()


def test_no_pairs() raises:
    """Go's `nop`. A replacer with nothing to do copies its argument."""
    var nop = new_replacer(List[Tuple[String, String]]())
    assert_equal(nop.replace("abc"), "abc")
    assert_equal(nop.replace(""), "")


def test_single_pair() raises:
    """Go's `abcMatcher` and `noHello`.

    The second is Go's issue 6659: replacing with the empty string is a
    deletion, and the bug it was filed for was dropping the text around it.
    """
    var abc = new_replacer(pairs([(String("abc"), String("[match]"))]))
    assert_equal(abc.replace(""), "")
    assert_equal(abc.replace("ab"), "ab")
    assert_equal(abc.replace("abc"), "[match]")
    assert_equal(abc.replace("abcd"), "[match]d")
    assert_equal(abc.replace("cabcabcdabca"), "c[match][match]d[match]a")

    var no_hello = new_replacer(pairs([(String("Hello"), String(""))]))
    assert_equal(no_hello.replace("Hello"), "")
    assert_equal(no_hello.replace("Hellox"), "x")
    assert_equal(no_hello.replace("xHello"), "x")
    assert_equal(no_hello.replace("xHellox"), "xx")


def test_html_escaping() raises:
    """Go's `htmlEscaper` and `htmlUnescaper`, which is why this type exists.

    Escaping with five calls to `replace_all` is wrong in a way that is easy to
    miss: whichever order they run in, one pass sees the ampersands the pass
    before it wrote. One pass cannot.
    """
    var escaper = new_replacer(
        pairs(
            [
                (String("&"), String("&amp;")),
                (String("<"), String("&lt;")),
                (String(">"), String("&gt;")),
                (String('"'), String("&quot;")),
                (String("'"), String("&apos;")),
            ]
        )
    )
    assert_equal(
        escaper.replace("<b>HTML's neat</b>"),
        "&lt;b&gt;HTML&apos;s neat&lt;/b&gt;",
    )
    assert_equal(escaper.replace("&amp;"), "&amp;amp;")
    assert_equal(escaper.replace(""), "")

    var unescaper = new_replacer(
        pairs(
            [
                (String("&amp;"), String("&")),
                (String("&lt;"), String("<")),
                (String("&gt;"), String(">")),
                (String("&quot;"), String('"')),
                (String("&apos;"), String("'")),
            ]
        )
    )
    assert_equal(unescaper.replace("&amp;amp;"), "&amp;")
    assert_equal(
        unescaper.replace("&lt;b&gt;HTML&apos;s neat&lt;/b&gt;"),
        "<b>HTML's neat</b>",
    )
    assert_equal(unescaper.replace(""), "")


def test_earlier_pairs_win() raises:
    """Go's duplicate key cases. The first pair for a key is the one that runs.

    And it is argument order rather than length, which is the part that
    surprises: `a` before `aa` replaces one character at a time, and `aaa`
    before `aa` before `a` takes the longest bite it can.
    """
    assert_equal(
        new_replacer(
            pairs([(String("a"), String("1")), (String("a"), String("2"))])
        ).replace("brad"),
        "br1d",
    )
    assert_equal(
        new_replacer(
            pairs([(String("a"), String("11")), (String("a"), String("22"))])
        ).replace("brad"),
        "br11d",
    )
    assert_equal(
        new_replacer(
            pairs(
                [
                    (String("a"), String("1")),
                    (String("aa"), String("2")),
                    (String("aaa"), String("3")),
                ]
            )
        ).replace("aaaa"),
        "1111",
    )
    assert_equal(
        new_replacer(
            pairs(
                [
                    (String("aaa"), String("3")),
                    (String("aa"), String("2")),
                    (String("a"), String("1")),
                ]
            )
        ).replace("aaaa"),
        "31",
    )


def test_pairs_do_not_feed_each_other() raises:
    """One pass, so what a replacement writes is never looked at again.

    Two calls to `replace_all` in this order give `cc`. One replacer gives
    `bc`, and that is the whole point of it.
    """
    var r = new_replacer(
        pairs([(String("a"), String("b")), (String("b"), String("c"))])
    )
    assert_equal(r.replace("ab"), "bc")
    assert_equal(r.replace("aaa"), "bbb")


def test_variable_length_keys() raises:
    """Go's `gen1`, which has pairwise common prefixes and no overall one."""
    var gen1 = new_replacer(
        pairs(
            [
                (String("aaa"), String("3[aaa]")),
                (String("aa"), String("2[aa]")),
                (String("a"), String("1[a]")),
                (String("i"), String("i")),
                (String("longerst"), String("most long")),
                (String("longer"), String("medium")),
                (String("long"), String("short")),
                (String("xx"), String("xx")),
                (String("x"), String("X")),
                (String("X"), String("Y")),
                (String("Y"), String("Z")),
            ]
        )
    )
    assert_equal(gen1.replace("fooaaabar"), "foo3[aaa]b1[a]r")
    assert_equal(
        gen1.replace("long, longerst, longer"), "short, most long, medium"
    )
    assert_equal(gen1.replace("xxxxx"), "xxxxX")
    assert_equal(gen1.replace("XiX"), "YiY")
    assert_equal(gen1.replace(""), "")


def test_keys_with_nothing_in_common() raises:
    """Go's `gen2`, where the trie is a table at the root and nothing else."""
    var gen2 = new_replacer(
        pairs(
            [
                (String("roses"), String("red")),
                (String("violets"), String("blue")),
                (String("sugar"), String("sweet")),
            ]
        )
    )
    assert_equal(
        gen2.replace("roses are red, violets are blue..."),
        "red are red, blue are blue...",
    )
    assert_equal(gen2.replace(""), "")


def test_keys_with_a_common_prefix() raises:
    """Go's `gen3`, which is where the edge splitting gets exercised.

    Every key starts with `abra`, so the trie holds that once and branches
    after it, and the last row is three strings that get most of the way down
    and match nothing.
    """
    var gen3 = new_replacer(
        pairs(
            [
                (String("abracadabra"), String("poof")),
                (String("abracadabrakazam"), String("splat")),
                (String("abraham"), String("lincoln")),
                (String("abrasion"), String("scrape")),
                (String("abraham"), String("isaac")),
            ]
        )
    )
    assert_equal(gen3.replace("abracadabrakazam abraham"), "poofkazam lincoln")
    assert_equal(gen3.replace("abrasion abracad"), "scrape abracad")
    assert_equal(gen3.replace("abba abram abrasive"), "abba abram abrasive")
    assert_equal(gen3.replace(""), "")


def test_keys_that_split_in_the_last_byte() raises:
    """Go's `foo1` through `foo4`, four shapes of the same near miss."""
    var foo1 = new_replacer(
        pairs(
            [
                (String("foo1"), String("A")),
                (String("foo2"), String("B")),
                (String("foo3"), String("C")),
            ]
        )
    )
    assert_equal(foo1.replace("fofoofoo12foo32oo"), "fofooA2C2oo")
    assert_equal(foo1.replace(""), "")

    var foo2 = new_replacer(
        pairs(
            [
                (String("foo1"), String("A")),
                (String("foo2"), String("B")),
                (String("foo31"), String("C")),
                (String("foo32"), String("D")),
            ]
        )
    )
    assert_equal(foo2.replace("fofoofoo12foo32oo"), "fofooA2Doo")

    var foo3 = new_replacer(
        pairs(
            [
                (String("foo11"), String("A")),
                (String("foo12"), String("B")),
                (String("foo31"), String("C")),
                (String("foo32"), String("D")),
            ]
        )
    )
    assert_equal(foo3.replace("fofoofoo12foo32oo"), "fofooBDoo")

    var foo4 = new_replacer(
        pairs([(String("foo12"), String("B")), (String("foo32"), String("D"))])
    )
    assert_equal(foo4.replace("fofoofoo12foo32oo"), "fofooBDoo")


def test_empty_key() raises:
    """Go's `blank` cases. An empty key matches between every pair of runes.

    Including before the first and after the last, and including in an empty
    string, which is why `blankToX1` on `""` is `X` and not `""`. It matches
    once in each gap and not twice, which is the flag the search carries from
    one position to the next.
    """
    var blank_to_x = new_replacer(pairs([(String(""), String("X"))]))
    assert_equal(blank_to_x.replace("foo"), "XfXoXoX")
    assert_equal(blank_to_x.replace(""), "X")

    var blank_twice = new_replacer(
        pairs([(String(""), String("X")), (String(""), String(""))])
    )
    assert_equal(blank_twice.replace("foo"), "XfXoXoX")
    assert_equal(blank_twice.replace(""), "X")

    # An empty key that wins over a real one, and the same pair the other way
    # round, which are different answers and both of them Go's.
    var high = new_replacer(
        pairs([(String(""), String("X")), (String("o"), String("O"))])
    )
    assert_equal(high.replace("oo"), "XOXOX")
    assert_equal(high.replace("ii"), "XiXiX")
    assert_equal(high.replace("oiio"), "XOXiXiXOX")
    assert_equal(high.replace("iooi"), "XiXOXOXiX")
    assert_equal(high.replace(""), "X")

    var low = new_replacer(
        pairs([(String("o"), String("O")), (String(""), String("X"))])
    )
    assert_equal(low.replace("oo"), "OOX")
    assert_equal(low.replace("ii"), "XiXiX")
    assert_equal(low.replace("oiio"), "OXiXiOX")
    assert_equal(low.replace("iooi"), "XiOOXiX")
    assert_equal(low.replace(""), "X")

    var noop1 = new_replacer(pairs([(String(""), String(""))]))
    assert_equal(noop1.replace("foo"), "foo")
    assert_equal(noop1.replace(""), "")

    var noop2 = new_replacer(
        pairs([(String(""), String("")), (String(""), String("A"))])
    )
    assert_equal(noop2.replace("foo"), "foo")
    assert_equal(noop2.replace(""), "")

    var blank_foo = new_replacer(
        pairs(
            [
                (String(""), String("X")),
                (String("foobar"), String("R")),
                (String("foobaz"), String("Z")),
            ]
        )
    )
    assert_equal(blank_foo.replace("foobarfoobaz"), "XRXZX")
    assert_equal(blank_foo.replace("foobar-foobaz"), "XRX-XZX")
    assert_equal(blank_foo.replace(""), "X")


def test_multibyte_keys() raises:
    """Keys and replacements that are not ASCII, which Go's table skips.

    The trie is over bytes, so a three byte key is three edges and a match
    lands on a rune boundary because a valid key can only start where a rune
    does.
    """
    var r = new_replacer(
        pairs(
            [
                (String("☺"), String("smile")),
                (String("日本"), String("Japan")),
                (String("a"), String("☹")),
            ]
        )
    )
    assert_equal(r.replace("a☺b"), "☹smileb")
    assert_equal(r.replace("日本語"), "Japan語")
    assert_equal(r.replace("日"), "日")


def test_write_string() raises:
    """Go's `TestWriteString`, against this package's own builder."""
    var r = new_replacer(
        pairs([(String("a"), String("1")), (String("b"), String("2"))])
    )
    var b = Builder()
    var n = r.write_string(b, "abcab")
    assert_equal(n, 5)
    assert_equal(b.string(), "12c12")

    # The count is the length of what came out and not of what went in, which
    # is the only thing a caller can do anything with.
    var b2 = Builder()
    var grow = new_replacer(pairs([(String("a"), String("aaa"))]))
    assert_equal(grow.write_string(b2, "aa"), 6)
    assert_equal(b2.string(), "aaaaaa")


def test_replacer_can_be_shared() raises:
    """Built once and used many times, which is what it is for.

    Nothing in a replacer changes after the constructor returns, so the same
    one can be copied and both copies go on working. Go's has to be careful
    here because it builds lazily behind a lock.
    """
    var r = new_replacer(pairs([(String("x"), String("y"))]))
    var r2 = r.copy()
    assert_equal(r.replace("xx"), "yy")
    assert_equal(r2.replace("xxx"), "yyy")
    assert_equal(r.replace("axa"), "aya")
