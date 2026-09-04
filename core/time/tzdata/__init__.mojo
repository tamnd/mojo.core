"""The IANA zone database, compiled into the program. Go's `time/tzdata`.

```mojo
from core.time.tzdata import load_location

var berlin = load_location("Europe/Berlin")
print(berlin)  # => Europe/Berlin
```

`core.time.load_location` reads the host's own database, which is the right
answer almost everywhere and no answer at all in the two places it is not: a
container built from scratch, and Windows. This package is the whole database
as data, 598 zones, so a program that imports it can name a zone without a file
system underneath it.

## It is named rather than installed

Go's package exports nothing whatsoever. Importing it runs an `init` that
assigns a package level function variable, and from that moment `LoadLocation`
quietly has a second place to look, which is a thing that happened to your
program because of a line in somebody else's file. There is no `init` here and
no package level variable to assign to, so the embedded copy is something the
caller asks for by name. A program that wants Go's arrangement writes it, and
can see that it did:

```mojo
from core.time import Location, load_location
from core.time.tzdata import load_location as load_embedded


def anywhere(name: String) raises -> Location:
    try:
        return load_location(name)
    except:
        return load_embedded(name)
```

## What it costs

About 460 KB of the binary, which is the database with the duplicates removed
and written as hex. Nothing is decoded until a zone is asked for, and then only
that zone, so the cost of the package is its size and nothing else. `data.mojo`
says how the two strings are arranged and `tools/gen/tzdata.py` says where they
came from.

## What is not here

`"Local"`. The embedded copy is a database and not a host, so it does not know
what this machine is set to, and a name it does not have raises `ErrUnknownZone`
like any other. `core.time.local()` is the function that answers that question.
"""

from core.errors import Report
from core.errors.codes import ErrBadLocationName, ErrUnknownZone
from core.time import Location, load_location_from_tz_data, utc

from .data import (
    BLOB,
    COUNT,
    INDEX,
    LENGTH_WIDTH,
    NAME_WIDTH,
    PAD,
    RECORD,
    START_WIDTH,
)


def load_location(name: StringSlice) raises -> Location:
    """The location the embedded database has under this name.

    ```mojo
    from core.time.tzdata import load_location

    print(load_location("Asia/Kathmandu"))  # => Asia/Kathmandu
    ```

    `""` and `"UTC"` are UTC and read nothing, which is what
    `core.time.load_location` does with them too.

    Raises `ErrBadLocationName` if the name is a path rather than a zone, and
    `ErrUnknownZone` if the database has no zone by that name, which includes
    `"Local"`. There is no third failure: the bytes were checked when they were
    generated, so a name that is in the index has a zone file behind it.
    """
    if name == "" or name == "UTC":
        return utc()
    if not _is_zone_name(name):
        # Refused before the lookup, and refused even though there is no file
        # system here for a path to escape into, so that a caller who swaps
        # this function for `core.time.load_location` gets the same answer to
        # the same bad name rather than a different one.
        raise (
            Report("time: invalid location name")
            .with_field("name", String(name))
            .with_code(ErrBadLocationName)
            .error()
        )

    var at = _find(name)
    if at < 0:
        raise (
            Report(String("unknown time zone ", name))
            .with_field("name", String(name))
            .with_code(ErrUnknownZone)
            .error()
        )

    var start = _number(at * RECORD + NAME_WIDTH, START_WIDTH)
    var length = _number(at * RECORD + NAME_WIDTH + START_WIDTH, LENGTH_WIDTH)
    var data = _file(start, length)
    return load_location_from_tz_data(name, Span(data))


def _is_zone_name(name: StringSlice) -> Bool:
    """Whether this could be an IANA zone name at all.

    Go's three tests, which are that the name holds no two dots in a row and
    does not begin with a separator. The same four lines as
    `core.time.load._is_zone_name` and not shared with it, because the two are
    different packages and a private function is not an interface.
    """
    var bytes = name.as_bytes()
    if len(bytes) == 0:
        return False
    if bytes[0] == UInt8(ord("/")) or bytes[0] == UInt8(ord("\\")):
        return False
    for i in range(len(bytes) - 1):
        if bytes[i] == UInt8(ord(".")) and bytes[i + 1] == UInt8(ord(".")):
            return False
    return True


def _find(name: StringSlice) -> Int:
    """Which record holds this name, or -1.

    A binary search over `INDEX`, whose records are all the same width and are
    in name order. The query is compared as though it were padded with `PAD` to
    the width of the name field, which is what the records are, and that keeps
    the order because `PAD` is below every byte a zone name contains:
    `Etc/GMT` still sorts before `Etc/GMT+0`.
    """
    var query = name.as_bytes()
    if len(query) > NAME_WIDTH:
        return -1
    for i in range(len(query)):
        # The one thing the padding cannot tell apart. A query holding `PAD`
        # pads to the same 32 bytes as the same name without it, so
        # `Europe/Berlin!` would find Europe/Berlin. No zone name holds that
        # byte, checked when this was generated, so a query that does is not a
        # name and there is nothing to find.
        if query[i] == UInt8(PAD):
            return -1

    var index = INDEX.as_bytes()
    var lo = 0
    var hi = COUNT
    while lo < hi:
        var mid = (lo + hi) // 2
        var at = mid * RECORD
        var order = 0
        for i in range(NAME_WIDTH):
            var want = query[i] if i < len(query) else UInt8(PAD)
            var got = index[at + i]
            if want != got:
                order = -1 if want < got else 1
                break
        if order == 0:
            return mid
        if order < 0:
            hi = mid
        else:
            lo = mid + 1
    return -1


def _number(at: Int, width: Int) -> Int:
    """The hex number of `width` digits that starts at `at` in `INDEX`."""
    var index = INDEX.as_bytes()
    var out = 0
    for i in range(at, at + width):
        out = (out << 4) | Int(_nibble(index[i]))
    return out


def _file(start: Int, length: Int) -> List[UInt8]:
    """The `length` bytes of `BLOB` that begin at `start`.

    Two hex characters to a byte, so the characters wanted are twice as far
    along and twice as many. Only the one zone that was asked for is decoded.
    """
    var blob = BLOB.as_bytes()
    var out = List[UInt8](capacity=length)
    for i in range(start * 2, (start + length) * 2, 2):
        out.append((_nibble(blob[i]) << 4) | _nibble(blob[i + 1]))
    return out^


def _nibble(c: UInt8) -> UInt8:
    """The value of one hex digit.

    Lower case, no separators, which is the only form the generator writes.
    Nothing validates the input because nothing but the generated file supplies
    it.
    """
    if c >= UInt8(ord("a")):
        return c - UInt8(ord("a")) + 10
    return c - UInt8(ord("0"))
