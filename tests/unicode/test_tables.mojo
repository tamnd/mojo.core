"""The two hundred and forty seven tables, and the six maps that name them.

Go's `script_test.go`, plus the parts of `letter_test.go` that are about the
tables rather than about case. The generated data itself is checked against Go
for every code point by the `unicode-tables` and `unicode-runes` differ areas,
so what is left for this file is the shape of the thing: that the tables are
sorted and strided the way the search assumes, that `latin_offset` counts what
the predicates skip, that the maps hold every table under the name Go uses, and
that the named constants and the map entries are one table and not two copies.

Go's category and property tests carry an assertion that is easy to miss and is
the most valuable line in the file: after every row of the fixture has been
checked, every remaining key of the map is a failure. It means the fixture has
to grow when Unicode adds a category, and a new table cannot arrive untested.
That assertion is `test_every_category_is_tested` and its property twin here.
"""

from std.testing import assert_equal, assert_false, assert_true

from core.unicode import (
    MAX_LATIN1,
    MAX_RUNE,
    VERSION,
    Categories,
    CategoryAliases,
    FoldCategory,
    FoldScript,
    Greek,
    L,
    Latin,
    Letter,
    Ll,
    Lower,
    Lt,
    Lu,
    M,
    Mark,
    N,
    Nd,
    Number,
    P,
    Properties,
    Punct,
    RangeTable,
    S,
    Scripts,
    Space,
    Symbol,
    Title,
    Upper,
    White_Space,
    Z,
    is_in,
)

from tests.unicode._fixtures import category_cases, property_cases


def _same(a: RangeTable, b: RangeTable) raises -> Bool:
    """Whether two tables hold the same ranges.

    By contents rather than by identity, because a `RangeTable` here is four
    integers naming a slice of one array and two of them being equal is what
    identity means.
    """
    if a.r16_len() != b.r16_len() or a.r32_len() != b.r32_len():
        return False
    if a.latin_offset != b.latin_offset:
        return False
    for index in range(a.r16_len()):
        var left = a.r16(index)
        var right = b.r16(index)
        if left.lo != right.lo or left.hi != right.hi:
            return False
        if left.stride != right.stride:
            return False
    for index in range(a.r32_len()):
        var left32 = a.r32(index)
        var right32 = b.r32(index)
        if left32.lo != right32.lo or left32.hi != right32.hi:
            return False
        if left32.stride != right32.stride:
            return False
    return True


def _all_tables() raises -> List[Tuple[String, RangeTable]]:
    """Every table any of the five maps names, tagged with the map it came from.

    A name can appear in more than one map, `Greek` in `Scripts` and in
    `FoldScript`, so the tag is part of the label rather than the whole of it.
    """
    var out = List[Tuple[String, RangeTable]]()
    var categories = Categories()
    for name in categories.keys():
        out.append((String("Categories[") + name + "]", categories[name]))
    var scripts = Scripts()
    for name in scripts.keys():
        out.append((String("Scripts[") + name + "]", scripts[name]))
    var properties = Properties()
    for name in properties.keys():
        out.append((String("Properties[") + name + "]", properties[name]))
    var fold_category = FoldCategory()
    for name in fold_category.keys():
        out.append((String("FoldCategory[") + name + "]", fold_category[name]))
    var fold_script = FoldScript()
    for name in fold_script.keys():
        out.append((String("FoldScript[") + name + "]", fold_script[name]))
    return out^


def test_the_maps_are_the_sizes_go_has() raises:
    """The counts, so that a table lost in generation is a failure and not a gap.

    These are Unicode 15.0.0's numbers as Go has them. They change when the
    edition does, and when they change the vendored files under `tests/data`
    have changed too, which is the point: this asserts that nothing else can
    move them.
    """
    assert_equal(VERSION, "15.0.0")
    assert_equal(len(Categories()), 38)
    assert_equal(len(Scripts()), 163)
    assert_equal(len(Properties()), 35)
    assert_equal(len(FoldCategory()), 6)
    assert_equal(len(FoldScript()), 3)
    assert_equal(len(CategoryAliases()), 42)


def test_every_category_is_tested() raises:
    """Go's `TestCategories`, including the assertion about the fixture itself.

    Each row says a code point is in a category, and then every category the
    rows did not mention is an error. Go writes the second half as a map it
    deletes from; it is a lookup here for the same reason and with the same
    effect.
    """
    var categories = Categories()
    var tested = Dict[String, Bool]()
    for row in category_cases():
        assert_true(
            row.name in categories,
            String(row.name) + " is not a known category",
        )
        assert_true(
            is_in(categories[row.name], row.rune),
            String("not in ") + row.name,
        )
        tested[row.name] = True
    for name in categories.keys():
        assert_true(name in tested, String("category not tested: ") + name)


def test_every_property_is_tested() raises:
    """Go's `TestProperties`, with the same assertion about the fixture."""
    var properties = Properties()
    var tested = Dict[String, Bool]()
    for row in property_cases():
        assert_true(
            row.name in properties,
            String(row.name) + " is not a known property",
        )
        assert_true(
            is_in(properties[row.name], row.rune),
            String("not in ") + row.name,
        )
        tested[row.name] = True
    for name in properties.keys():
        assert_true(name in tested, String("property not tested: ") + name)


def test_latin_offset_counts_what_the_predicates_skip() raises:
    """Go's `TestLatinOffset`, over all five maps.

    `latin_offset` is how many sixteen bit ranges end at or below U+00FF, and
    the predicates that have already answered from the byte table start their
    search after that many. A number too large skips a range that holds real
    code points and the table quietly loses them, which no other test here
    would see, because the fast path never asks.
    """
    for entry in _all_tables():
        var label, table = entry
        var count = 0
        while (
            count < table.r16_len() and Int32(table.r16(count).hi) <= MAX_LATIN1
        ):
            count += 1
        assert_equal(table.latin_offset, count, label)


