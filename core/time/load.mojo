"""Finding a zone file on the host and turning it into a location. Go's
`LoadLocation` and the `Local` behind it.

`tzif.mojo` reads the bytes of a compiled zone file. This is the part that goes
and gets them: it takes a name like `Europe/Berlin`, works out which of the
directories a system might keep its zone database in actually has it, reads the
file and hands the bytes on. `local()` is the same walk for the one zone the
host itself is set to.

## Where it looks

`ZONEINFO` first, if it is set to something, then the four directories Go lists,
in Go's order: `/usr/share/zoneinfo/`, which is where almost every system keeps
it, `/usr/share/lib/zoneinfo/` for Solaris, `/usr/lib/locale/TZ/` for IRIX, and
`/etc/zoneinfo` for NixOS. The first one that has a file by that name wins, and
a directory that does not have it is not a failure, so a machine with two of
these and a name in the second answers the same as a machine with one.

A name is checked before any of that happens. No IANA zone name has two dots in
a row and none begins with a slash or a backslash, so a name that does is a path
somebody assembled and not a zone, and looking it up would mean reading a file
nobody meant to name. Those are refused with `ErrBadLocationName`, which is the
same three tests Go makes.

## What is not here

Go also reads `$GOROOT/lib/time/zoneinfo.zip` and, if the program imported
`time/tzdata`, a copy of the database compiled into the binary. There is no
GOROOT here, so the first has nothing to point at, and the second is
`core.time.tzdata`, which is not written yet. Go wires that one up with a
package level function variable that `tzdata`'s `init` assigns, and this library
has neither module level mutable state nor `init`, so when it arrives it will be
something a caller reaches for by name rather than something that appears
underneath this.

Windows keeps its zones in the registry rather than in files and Go has a
separate implementation for it. This library builds on macOS and Linux, and a
Windows port of this file is its own piece of work.

## Nothing is cached

Go's `LoadLocation` reads the file on every call too, so a named zone costs the
same on both sides. Its `Local` does not: that one is built by a `sync.Once` the
first time anything asks and every later mention of `time.Local` is free, and
`local()` here reads `/etc/localtime` again each time. The reason is the same one
that makes `utc()` a function, that a `Location` holds a counted handle to a
table with a destructor and there is nowhere at module scope to keep one. A
program that reads a lot of times in one zone should load the location once and
pass the copy about, which costs an atomic increment. `docs/deviations.md` has
the row.
"""

from core.errors import ErrorValue, Report, capture, field
from core.errors.codes import (
    ErrBadLocationName,
    ErrUnknownZone,
    ErrZoneFileTooLarge,
)
from core.syscall import ENOENT, O_RDONLY, close, getenv, open, read

from .tzif import load_location_from_tz_data
from .zone import Location, utc

comptime Byte = UInt8

comptime _MAX_FILE_SIZE = 10 << 20
"""The largest file the search will read, ten megabytes, which is Go's limit.

The whole database is about half of that and the largest single zone in it is
under four kilobytes, so nothing this refuses was ever a zone file. It is here
because a name resolves to a path and a path can be anything.
"""

comptime _CHUNK = 4096
"""How much is asked for per `read`. Go uses the same, and a zone file is
usually one of these."""


def _platform_sources() -> List[String]:
    """The directories a system might keep its zone database in, in Go's order.

    A function rather than a constant because a `List` is not something a module
    level `var` can hold. The last of the four has no trailing slash, which is
    how Go writes it: the separator is added when the name is joined on, so the
    other three produce a doubled slash and every system in the set treats that
    as one.
    """
    return [
        String("/usr/share/zoneinfo/"),
        String("/usr/share/lib/zoneinfo/"),
        String("/usr/lib/locale/TZ/"),
        String("/etc/zoneinfo"),
    ]


def load_location(name: StringSlice) raises -> Location:
    """The location the host's zone database has under this name. Go's
    `LoadLocation`.

    ```mojo
    from core.time import load_location

    var berlin = load_location("Europe/Berlin")
    print(berlin)  # => Europe/Berlin
    ```

    `""` and `"UTC"` are UTC and read nothing. `"Local"` is whatever the host is
    set to, which is `local()`. Anything else is an IANA name such as
    `America/New_York`, looked for in the directories listed at the top of this
    file.

    Raises `ErrBadLocationName` if the name is a path rather than a zone,
    `ErrUnknownZone` if no directory had it, `ErrBadZoneData` if one had a file
    by that name which is not a zone file, and whatever the platform said if a
    directory refused for any reason other than the file not being there.
    """
    if name == "" or name == "UTC":
        return utc()
    if name == "Local":
        return local()
    if not _is_zone_name(name):
        # Go's message, unchanged, the same as every other raise in this
        # package. The name goes in a field rather than in the sentence, so a
        # caller that wants to log which name was refused has it without
        # reading English.
        raise (
            Report("time: invalid location name")
            .with_field("name", String(name))
            .with_code(ErrBadLocationName)
            .error()
        )

    var sources = List[String]()
    var zoneinfo = getenv("ZONEINFO")
    if zoneinfo and zoneinfo.value() != "":
        sources.append(zoneinfo.value())
    sources.extend(_platform_sources())
    return _load_from_sources(name, sources)


