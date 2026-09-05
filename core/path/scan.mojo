"""Two byte scans, so that this package can sit under the file system.

Go's `path` imports `internal/bytealg` and `unicode/utf8` and nothing else. It
does not import `strings` or `bytes`, which is not an accident: `io/fs` imports
`path`, so `path` has to be reachable from underneath the file system, and a
package that pulled the whole of `strings` down with it could not be.

This library had the same two calls coming from `core.strings` and `core.bytes`
and paid the same price Go refuses to pay, which was that `core.io.fs` could not
name `core.path` at all. So the two loops are here. They are four lines each and
they are the only thing this package wanted from either of those two, and the
alternative was `core.bytes`, `core.strings` and everything they rest on sitting
underneath every file system in the library.

They are private. `core.bytes.index_byte` and `core.strings.last_index_byte` are
still the ones a caller reaches for and are still the only ones documented, and
nothing here is exported or re-exported.
"""

from core.io import Byte


def _index_byte[o: Origin](s: Span[Byte, o], c: Byte) -> Int:
    """The first offset of `c` in `s`, or -1. Go's `bytealg.IndexByte`."""
    for i in range(len(s)):
        if s[i] == c:
            return i
    return -1


def _last_index_byte[o: ImmOrigin](s: StringSlice[o], c: Byte) -> Int:
    """The last offset of `c` in `s`, or -1. Go's `bytealg.LastIndexByte`."""
    var raw = s.as_bytes()
    for i in reversed(range(len(raw))):
        if raw[i] == c:
            return i
    return -1