def test_the_ranges_are_sorted_and_strided() raises:
    """The invariants `_is16` and `_is32` assume and cannot check.

    Both searches are binary above a short table, so unsorted ranges give a
    wrong answer rather than a slow one. The stride is a divisor and a zero
    there is a division by zero on the first code point that reaches it.
    """
    for entry in _all_tables():
        var label, table = entry
        var previous16 = -1
        for index in range(table.r16_len()):
            var r = table.r16(index)
            assert_true(r.lo <= r.hi, label)
            assert_true(r.stride >= 1, label)
            assert_equal(Int(r.hi - r.lo) % Int(r.stride), 0, label)
            assert_true(Int(r.lo) > previous16, label)
            previous16 = Int(r.hi)
        var previous32 = -1
        for index in range(table.r32_len()):
            var r32 = table.r32(index)
            assert_true(r32.lo <= r32.hi, label)
            assert_true(r32.stride >= 1, label)
            assert_equal(Int(r32.hi - r32.lo) % Int(r32.stride), 0, label)
            assert_true(Int(r32.lo) > previous32, label)
            previous32 = Int(r32.hi)
            # The split is by width and not by convenience: anything that fits
            # in sixteen bits belongs in the other list, and a search that has
            # ruled out the sixteen bit ranges relies on it.
            assert_true(r32.lo > UInt32(0xFFFF), label)
            assert_true(r32.hi <= UInt32(MAX_RUNE), label)


def test_no_table_is_empty() raises:
    """A named table with no ranges would be a name for the empty set.

    Every one of these is a category, a script or a property that Unicode
    assigns to at least one code point, so an empty one means the generator
    read a section it did not understand and wrote the name anyway.
    """
    for entry in _all_tables():
        var label, table = entry
        assert_true(table.r16_len() + table.r32_len() > 0, label)


def test_the_named_tables_are_the_map_entries() raises:
    """`unicode.Lu` and `Categories()["Lu"]` are one table, not two copies.

    The named constant is the one to reach for and the map is for names only
    known at run time, and the whole arrangement is worth nothing if the two
    can disagree.
    """
    var categories = Categories()
    assert_true(_same(categories["Lu"], Lu))
    assert_true(_same(categories["Ll"], Ll))
    assert_true(_same(categories["Lt"], Lt))
    assert_true(_same(categories["L"], L))
    assert_true(_same(categories["M"], M))
    assert_true(_same(categories["N"], N))
    assert_true(_same(Scripts()["Greek"], Greek))
    assert_true(_same(Scripts()["Latin"], Latin))
    assert_true(_same(Properties()["White_Space"], White_Space))


def test_the_readable_names_are_the_short_ones() raises:
    """Go's aliases as variables: `Letter` is `L` and `Upper` is `Lu`.

    Two names for one table, which is Go's `tables.go` and is why this is an
    equality of contents and not of spelling.
    """
    assert_true(_same(Letter, L))
    assert_true(_same(Mark, M))
    assert_true(_same(Number, N))
    assert_true(_same(Punct, P))
    assert_true(_same(Symbol, S))
    assert_true(_same(Space, Z))
    assert_true(_same(Upper, Lu))
    assert_true(_same(Title, Lt))
    assert_true(_same(Lower, Ll))


def test_every_alias_resolves_to_a_category() raises:
    """`CategoryAliases` maps Unicode's long names onto the short ones.

    The value has to be a key of `Categories`, or a program that accepts both
    spellings from a user resolves one of them to nothing.
    """
    var categories = Categories()
    var aliases = CategoryAliases()
    for name in aliases.keys():
        var short = aliases[name]
        assert_true(
            short in categories,
            String(name)
            + " resolves to "
            + short
            + ", which is not a category",
        )
    # The spellings, so that a generator emitting the pairs the other way round
    # is a failure rather than a surprise at a call site.
    assert_equal(aliases["Letter"], "L")
    assert_equal(aliases["Uppercase_Letter"], "Lu")
    assert_equal(aliases["Cased_Letter"], "LC")
    assert_equal(aliases["Decimal_Number"], "Nd")
    assert_equal(aliases["Other"], "C")


def test_fold_category_has_no_cased_letter() raises:
    """Go's quirk, reproduced on purpose: `FoldCategory` has no `LC` key.

    `LC` is a category and it has fold exceptions, and Go's generator does not
    emit it because it only walks the categories that appear in the file it
    reads. Following Go here rather than fixing it is the whole point of this
    package, so the absence is asserted rather than left to be noticed as a
    bug and quietly corrected.
    """
    var fold = FoldCategory()
    assert_false("LC" in fold)
    assert_true("L" in fold)
    assert_true("Ll" in fold)
    assert_true("Lt" in fold)
    assert_true("Lu" in fold)
    assert_true("M" in fold)
    assert_true("Mn" in fold)


def test_the_maps_are_fresh_every_call() raises:
    """Each of the six is a function that builds a `Dict`, which callers pay for.

    A caller that writes `Categories()["Lu"]` in a loop builds a thirty eight
    entry dictionary on every iteration. That is a deviation from Go, where
    these are package level variables, and this test is here to make it a
    stated property: the returned map is the caller's own, and mutating it
    changes nothing for anybody else.
    """
    var first = Categories()
    first["Lu"] = Ll
    var second = Categories()
    assert_true(_same(second["Lu"], Lu))
    assert_false(_same(first["Lu"], Lu))