def local() -> Location:
    """The zone the host itself is set to. Go's `Local`.

    ```mojo
    from core.time import local, now

    print(now().in_location(local()).zone()[0])
    ```

    `TZ` decides, and the three cases are Go's. No `TZ` at all means read
    `/etc/localtime`, which is where a system records the choice made when it
    was installed. `TZ` set to an absolute path means read that file. `TZ` set
    to anything else means look that name up the way `load_location` would,
    except that `ZONEINFO` is not consulted, which is also what Go does.

    `TZ` set to the empty string means UTC, and so does every one of the above
    failing. This is the one place in the package that answers a question it
    could not work out rather than raising: a program asking what time it is
    locally on a machine with no zone database wants an answer, and Go gives it
    UTC.
    """
    var tz = getenv("TZ")
    if not tz:
        # No TZ. The host's own choice, and the name is `Local` rather than the
        # path it came from, because `/etc/localtime` is a copy of a zone file
        # and does not say which one.
        try:
            var loc = _load_one("/etc", "localtime")
            _rename(loc, "Local")
            return loc^
        except:
            return utc()

    var want = tz.value()
    # A leading colon is the POSIX way of saying the rest is implementation
    # defined, which for every system in the set means a file name.
    if want.startswith(":"):
        var rest = String(want[byte=1:])
        want = rest^
    if want == "":
        return utc()

    if want.as_bytes()[0] == UInt8(ord("/")):
        try:
            var loc = _load_one("", want)
            if want == "/etc/localtime":
                _rename(loc, "Local")
            else:
                _rename(loc, want)
            return loc^
        except:
            return utc()

    if want != "UTC":
        try:
            return _load_from_sources(want, _platform_sources())
        except:
            return utc()

    return utc()


def _rename(mut loc: Location, name: StringSlice):
    """Call this location something else.

    Only ever used on a location this file has just built and is the only holder
    of, which is why writing through the counted handle is safe here and is not
    something `Location` offers. A zone file does not carry its own name, so the
    name is whatever the loader decided, and `local()` decides differently
    depending on how it found the file.
    """
    if loc.table:
        loc.table.value()[].name = String(name)


def _is_zone_name(name: StringSlice) -> Bool:
    """Whether this could be an IANA zone name at all.

    Go's three tests in `LoadLocation`, which are that the name holds no two
    dots in a row and does not begin with a separator. Go looks for `..`
    anywhere rather than as a whole path element, and the reason it gives is
    that no valid name contains even a single dot, so there is nothing to be
    careful about losing.
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


def _load_from_sources(
    name: StringSlice, sources: List[String]
) raises -> Location:
    """The first of these directories that has a readable zone file by this
    name.

    Go's `loadLocation`, including which failure it keeps. A directory that does
    not have the file is not a failure and the search moves on. Anything else is
    remembered, but only the first of them, and only if the search never
    succeeds: a `/usr/share/zoneinfo` nobody may read is worth reporting on a
    host that has no zone anywhere, and worth saying nothing about on a host
    where the next directory answered.
    """
    # Captured rather than held as an `Error`. A record lives on the thread
    # until the next raise on it, and the next raise is the next source in this
    # very loop, so keeping the `Error` would keep the sentence and hand back
    # somebody else's errno and code. `docs/design.md` section 4.
    var first = Optional[ErrorValue](None)
    for source in sources:
        try:
            return _load_one(source, name)
        except e:
            if not first and not _is_not_there(e):
                first = capture(e)
    if first:
        raise first.value().error()
    raise (
        Report(String("unknown time zone ", name))
        .with_field("name", String(name))
        .with_code(ErrUnknownZone)
        .error()
    )


def _load_one(dir: StringSlice, name: StringSlice) raises -> Location:
    """One directory, one name, read and parsed.

    An empty directory means the name is the whole path, which is how `local()`
    reads an absolute `TZ`.
    """
    var path = String(name)
    if dir.byte_length() != 0:
        path = String(dir, "/", name)
    var data = _read_file(path)
    return load_location_from_tz_data(name, Span(data))


def _read_file(path: String) raises -> List[Byte]:
    """The whole of a file, or a failure.

    Go's `readFile`, written here rather than taken from `core.io.fs` because
    that package is not written yet. It stops at `_MAX_FILE_SIZE` so that a name
    which resolved to something enormous costs a read and not the memory.
    """
    var fd = open(path, O_RDONLY, 0)
    var out = List[Byte]()
    var room = List[Byte](length=_CHUNK, fill=0)
    while True:
        var n: Int
        try:
            n = read(fd, Span(room))
        except e:
            close(fd)
            raise e
        if n == 0:
            break
        out.extend(Span(room)[0:n])
        if len(out) > _MAX_FILE_SIZE:
            close(fd)
            raise (
                Report(String("time: file ", path, " is too large"))
                .with_field("path", path)
                .with_code(ErrZoneFileTooLarge)
                .error()
            )
    close(fd)
    return out^


def _is_not_there(e: Error) -> Bool:
    """Whether this failure was the file not being there.

    The one failure the search steps over. It is read out of the `errno` field
    every `core.syscall` failure carries rather than out of the sentence, which
    is the whole reason that package keeps the number.
    """
    var got = field(e, "errno")
    if not got:
        return False
    return got.value() == String(ENOENT)
