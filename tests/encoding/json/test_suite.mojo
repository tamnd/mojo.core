"""JSONTestSuite, all three hundred and eighteen parsing files.

Nicolas Seriot's corpus from "Parsing JSON is a Minefield", which is the
closest thing there is to a conformance suite for RFC 8259. The first letter of
a file name is the verdict: `y_` has to be accepted, `n_` has to be refused,
and `i_` is a case the standard leaves open, where either answer is allowed so
long as it was decided rather than stumbled into.

The corpus is embedded by `tools/gen/jsonsuite.py`, because nothing in this
suite opens a file at run time.
"""

from std.testing import assert_equal, assert_true

from core.encoding.json import valid, valid_or_raise
from tests.generated.jsonsuite import suite_cases


def _refused_open_cases() -> List[String]:
    """The four `i_` files this refuses. Every other one is accepted.

    All four are a document that is not UTF-8, and they are one decision rather
    than four. The scanner reads UTF-8, a byte order mark is not whitespace and
    is not the start of a value, and a document in UTF-16 is a document in
    another encoding, so all four stop at the first byte. Go answers the same
    way and for the same reason, and RFC 8259 section 8.1 is what allows it:
    a document exchanged between systems shall be encoded in UTF-8 and shall
    not be preceded by a byte order mark.

    Nothing here is about what a string holds. The eleven files carrying
    unpaired surrogates and the nine carrying bytes that are not UTF-8 inside a
    string are all accepted, because the scanner counts brackets and quotes and
    never looks at the text between them, which is Go's split too.
    """
    return [
        String("i_string_UTF-16LE_with_BOM.json"),
        String("i_string_utf16BE_no_BOM.json"),
        String("i_string_utf16LE_no_BOM.json"),
        String("i_structure_UTF-8_BOM_empty_object.json"),
    ]


def _holds(names: List[String], name: String) -> Bool:
    """Whether `names` has `name` in it."""
    for i in range(len(names)):
        if names[i] == name:
            return True
    return False


def test_the_corpus_is_all_there() raises:
    """A corpus that quietly lost half its files would pass every test below,
    so the shape of it is checked before anything is asked of it."""
    var cases = suite_cases()
    assert_equal(len(cases), 318)
    var yes = 0
    var no = 0
    var open = 0
    for i in range(len(cases)):
        var name = cases[i].name.copy()
        if name.startswith("y_"):
            yes += 1
        elif name.startswith("n_"):
            no += 1
        elif name.startswith("i_"):
            open += 1
        else:
            raise Error("file name says nothing about the verdict: " + name)
    assert_equal(yes, 95)
    assert_equal(no, 188)
    assert_equal(open, 35)


def test_every_yes_case_is_accepted() raises:
    """The ninety five documents that are JSON."""
    var cases = suite_cases()
    for i in range(len(cases)):
        var name = cases[i].name.copy()
        if not name.startswith("y_"):
            continue
        if not valid(Span(cases[i].document)):
            var why = String()
            try:
                valid_or_raise(Span(cases[i].document))
            except e:
                why = String(e)
            raise Error("refused " + name + ": " + why)


def test_every_no_case_is_refused() raises:
    """The hundred and eighty eight documents that are not.

    This is the half of the corpus that finds bugs. A parser that accepts too
    much passes every test above and fails somewhere in here, on a trailing
    comma, a comment, a single quoted string, a number written the way some
    other language writes one, or an input that simply stops.
    """
    var cases = suite_cases()
    for i in range(len(cases)):
        var name = cases[i].name.copy()
        if not name.startswith("n_"):
            continue
        if valid(Span(cases[i].document)):
            raise Error("accepted " + name)


def test_every_no_case_says_why_it_was_refused() raises:
    """A refusal with no message and no offset would be a refusal nobody can
    act on, so every one of the hundred and eighty eight is asked."""
    var cases = suite_cases()
    for i in range(len(cases)):
        var name = cases[i].name.copy()
        if not name.startswith("n_"):
            continue
        var why = String()
        try:
            valid_or_raise(Span(cases[i].document))
        except e:
            why = String(e)
        if why.byte_length() == 0:
            raise Error("refused " + name + " with nothing to say about it")


def test_the_open_cases_are_answered_on_purpose() raises:
    """The thirty five documents RFC 8259 leaves to the implementation.

    Four are refused and thirty one are accepted, and `_refused_open_cases`
    says which and why. The point of the table is that adding a file to the
    corpus cannot quietly change an answer: a new `i_` case is accepted only
    because this test says every name outside the table is accepted, and a
    reviewer sees the count move.
    """
    var refused = _refused_open_cases()
    var cases = suite_cases()
    var seen = 0
    for i in range(len(cases)):
        var name = cases[i].name.copy()
        if not name.startswith("i_"):
            continue
        seen += 1
        var want = not _holds(refused, name)
        var got = valid(Span(cases[i].document))
        if got != want:
            var verb = "accepted " if got else "refused "
            raise Error(verb + name + ", which the table does not say")
    assert_equal(seen, 35)


def test_the_table_names_files_that_exist() raises:
    """A name misspelled in `_refused_open_cases` would turn a refusal into an
    expectation of acceptance and the test above would still pass, since the
    misspelling matches nothing."""
    var refused = _refused_open_cases()
    assert_equal(len(refused), 4)
    var cases = suite_cases()
    var names = List[String]()
    for i in range(len(cases)):
        names.append(cases[i].name.copy())
    for i in range(len(refused)):
        assert_true(
            _holds(names, refused[i]),
            "no such file in the corpus: " + refused[i],
        )


def test_the_numbers_no_machine_type_holds_are_still_json() raises:
    """Ten of the open cases are numbers too large, too small or too precise
    for a `Float64`, and every one of them is accepted.

    Whether a number fits is not a question about whether a document is JSON,
    which is exactly what `Number` exists for: the text is kept and the caller
    finds out at the point they ask for a machine type. Go accepts all ten as
    well, and fails on the same ten only when something asks for a float.
    """
    var cases = suite_cases()
    var counted = 0
    for i in range(len(cases)):
        var name = cases[i].name.copy()
        if not name.startswith("i_number_"):
            continue
        counted += 1
        assert_true(valid(Span(cases[i].document)), "refused " + name)
    assert_equal(counted, 10)


def test_a_string_is_not_checked_for_being_text() raises:
    """The twenty open cases that carry an unpaired surrogate, an overlong
    sequence, a lone continuation byte or Latin-1, all accepted.

    The scanner counts brackets and quotes and reads the bytes between them
    only far enough to find the closing quote, so what a string holds is the
    business of whatever decodes it. Go draws the line in the same place, and
    it is why `valid` is a question about structure and not about text.
    """
    var refused = _refused_open_cases()
    var cases = suite_cases()
    var counted = 0
    for i in range(len(cases)):
        var name = cases[i].name.copy()
        if not name.startswith("i_string_") and not name.startswith(
            "i_object_"
        ):
            continue
        if _holds(refused, name):
            continue
        counted += 1
        assert_true(valid(Span(cases[i].document)), "refused " + name)
    assert_equal(counted, 20)


def test_five_hundred_nested_arrays_are_fine() raises:
    """The one open case about depth. Five hundred is well inside the ten
    thousand the scanner allows, so the answer is yes, and the corpus has
    nothing between five hundred and the hundred thousand in the no column."""
    var cases = suite_cases()
    for i in range(len(cases)):
        if cases[i].name == "i_structure_500_nested_arrays.json":
            assert_true(valid(Span(cases[i].document)))
            return
    raise Error("i_structure_500_nested_arrays.json is not in the corpus")
