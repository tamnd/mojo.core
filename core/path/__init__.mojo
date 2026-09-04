"""Slash separated paths. Go's `path`.

Nine symbols, all lexical. A path here is text with slashes in it: a URL path,
an entry in an archive, a key in an object store. Nothing in this package opens
anything or asks whether a name exists, and `clean("a/../b")` is `"b"` whether
or not `a` is there and whether or not it is a symbolic link.

Start with `clean` for the shortest name meaning the same thing, `join` to put
one together, `split`, `base`, `dir` and `ext` to take one apart, `is_abs` for
whether it starts at the root, and `is_match` for shell style patterns.

`core.path.filepath` is the same set of questions about the host's own paths,
where the separator can be a backslash and a name can start with a drive
letter. On the two platforms this library supports the separator is `/` and the
two packages agree on almost everything, and the abstraction is kept anyway,
because a program that says which of the two it means is a program that still
says it on a platform where they differ.
"""

from core.errors.codes import ErrBadPattern

from .pattern import is_match
from .path import base, clean, dir, ext, is_abs, join, split
