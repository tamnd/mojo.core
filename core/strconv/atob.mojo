"""Booleans. Go's `atob.go`.

Six spellings of true and six of false, and nothing else. Not `yes`, not `on`,
not the empty string, and not `True ` with a space: whatever produced the text
can be asked to produce one of the twelve.
"""

from core.strconv.num_error import _syntax_error


def parse_bool[o: ImmOrigin](s: StringSlice[o]) raises -> Bool:
    """`s` as a boolean. Go's `ParseBool`.

    Accepts `1`, `t`, `T`, `true`, `TRUE`, `True`, and the six matching
    spellings of false. Everything else raises with `ErrSyntax`, including
    `tRuE`, because Go accepts three capitalisations rather than all of them.

    ```mojo
    from core.strconv import parse_bool

    def main() raises:
        print(parse_bool("TRUE"))  # True
    ```
    """
    if (
        s == "1"
        or s == "t"
        or s == "T"
        or s == "true"
        or s == "TRUE"
        or (s == "True")
    ):
        return True
    if (
        s == "0"
        or s == "f"
        or s == "F"
        or s == "false"
        or s == "FALSE"
        or (s == "False")
    ):
        return False
    raise _syntax_error("parse_bool", s)


def format_bool(b: Bool) -> String:
    """`true` or `false`. Go's `FormatBool`.

    Lower case, which is Go's spelling of a boolean literal rather than Mojo's.
    A round trip through `parse_bool` works either way, since `True` is one of
    the spellings it takes.
    """
    return "true" if b else "false"


def append_bool(mut dst: List[UInt8], b: Bool) -> Int:
    """`format_bool(b)` onto the end of `dst`, and how many bytes that took.
    Go's `AppendBool`."""
    var text = "true" if b else "false"
    for byte in text.as_bytes():
        dst.append(byte)
    return len(text.as_bytes())
