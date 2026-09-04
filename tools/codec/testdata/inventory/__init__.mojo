"""A package that stands in for somebody else's code.

Nothing here is part of the library. It is a small application package of the
kind the generator is meant for, with the awkward cases a real one would have:
a struct nested inside another, a list of them, a dictionary, fields that may
be absent, a renamed key, a field with no tag at all, a struct that encodes and
does not decode, and one whose fields are all optional so that the commas
between them have to be worked out as it goes.

`pixi run codec-selftest` copies this somewhere outside the repository,
generates a codec for it there, builds it and runs `driver.mojo` over it. The
copy of the generated file checked in beside these sources is compared with
what that run produces, so the diff of a change to the emitter is reviewable
rather than invisible.
"""

from .items import Item, Sparse
from .summaries import Summary
from .vendors import Vendor
