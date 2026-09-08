"""DER, the encoding certificates are written in. Go's `encoding/asn1`.

ASN.1 is a notation for describing objects and DER is one of several ways of
writing those objects down. DER is the one X.509 uses, and the reason it is the
one is that every object has exactly one encoding, so two programs hashing the
same certificate get the same bytes. That property is only worth anything if
readers enforce it, which is why this refuses a non-minimal length, a
non-canonical integer, an indefinite length and a tag number written longer
than it needed to be, even where the value being expressed is obvious.

Go has `Unmarshal` and `Marshal`, which read and write a structure by walking
the Go type with reflection. There is none here, so the package is two paths,
the same split `core.encoding.json` makes. This file is the first: `Parser`
reads one value at a time and `Builder` writes one at a time, and `BitString`,
`ObjectIdentifier`, `RawValue` and the tag constants are what a value goes in
and comes back as. The second path is generated code, one reader and one writer
per struct, built out of the fields and the ASN.1 struct tags.

Nothing here recurses. A SEQUENCE hands back a second `Parser` over its
contents rather than calling into itself, and a `Builder` keeps its open values
on a list rather than on the stack, so there is no depth to cap and a document
of a million nested sequences costs a million calls that each return.

`docs/design.md` has the reasoning and `docs/packages.md` says which symbols
are outstanding.
"""

from .build import Builder
from .errors import StructuralError, SyntaxError
from .parse import Parser
from .tags import (
    ClassApplication,
    ClassContextSpecific,
    ClassPrivate,
    ClassUniversal,
    TagAndLength,
    TagBMPString,
    TagBitString,
    TagBoolean,
    TagEnum,
    TagGeneralString,
    TagGeneralizedTime,
    TagIA5String,
    TagInteger,
    TagNull,
    TagNumericString,
    TagOID,
    TagOctetString,
    TagPrintableString,
    TagSequence,
    TagSet,
    TagT61String,
    TagUTCTime,
    TagUTF8String,
)
from .value import (
    BitString,
    Enumerated,
    Flag,
    NullBytes,
    NullRawValue,
    ObjectIdentifier,
    RawContent,
    RawValue,
)
