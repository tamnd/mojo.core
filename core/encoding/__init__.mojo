"""How a type says it can encode itself. Go's `encoding`.

```mojo
from core.encoding import TextMarshaler


def render[T: TextMarshaler](value: T) raises -> String:
    return String(from_utf8_lossy=value.marshal_text())
```

Six traits, one method each, and nothing else. They are the smallest thing in
the library and they are why an instant, a big number, a network address or a
type somebody wrote this morning can go through a codec that has never heard of
it: the codec names the trait and the type names the method, and neither one
names the other.

`BinaryMarshaler` and `BinaryUnmarshaler` are a value as bytes and back.
`TextMarshaler` and `TextUnmarshaler` are the same pair for text that a person
could read. `BinaryAppender` and `TextAppender` write into a list the caller
already has, which is what a codec filling a buffer actually wants, and Go added
both of them in 1.24 for the same reason.

Go's four interfaces are discovered at run time with a type assertion. There is
nothing to assert against here, design.md section 1, so a codec takes the type
as a generic parameter bound by the trait instead and a type that cannot encode
itself is a compile error rather than a fallback path. `marshal.mojo` says what
that changes and what it does not.

## Who implements them

`time.Time` implements all six. `math.big.Int`, `math.big.Float` and
`math.big.Rat` implement the three text traits. `math.rand.PCG` and
`math.rand.ChaCha8` implement the three binary ones, which is how a generator's
state is saved and restored. Every one of those methods was written before this
package existed and none of them changed shape to join it.

## The subpackages

Everything under `core.encoding` is a codec: `json`, `xml`, `csv`, `gob`,
`asn1`, `pem`, `binary`, `hex`, `base32`, `base64` and `ascii85`. They depend on
this package and this package depends on nothing at all, which is the arrangement
Go has and the reason the traits are declared in a package of their own rather
than in whichever codec needed them first.
"""

from .marshal import (
    BinaryAppender,
    BinaryMarshaler,
    BinaryUnmarshaler,
    TextAppender,
    TextMarshaler,
    TextUnmarshaler,
)
