"""Go's `testInput` and the two token lists it reads as.

`raw_tokens` and `cooked_tokens` are the same document parsed the two ways, and
the difference between them is exactly what `token` does over `raw_token`. They
are written out here in Go's order with Go's contents rather than harvested,
because `tools/testgen` writes rows of scalars and these are rows of tokens.

The other three tables are Go's as well: `xml_input`, every document its parser
has to refuse, and `non_strict_input` with `non_strict_tokens`, the things a
document may get away with once `strict` is off.
"""

from core.encoding.xml import (
    Attr,
    CharData,
    Comment,
    Directive,
    EndElement,
    Name,
    ProcInst,
    StartElement,
    Token,
)

comptime TEST_INPUT = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN"
  "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">
<body xmlns:foo="ns1" xmlns="ns2" xmlns:tag="ns3" \r
\t  >
  <hello lang="en">World &lt;&gt;&apos;&quot; &#x767d;&#40300;翔</hello>
  <query>&何; &is-it;</query>
  <goodbye />
  <outer foo:attr="value" xmlns:tag="ns4">
    <inner/>
  </outer>
  <tag:name>
    <![CDATA[Some text here.]]>
  </tag:name>
</body><!-- missing final newline -->"""
"""Go's `testInput`.

Go splices a carriage return, a newline and a tab into the middle of the `body`
tag with string concatenation, because a raw literal cannot hold them legibly.
The escapes on the fifth line are the same three characters and they are there
for the same reason: whitespace inside a tag is whitespace whatever it is made
of, and a parser that only understood spaces would pass every other test.
"""

comptime NON_STRICT_INPUT = """
<tag>non&entity</tag>
<tag>&unknown;entity</tag>
<tag>&#123</tag>
<tag>&#zzz;</tag>
<tag>&なまえ3;</tag>
<tag>&lt-gt;</tag>
<tag>&;</tag>
<tag>&0a;</tag>
"""
"""Go's `nonStrictInput`. Eight ways of writing something that is not an
entity, each of which a strict parser refuses and a forgiving one leaves
alone."""

comptime DOCTYPE = """DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN"
  "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd\""""
"""What the doctype in `TEST_INPUT` arrives as: two lines, quotes and all, and
nothing in it acted on."""


def test_entity() -> Dict[String, String]:
    """Go's `testEntity`, the two names `TEST_INPUT` uses and nothing else."""
    var out = Dict[String, String]()
    out["何"] = String("What")
    out["is-it"] = String("is it?")
    return out^


def attrs(var items: List[Attr]) -> List[Attr]:
    """The attributes of a start element, written inline."""
    return items^


def start(
    space: StringSlice, local: StringSlice, var attr: List[Attr]
) -> Token:
    """A start element token, the way Go's table writes one."""
    return Token(StartElement(Name(space, local), attr^))


def end(space: StringSlice, local: StringSlice) -> Token:
    """An end element token."""
    return Token(EndElement(Name(space, local)))


def chars(text: StringSlice) -> Token:
    """A character data token."""
    return Token(CharData(text))


def attr(space: StringSlice, local: StringSlice, value: StringSlice) -> Attr:
    """One attribute."""
    return Attr(Name(space, local), value)


def raw_tokens() -> List[Token]:
    """Go's `rawTokens`, what `TEST_INPUT` is before anything is resolved."""
    var out = List[Token]()
    out.append(chars("\n"))
    out.append(Token(ProcInst("xml", 'version="1.0" encoding="UTF-8"')))
    out.append(chars("\n"))
    out.append(Token(Directive(DOCTYPE)))
    out.append(chars("\n"))
    out.append(
        start(
            "",
            "body",
            [
                attr("xmlns", "foo", "ns1"),
                attr("", "xmlns", "ns2"),
                attr("xmlns", "tag", "ns3"),
            ],
        )
    )
    out.append(chars("\n  "))
    out.append(start("", "hello", [attr("", "lang", "en")]))
    out.append(chars("World <>'\" 白鵬翔"))
    out.append(end("", "hello"))
    out.append(chars("\n  "))
    out.append(start("", "query", List[Attr]()))
    out.append(chars("What is it?"))
    out.append(end("", "query"))
    out.append(chars("\n  "))
    out.append(start("", "goodbye", List[Attr]()))
    out.append(end("", "goodbye"))
    out.append(chars("\n  "))
    out.append(
        start(
            "",
            "outer",
            [attr("foo", "attr", "value"), attr("xmlns", "tag", "ns4")],
        )
    )
    out.append(chars("\n    "))
    out.append(start("", "inner", List[Attr]()))
    out.append(end("", "inner"))
    out.append(chars("\n  "))
    out.append(end("", "outer"))
    out.append(chars("\n  "))
    out.append(start("tag", "name", List[Attr]()))
    out.append(chars("\n    "))
    out.append(chars("Some text here."))
    out.append(chars("\n  "))
    out.append(end("tag", "name"))
    out.append(chars("\n"))
    out.append(end("", "body"))
    out.append(Token(Comment(" missing final newline ")))
    return out^


