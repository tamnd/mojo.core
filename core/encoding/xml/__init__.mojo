"""XML, one token at a time. Go's `encoding/xml`.

A document is read as a stream of tokens and written as a stream of tokens.
`new_decoder` wraps a reader and `token` hands back the next start element, end
element, run of text, comment, processing instruction or directive, with the
elements matched against each other and the name space prefixes resolved to the
URLs they were declared as. `new_encoder` goes the other way.

```mojo
from core.bytes import new_buffer_string
from core.encoding.xml import START_ELEMENT, new_decoder

def main() raises:
    var d = new_decoder(new_buffer_string("<a><b>text</b></a>"))
    var tokens = d.tokens()
    var names = List[String]()
    while tokens.has_next():
        var t = tokens.next()
        if t.kind == START_ELEMENT:
            names.append(t.name.local)
    print(len(names))  # 2
```

## What is here and what is not

Go's package has two halves. The token half is the one above. The other half
turns a whole value into a document and back, and in Go it is a walk over the
value with reflection, reading struct tags as it goes. There is no walk here.
`Marshaler` and `Unmarshaler` are the traits Go's walk asks a value about
before it starts guessing, and here they are the whole path: a type says how it
writes itself and how it reads itself back, and `marshal` and `unmarshal` call
what it said. `MarshalerAttr` and `UnmarshalerAttr` are the same pair for one
attribute rather than a whole element.

The one thing lost with the walk is the name Go gives an element by default,
which it reads off the Go type. There is no type name to read here, so
`marshal` hands the value a start element with an empty name and the value
names itself. `docs/deviations.md` has the row.

## Reading a document you did not write

The decoder does not parse a document type definition. A `<!DOCTYPE ...>`
arrives as a `Directive` holding its own text, and nothing in it is acted on.
That is Go's decision and it is the reason the two well known attacks on an XML
parser are not possible here rather than merely defended against: a document
cannot declare an entity, so there is nothing for a billion laughs expansion to
expand, and it cannot name an external file, so nothing is fetched. On top of
that a decoder here caps element nesting at `max_depth`, which Go caps only
inside its reflection half.

Every entity a decoder does expand comes from `Decoder.entity`, which the
caller filled in, and the text it expands to is never scanned again. An entry
cannot refer to another entry, so a table of any size expands to at most its
own size and there is no expansion budget to configure.

## HTML

Three lines read the HTML that is out there rather than the XML that is not:

```mojo
from core.bytes import new_buffer_string
from core.encoding.xml import html_auto_close, html_entity, new_decoder

def main() raises:
    var d = new_decoder(new_buffer_string("<p>caf&eacute;<br><p>x"))
    d.strict = False
    d.auto_close = html_auto_close()
    d.entity = html_entity()
    _ = d.token()
```

Those are the same three Go's own documentation gives, and they forgive the
same things: a missing end tag, an entity that is not one, an attribute with no
value and a value with no quotes.
"""

from .decode import (
    Decoder,
    Tokens,
    Unmarshaler,
    UnmarshalerAttr,
    new_decoder,
)
from .encode import HEADER, Encoder, Marshaler, MarshalerAttr, new_encoder
from .errors import UnmarshalError, unmarshal_error
from .escape import escape, escape_text, is_in_character_range
from .marshal import marshal, marshal_indent, unmarshal
from .syntax import SyntaxError
from .tables import html_auto_close, html_entity, is_name_first, is_name_rune
from .token import (
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
    TokenReader,
    copy_token,
)
