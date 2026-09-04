"""A package that exists to be read by `tools/docjson`.

Every awkward case the reader has to handle is in here once: a tag in a
summary, a tag in a later paragraph, backticked prose that is not a tag, a
field whose type is another struct in the same package, a field whose type is
a struct in another package, a generic struct whose field is its own parameter,
a type parameterised twice over, an aliased import that collides with a prelude
name, and a private field that `mojo doc` will not report at all.

It is not built by `pixi run pkg` and not part of the library. The selftest
runs `mojo doc` over it and asserts what comes back, which is the only way to
find out that the reader still agrees with the compiler.
"""

from .records import Record
from .shapes import Boxed, Line, Named, Point