def cooked_tokens() -> List[Token]:
    """Go's `cookedTokens`, the same document with the prefixes resolved.

    Every element name has become a URL and `foo:attr` has become `ns1:attr`,
    while the `xmlns` attributes keep their prefix as their space, which is
    what makes them recognisable as declarations rather than as data.
    """
    var out = List[Token]()
    out.append(chars("\n"))
    out.append(Token(ProcInst("xml", 'version="1.0" encoding="UTF-8"')))
    out.append(chars("\n"))
    out.append(Token(Directive(DOCTYPE)))
    out.append(chars("\n"))
    out.append(
        start(
            "ns2",
            "body",
            [
                attr("xmlns", "foo", "ns1"),
                attr("", "xmlns", "ns2"),
                attr("xmlns", "tag", "ns3"),
            ],
        )
    )
    out.append(chars("\n  "))
    out.append(start("ns2", "hello", [attr("", "lang", "en")]))
    out.append(chars("World <>'\" 白鵬翔"))
    out.append(end("ns2", "hello"))
    out.append(chars("\n  "))
    out.append(start("ns2", "query", List[Attr]()))
    out.append(chars("What is it?"))
    out.append(end("ns2", "query"))
    out.append(chars("\n  "))
    out.append(start("ns2", "goodbye", List[Attr]()))
    out.append(end("ns2", "goodbye"))
    out.append(chars("\n  "))
    out.append(
        start(
            "ns2",
            "outer",
            [attr("ns1", "attr", "value"), attr("xmlns", "tag", "ns4")],
        )
    )
    out.append(chars("\n    "))
    out.append(start("ns2", "inner", List[Attr]()))
    out.append(end("ns2", "inner"))
    out.append(chars("\n  "))
    out.append(end("ns2", "outer"))
    out.append(chars("\n  "))
    out.append(start("ns3", "name", List[Attr]()))
    out.append(chars("\n    "))
    out.append(chars("Some text here."))
    out.append(chars("\n  "))
    out.append(end("ns3", "name"))
    out.append(chars("\n"))
    out.append(end("ns2", "body"))
    out.append(Token(Comment(" missing final newline ")))
    return out^


def non_strict_tokens() -> List[Token]:
    """Go's `nonStrictTokens`, each bad entity left exactly as it was written.
    """
    var out = List[Token]()
    var texts = [
        String("non&entity"),
        String("&unknown;entity"),
        String("&#123"),
        String("&#zzz;"),
        String("&なまえ3;"),
        String("&lt-gt;"),
        String("&;"),
        String("&0a;"),
    ]
    for i in range(len(texts)):
        out.append(chars("\n"))
        out.append(start("", "tag", List[Attr]()))
        out.append(chars(texts[i]))
        out.append(end("", "tag"))
    out.append(chars("\n"))
    return out^


def xml_input() -> List[String]:
    """Go's `xmlInput`, every document its parser refuses.

    The first group runs out of input part way through something, the second is
    malformed in a way that has nothing to do with where the document stops.
    Go leaves two rows commented out because they are the caller's problem
    rather than the tokenizer's, and they are left out here too.
    """
    return [
        # Unexpected end of input.
        String("<"),
        String("<t"),
        String("<t "),
        String("<t/"),
        String("<!"),
        String("<!-"),
        String("<!--"),
        String("<!--c-"),
        String("<!--c--"),
        String("<!d"),
        String("<t></"),
        String("<t></t"),
        String("<?"),
        String("<?p"),
        String("<t a"),
        String("<t a="),
        String("<t a='"),
        String("<t a=''"),
        String("<t/><!["),
        String("<t/><![C"),
        String("<t/><![CDATA[d"),
        String("<t/><![CDATA[d]"),
        String("<t/><![CDATA[d]]"),
        # Malformed whatever follows.
        String("<>"),
        String("<t/a"),
        String("<0 />"),
        String("<?0 >"),
        String("</0>"),
        String("<t 0=''>"),
        String("<t a='&'>"),
        String("<t a='<'>"),
        String("<t>&nbspc;</t>"),
        String("<t a>"),
        String("<t a=>"),
        String("<t a=v>"),
        String("<t></e>"),
        String("<t></>"),
        String("<t></t!"),
        String("<t>cdata]]></t>"),
    ]
