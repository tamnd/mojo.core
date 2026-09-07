"""JSON. Go's `encoding/json`, without the reflection.

Go has one entry point, `Unmarshal`, which reads a document into whatever value
it is handed by inspecting that value's type while the program runs. There is
no such inspection here, so the package is two paths instead.

This file is the first: a scanner, and everything that can be built on a
scanner without knowing what the document holds. `valid` says whether bytes are
JSON, `compact` and `indent` reshape them without changing what they mean,
`html_escape` makes them safe to put in a script tag, and `new_decoder` reads a
stream as a flat sequence of tokens, which is enough to walk a document of any
shape without a type to read it into. The second path is generated code, one
decoder per struct, and it arrives with issue 33.

`docs/design.md` section 8 has the reasoning, and `docs/packages.md` says which
symbols are outstanding.
"""

from .decode import Decoder, Tokens, new_decoder
from .indent import compact, html_escape, indent
from .number import Number
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
