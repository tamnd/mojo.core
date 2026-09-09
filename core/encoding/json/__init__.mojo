"""JSON. Go's `encoding/json`, without the reflection.

Go has one entry point, `Unmarshal`, which reads a document into whatever value
it is handed by inspecting that value's type while the program runs. There is
no such inspection here, so the package is two paths instead.

This file is the first: a scanner, and everything that can be built on a
scanner without knowing what the document holds. `valid` says whether bytes are
JSON, `compact` and `indent` reshape them without changing what they mean,
`html_escape` makes them safe to put in a script tag, `new_decoder` reads a
stream as a flat sequence of tokens or one whole value at a time, `RawMessage`
holds a value that has not been read yet, and `parse` reads a whole document
into an arena that can be walked in any order. Any of those is enough to work
with a document of any shape without a type to read it into.

The second path is generated code, one encoder and one decoder per struct,
written by `tools/codec` out of the fields and the struct tags. The part of it
that is the same for every struct is here as well: `ValueScanner` and the six
`append_` writers are what a generated codec is made of, and are the whole of
what it needs from this package.

Between the two sits the interface Go asks a value for before it walks it.
`Marshaler` and `Unmarshaler` are the two traits a type implements to say it
knows its own JSON, `marshal`, `marshal_indent` and `unmarshal` are the calls
that take one, and `new_encoder` writes a stream of them with the newline Go
writes after each.

Two of Go's error types are here as well. `UnmarshalTypeError` is what a
decoder raises when the document is well formed and says one thing and the
field wants another, and `UnsupportedValueError` is the same disagreement going
the other way, a float that is infinite or is not a number and so has no
spelling in JSON. Go's other five are waived, and `tools/parity/waivers.toml`
carries the reason for each.

`docs/design.md` section 8 has the reasoning, and `docs/packages.md` says which
symbols are outstanding.
"""

from .codec import (
    ValueScanner,
    append_bool,
    append_float,
    append_raw,
    append_signed,
    append_string,
    append_unsigned,
    missing_key,
)
from .decode import Decoder, Tokens, new_decoder
from .document import ARRAY, Document, OBJECT, Value, new_document, parse
from .errors import UnmarshalTypeError, UnsupportedValueError
from .indent import compact, html_escape, indent
from .marshal import (
    Encoder,
    Marshaler,
    Unmarshaler,
    marshal,
    marshal_indent,
    new_encoder,
    unmarshal,
)
from .number import Number
from .raw import RawMessage
from .scan import MAX_NESTING_DEPTH, SyntaxError, valid, valid_or_raise
from .token import (
    ARRAY_CLOSE,
    ARRAY_OPEN,
    BOOL,
    DELIM,
    Delim,
    NULL,
    NUMBER,
    OBJECT_CLOSE,
    OBJECT_OPEN,
    STRING,
    Token,
)
