"""The rule about names in an `fs.FS`, which is lexical and stands alone.

Its own file rather than the package `__init__`, because `valid_path` needs
`core.unicode.utf8.valid` and an import at the top of an `__init__` is a name
the package exports. `core.path` splits the same way and for the same reason.
"""

from core.io import Byte
from core.unicode.utf8 import valid

comptime _SLASH = Byte(ord("/"))
comptime _DOT = Byte(ord("."))


def valid_path(name: StringSlice) -> Bool:
    """Whether `name` is a name this package would accept. Go's `fs.ValidPath`.

    ```mojo
    from core.io.fs import valid_path

    print(valid_path("a/b"))  # => True
    print(valid_path("a//b"))  # => False
    print(valid_path("."))  # => True
    ```

    Valid UTF-8, not empty, no leading or trailing slash, no two slashes in a
    row, and no element that is `.` or `..`. The root is `"."` and is the one
    name with a dot in it that passes, which is what makes it possible to name
    the tree itself.

    So this is `clean` and `is_abs` asked as one question and asked in the
    strict direction: a name that would need cleaning is refused rather than
    cleaned, because the caller who assembled it is the one who knows what it
    was supposed to mean.
    """
    var raw = name.as_bytes()
    if not valid(raw):
        return False
    if name == ".":
        return True

    var start = 0
    for i in range(len(raw) + 1):
        # One past the end counts as a separator, so the last element is
        # checked by the same three tests as the ones before it.
        if i == len(raw) or raw[i] == _SLASH:
            var elem = raw[start:i]
            if len(elem) == 0:
                return False
            if len(elem) == 1 and elem[0] == _DOT:
                return False
            if len(elem) == 2 and elem[0] == _DOT and elem[1] == _DOT:
                return False
            start = i + 1
    return True
