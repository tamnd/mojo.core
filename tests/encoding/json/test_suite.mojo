"""JSONTestSuite, all three hundred and eighteen parsing files.

Nicolas Seriot's corpus from "Parsing JSON is a Minefield", which is the
closest thing there is to a conformance suite for RFC 8259. The first letter of
a file name is the verdict: `y_` has to be accepted, `n_` has to be refused,
and `i_` is a case the standard leaves open, where either answer is allowed so
long as it was decided rather than stumbled into.

Every file is put to `valid`, which is a question about structure, and to
`parse`, which also has to decide what a string holds. The two answers differ on
exactly twenty files and `_refused_by_parse` is where that is written down.

The corpus is embedded by `tools/gen/jsonsuite.py`, because nothing in this
suite opens a file at run time.
"""

from std.testing import assert_equal, assert_true

from core.encoding.json import new_document, valid, valid_or_raise
from core.errors import matches
from core.errors.codes import ErrJSONText
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


def _refused_by_parse() -> List[String]:
    """The twenty `i_` files `valid` accepts and `parse` refuses.

    All twenty are a string holding something that is not text: eleven carry an
    escape naming half of a surrogate pair with no other half, and nine carry
    bytes that are not UTF-8, which covers a lone continuation byte, an overlong
    sequence, a surrogate written out in UTF-8, a code point past the end of
    Unicode, Latin-1 and a sequence that simply stops.

    They are one decision rather than twenty. `valid` reads the bytes between a
    pair of quotes only far enough to find the closing quote, so a document is
    structure and the text inside it is somebody else's business, and Go draws
    the line in the same place. A `Value` is where that stops being true,
    because it hands back a Mojo `String`, which says it is UTF-8. Go's answer
    is to put U+FFFD in and carry on, which loses the difference between a
    document that held a replacement character and one that did not, so `parse`
    raises `ErrJSONText` instead. `docs/deviations.md` has the row.

    The four files in `_refused_open_cases` are refused by both, for a reason
    that is about the document's own encoding rather than about a string, so
    they are not in this table and `parse` refuses twenty four in total.
    """
    return [
        String("i_object_key_lone_2nd_surrogate.json"),
        String("i_string_1st_surrogate_but_2nd_missing.json"),
        String("i_string_1st_valid_surrogate_2nd_invalid.json"),
        String("i_string_UTF-8_invalid_sequence.json"),
        String("i_string_UTF8_surrogate_U+D800.json"),
        String("i_string_incomplete_surrogate_and_escape_valid.json"),
        String("i_string_incomplete_surrogate_pair.json"),
        String("i_string_incomplete_surrogates_escape_valid.json"),
        String("i_string_invalid_lonely_surrogate.json"),
        String("i_string_invalid_surrogate.json"),
        String("i_string_invalid_utf-8.json"),
        String("i_string_inverted_surrogates_U+1D11E.json"),
        String("i_string_iso_latin_1.json"),
        String("i_string_lone_second_surrogate.json"),
        String("i_string_lone_utf8_continuation_byte.json"),
        String("i_string_not_in_unicode_range.json"),
        String("i_string_overlong_sequence_2_bytes.json"),
        String("i_string_overlong_sequence_6_bytes.json"),
        String("i_string_overlong_sequence_6_bytes_null.json"),
        String("i_string_truncated-utf-8.json"),
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


def test_every_yes_case_is_parsed() raises:
    """The ninety five documents that are JSON, read into an arena.

    Nothing in the yes column holds a string that is not text, so `parse` and
    `valid` agree on all ninety five, and this is the test that says so.
    """
    var cases = suite_cases()
    for i in range(len(cases)):
        var name = cases[i].name.copy()
        if not name.startswith("y_"):
            continue
        var doc = new_document()
        try:
            doc.parse_into(Span(cases[i].document))
        except e:
            raise Error("refused " + name + ": " + String(e))


def test_every_yes_case_survives_a_round_trip() raises:
    """Written back out and read again, every one of the ninety five gives the
    same bytes the second time.

    Not the same bytes as the file, which would be asking `write_to` to keep
    whitespace and the document's own choice of escape. What has to hold is
    that writing a document out and reading it back gives a document that
    writes out the same way, which is what says the arena and the writer agree
    about what is in there.
    """
    var cases = suite_cases()
    for i in range(len(cases)):
        var name = cases[i].name.copy()
        if not name.startswith("y_"):
            continue
        var first = new_document()
        first.parse_into(Span(cases[i].document))
        var once = String(first.root())
        var second = new_document()
        try:
            second.parse_into(once.as_bytes())
        except e:
            raise Error("refused its own output for " + name + ": " + String(e))
        assert_equal(String(second.root()), once, name)


def test_every_no_case_is_refused_by_parse() raises:
    """The hundred and eighty eight documents that are not JSON.

    `parse` runs `valid_or_raise` before it reads anything, so this is the same
    hundred and eighty eight refusals arriving through a second door. Worth
    asking anyway: the builder walks the bytes a second time and a document it
    accepted after the scanner refused it would be the scanner not being
    consulted.
    """
    var cases = suite_cases()
    for i in range(len(cases)):
        var name = cases[i].name.copy()
        if not name.startswith("n_"):
            continue
        var doc = new_document()
        var accepted = True
        try:
            doc.parse_into(Span(cases[i].document))
        except:
            accepted = False
        if accepted:
            raise Error("accepted " + name)


def test_the_open_cases_are_answered_on_purpose_by_parse() raises:
    """The thirty five documents RFC 8259 leaves to the implementation.

    Twenty four are refused, the four in `_refused_open_cases` for their
    encoding and the twenty in `_refused_by_parse` for what a string holds, and
    the remaining eleven are accepted. As with `valid`, the point of the table
    is that a new file in the corpus cannot quietly change an answer.
    """
    var encoding = _refused_open_cases()
    var text = _refused_by_parse()
    var cases = suite_cases()
    var seen = 0
    var refused = 0
    for i in range(len(cases)):
        var name = cases[i].name.copy()
        if not name.startswith("i_"):
            continue
        seen += 1
        var want = not _holds(encoding, name) and not _holds(text, name)
        var doc = new_document()
        var got = True
        var why = String()
        try:
            doc.parse_into(Span(cases[i].document))
        except e:
            got = False
            why = String(e)
            refused += 1
        if got != want:
            var verb = "accepted " if got else "refused "
            raise Error(verb + name + ", which the tables do not say: " + why)
    assert_equal(seen, 35)
    assert_equal(refused, 24)


def test_a_refused_string_says_it_was_the_text() raises:
    """All twenty carry `ErrJSONText`, so a caller can tell a document that is
    not JSON from one whose strings are not text and act differently."""
    var text = _refused_by_parse()
    var cases = suite_cases()
    var counted = 0
    for i in range(len(cases)):
        var name = cases[i].name.copy()
        if not _holds(text, name):
            continue
        counted += 1
        var doc = new_document()
        try:
            doc.parse_into(Span(cases[i].document))
            raise Error("accepted " + name)
        except e:
            assert_true(matches(e, ErrJSONText), name + ": " + String(e))
    assert_equal(counted, 20)


def test_the_parse_table_names_files_that_exist() raises:
    """A name misspelled in `_refused_by_parse` would turn a refusal into an
    expectation of acceptance and the tests above would still pass, since the
    misspelling matches nothing."""
    var text = _refused_by_parse()
    assert_equal(len(text), 20)
    var cases = suite_cases()
    var names = List[String]()
    for i in range(len(cases)):
        names.append(cases[i].name.copy())
    for i in range(len(text)):
        assert_true(
            _holds(names, text[i]), "no such file in the corpus: " + text[i]
        )


def test_the_two_tables_name_different_files() raises:
    """The four refused for their encoding and the twenty refused for their
    text are separate decisions, and a file in both would make the count of
    twenty four wrong."""
    var encoding = _refused_open_cases()
    var text = _refused_by_parse()
    for i in range(len(encoding)):
        assert_true(
            not _holds(text, encoding[i]),
            "in both tables: " + encoding[i],
        )


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
