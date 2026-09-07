"""The six token types, and the one struct that holds any of them.

Go finds out which token arrived with a type switch and this reads a `kind`,
so the interesting part is that the six accessors refuse a token of the wrong
kind rather than handing back a zero value. The rest is Go's `CopyToken`
tests, which here check something weaker than Go's do and say why.
"""

from core.encoding.xml import (
    Attr,
    CHAR_DATA,
    CharData,
    COMMENT,
    Comment,
    DIRECTIVE,
    Directive,
    END_ELEMENT,
    EndElement,
    Name,
    PROC_INST,
    ProcInst,
    START_ELEMENT,
    StartElement,
    Token,
    copy_token,
)
from core.io import Byte
from core.strings import contains


def test_a_name_prints_with_its_space_in_front() raises:
    """For a message, not for a document: the prefix an encoder picks depends
    on what else is in scope, so a name cannot write its own."""
    if String(Name("space", "local")) != "space:local":
        raise Error("wrote " + String(Name("space", "local")))
    if String(Name("", "local")) != "local":
        raise Error("a name with no space printed a colon")


def test_two_names_match_on_both_halves() raises:
    """A local name in two name spaces is two different names, which is the
    whole reason the space is carried around."""
    if Name("a", "x") != Name("b", "x"):
        pass
    else:
        raise Error("two spaces compared equal")
    if Name("a", "x") != Name("a", "x"):
        raise Error("the same name compared unequal")


def test_each_kind_answers_to_its_own_accessor() raises:
    """`kind` is the question to ask, and the accessor is the answer."""
    var s = Token(StartElement(Name("", "a"), [Attr(Name("", "x"), "1")]))
    if s.kind != START_ELEMENT:
        raise Error("a start element has the wrong kind")
    if s.start_element().attr[0].value != "1":
        raise Error("the attribute did not survive")

    var e = Token(EndElement(Name("", "a")))
    if e.kind != END_ELEMENT or e.end_element().name.local != "a":
        raise Error("an end element did not survive")

    var c = Token(CharData("text"))
    if c.kind != CHAR_DATA or c.char_data().text() != "text":
        raise Error("character data did not survive")

    var m = Token(Comment("note"))
    if m.kind != COMMENT or m.comment().text() != "note":
        raise Error("a comment did not survive")

    var d = Token(Directive("DOCTYPE x"))
    if d.kind != DIRECTIVE or d.directive().text() != "DOCTYPE x":
        raise Error("a directive did not survive")

    var p = Token(ProcInst("target", "inst"))
    if p.kind != PROC_INST or p.proc_inst().text() != "inst":
        raise Error("a processing instruction did not survive")
    if p.proc_inst().target != "target":
        raise Error("the target did not survive")


def test_asking_for_the_wrong_kind_raises() raises:
    """Go's type assertion has a two value form that says no quietly. There is
    nothing to hand back here, so the accessor raises and names both kinds."""
    var t = Token(CharData("text"))
    var raised = Optional[Error](None)
    try:
        _ = t.start_element()
    except err:
        raised = err
    if not raised:
        raise Error("character data was handed back as a start element")
    var msg = String(raised.value())
    if not contains(msg, "character data") or not contains(
        msg, "a start element"
    ):
        raise Error("the message does not name both kinds: " + repr(msg))


def test_a_token_reads_back_as_something_a_message_can_hold() raises:
    """Not a document, which is the encoder's work. Enough to tell two tokens
    apart in a failing test or a log line."""
    var s = Token(StartElement(Name("ns", "a"), [Attr(Name("", "x"), "1")]))
    var got = String(s)
    if not contains(got, "ns:a") or not contains(got, "x="):
        raise Error("a start element printed as " + repr(got))
    if not contains(String(Token(EndElement(Name("", "a")))), "</a>"):
        raise Error("an end element printed without its name")


def test_the_text_of_a_token_is_its_bytes() raises:
    """The same thing all six `text` methods do, for a caller holding a
    `Token` who does not want to name its kind first."""
    if Token(Comment("note")).text() != "note":
        raise Error("a comment has no text")
    if Token(StartElement(Name("", "a"), List[Attr]())).text() != "":
        raise Error("a start element invented some text")


def test_a_copy_is_independent_of_what_it_was_copied_from() raises:
    """Go's three `CopyToken` tests, which check that the copy does not share
    the decoder's buffer.

    Nothing here borrows anything, so this checks the weaker thing that is
    actually true: changing the copy leaves the original alone. `copy_token`
    is here because Go has it and a port will reach for it, not because a
    caller who never calls it is making a mistake.
    """
    var original = Token(CharData("same data"))
    var copy = copy_token(original)
    if copy != original:
        raise Error("a copy is not equal to what it was copied from")
    copy.data[1] = Byte(ord("o"))
    if copy == original:
        raise Error("the copy shares its bytes with the original")
    if original.text() != "same data":
        raise Error("the original changed")

    var elt = StartElement(Name("", "hello"), [Attr(Name("", "lang"), "en")])
    var t1 = Token(elt.copy())
    var t2 = copy_token(t1)
    if t2 != t1:
        raise Error("a copied start element is not equal")
    t2.attr[0] = Attr(Name("", "lang"), "de")
    if t2 == t1:
        raise Error("the copy shares its attributes with the original")
    if t1.attr[0].value != "en":
        raise Error("the original attribute changed")


def test_an_end_element_is_made_from_the_start_element() raises:
    """`end` is what a caller writing a document by hand reaches for, so that
    the two tags cannot drift apart."""
    var s = StartElement(Name("ns", "a"), List[Attr]())
    if s.end().name != s.name:
        raise Error("end did not carry the name across")


def test_text_that_is_not_utf_8_raises_rather_than_being_mangled() raises:
    """Character data is bytes on purpose, and turning it into a `String` is
    the point at which that has to be paid for."""
    var bad = List[Byte]()
    bad.append(0xFF)
    var t = Token(CharData(bad^))
    var raised = False
    try:
        _ = t.text()
    except err:
        raised = True
    if not raised:
        raise Error("bytes that are not UTF-8 became a String")
