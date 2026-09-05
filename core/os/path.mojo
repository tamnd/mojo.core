"""The few facts about this host's paths that Go keeps in `os`.

`core.path.filepath` is where path handling lives and it declares the same
separator under its own name. These are here because Go has them here, and Go
has them here because `os` is older than `path/filepath` and code that only
wanted the character should not have to import a whole package for it.

Both platforms this library targets separate with a slash and list with a
colon, which is why these are constants and not questions asked at run time.
"""

from core.io import Byte

comptime PATH_SEPARATOR = Int32(ord("/"))
"""What separates the elements of a path on this host. Go's `PathSeparator`."""

comptime PATH_LIST_SEPARATOR = Int32(ord(":"))
"""What separates the paths in a list such as `PATH`. Go's `PathListSeparator`.
"""

comptime DEV_NULL = "/dev/null"
"""The name of the null device. Go's `DevNull`.

Opening it for writing gives a file that accepts everything and keeps nothing,
which is what a program wants when a caller asked for output it does not want.
`core.io.Discard` is the version that does not involve the kernel.
"""


def is_path_separator(c: Byte) -> Bool:
    """Whether this byte separates path elements. Go's `IsPathSeparator`.

    One byte and one answer here. On Windows Go says yes to both the backslash
    and the slash, which is why the question is a function rather than a
    comparison against the constant, and keeping it a function is what lets
    that host arrive without every caller changing.
    """
    return Int32(Int(c)) == PATH_SEPARATOR
