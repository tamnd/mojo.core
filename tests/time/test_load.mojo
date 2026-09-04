"""The zone file search, against a database this test builds.

Every test here writes Go's slim files into a scratch directory of its own and
points `ZONEINFO` at it, so what is being checked is the search and not the host.
A machine with no `/usr/share/zoneinfo` gives the same answers as one with the
whole database, which matters because two of the three platforms in the test
matrix are containers.

The scratch directory carries the process id, the same as `tests/syscall`, and
every test takes away what it made and puts `TZ` and `ZONEINFO` back the way it
found them. Both of those are process wide, and a test that leaks one changes
what a later test in the same process sees.
"""

from std.testing import (
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)

from tests.generated.tzif import BERLIN_2020B, NUUK_2021A, bytes_of

from core.errors import field, matches
from core.errors.codes import ErrBadZoneData
from core.syscall import (
    ENOTDIR,
    close,
    create,
    getenv,
    getpid,
    mkdir,
    rmdir,
    setenv,
    unlink,
    unsetenv,
    write,
)
from core.time import (
    JANUARY,
    OCTOBER,
    date,
    load_location,
    load_location_from_tz_data,
    local,
    utc,
)

comptime Byte = UInt8


struct _Env(Movable):
    """`TZ` and `ZONEINFO` as they were, put back when this goes out of scope.

    A destructor rather than a call at the end of each test, because a test that
    fails half way through still has to leave the environment alone: the next
    test in the same process reads the same two variables.
    """

    var tz: Optional[String]
    var zoneinfo: Optional[String]

    def __init__(out self):
        self.tz = getenv("TZ")
        self.zoneinfo = getenv("ZONEINFO")

    def __deinit__(deinit self):
        try:
            if self.tz:
                setenv("TZ", self.tz.value())
            else:
                unsetenv("TZ")
            if self.zoneinfo:
                setenv("ZONEINFO", self.zoneinfo.value())
            else:
                unsetenv("ZONEINFO")
        except:
            pass


def _scratch(name: String) raises -> String:
    """An empty directory of our own, with `Europe` and `America` under it.

    The two subdirectories are there because an IANA name has a region in it and
    the search joins the name onto the source directory whole, so the loader
    only ever finds a file that is already two levels down.
    """
    var place = String("/tmp/mojo-core-time-", getpid(), "-", name)
    _clear(place)
    mkdir(place, 0o700)
    mkdir(String(place, "/Europe"), 0o700)
    mkdir(String(place, "/America"), 0o700)
    return place


def _clear(place: String):
    """Take the scratch directory away, whatever is in it.

    Two levels deep and no deeper, because nothing here makes a deeper one.
    Every step is allowed to fail: this is called before a test as well as
    after, and before one there is usually nothing there.
    """
    for region in ["Europe", "America"]:
        var dir = String(place, "/", region)
        for name in ["Berlin", "Nuuk", "Nowhere", "Rubbish"]:
            try:
                unlink(String(dir, "/", name))
            except:
                pass
        try:
            rmdir(dir)
        except:
            pass
    try:
        rmdir(place)
    except:
        pass


def _put(path: String, data: List[Byte]) raises:
    """Write these bytes at this path, making the file."""
    var fd = create(path, 0o600)
    var wrote = write(fd, Span(data))
    close(fd)
    if wrote != len(data):
        raise Error("the scratch file was written short")


def test_a_name_that_is_a_path_is_refused() raises:
    """The three tests Go makes before it looks anywhere.

    All of these would resolve to a real file on a real machine, which is the
    point: a name is refused for its shape, before anything is read, so a
    program passing a name it took from somewhere else cannot be talked into
    reading `/etc/shadow`.
    """
    for name in [
        String("/etc/localtime"),
        String("\\etc\\localtime"),
        String("../etc/localtime"),
        String("Europe/../../etc/passwd"),
        String(".."),
    ]:
        with assert_raises(contains="time: invalid location name"):
            _ = load_location(name)


def test_the_refusal_carries_the_name_and_reads_nothing() raises:
    # The name is in a field, so a caller logging what was refused does not have
    # to take it back out of the sentence.
    try:
        _ = load_location("../Europe/Berlin")
        raise Error("a name that is a path should have been refused")
    except e:
        assert_equal(field(e, "name").value(), "../Europe/Berlin")


def test_a_single_dot_is_allowed_through() raises:
    """Go looks for two dots in a row and not for one.

    No IANA name has even a single dot, so nothing real reaches this, but the
    check is written the way Go writes it and this is the line that says so. It
    gets as far as the search and comes back unknown rather than invalid.
    """
    var env = _Env()
    var place = _scratch("singledot")
    setenv("ZONEINFO", place)
    with assert_raises(contains="unknown time zone"):
        _ = load_location("Europe/Ber.lin")
    _clear(place)
    _ = env^


def test_the_empty_name_and_utc_read_nothing() raises:
    # Both are UTC and neither goes near the file system, which is what makes
    # them the two names that work on a machine with no zone database.
    var env = _Env()
    setenv("ZONEINFO", "/nowhere/at/all")
    assert_equal(String(load_location("")), "UTC")
    assert_equal(String(load_location("UTC")), "UTC")
    assert_false(load_location("UTC").table)
    _ = env^


def test_zoneinfo_names_the_directory_to_look_in() raises:
    var env = _Env()
    var place = _scratch("found")
    _put(String(place, "/Europe/Berlin"), bytes_of(BERLIN_2020B))
    setenv("ZONEINFO", place)

    var berlin = load_location("Europe/Berlin")
    assert_equal(String(berlin), "Europe/Berlin")

    # The same instant Go's own slim test uses, so this is the loaded file
    # answering rather than the search reporting that it found something.
    var t = date(2020, OCTOBER, 29, 15, 30, 0, 0, berlin)
    assert_equal(t.unix(), 1603981800)
    var name, offset = t.zone()
    assert_equal(name, "CET")
    assert_equal(offset, 3600)

    _clear(place)
    _ = env^


def test_a_file_found_this_way_is_the_file_read_from_bytes() raises:
    # The search adds nothing to what `load_location_from_tz_data` does, and
    # this is the line that would fail if it did: same bytes, same name, and
    # every answer has to agree.
    var env = _Env()
    var place = _scratch("sameanswer")
    var data = bytes_of(NUUK_2021A)
    _put(String(place, "/America/Nuuk"), data)
    setenv("ZONEINFO", place)

    var found = load_location("America/Nuuk")
    var direct = load_location_from_tz_data("America/Nuuk", Span(data))
    for year in [1885, 1950, 2020, 2100]:
        var sec = date(year, JANUARY, 1, 12, 0, 0, 0, utc()).unix()
        var a = found.lookup(sec)
        var b = direct.lookup(sec)
        assert_equal(a[0], b[0])
        assert_equal(a[1], b[1])
        assert_equal(a[2], b[2])
        assert_equal(a[3], b[3])

    _clear(place)
    _ = env^


def test_zoneinfo_is_looked_at_before_the_platform_directories() raises:
    """The order, checked without depending on what the host has.

    Nuuk's file is written under Berlin's name. If the search reached
    `/usr/share/zoneinfo` first on a machine that has it, the answer would be
    an hour east of Greenwich; through `ZONEINFO` it is three hours west. A
    machine with no zone database gives the same answer, which is why the trick
    is worth the confusion.
    """
    var env = _Env()
    var place = _scratch("order")
    _put(String(place, "/Europe/Berlin"), bytes_of(NUUK_2021A))
    setenv("ZONEINFO", place)

    var loc = load_location("Europe/Berlin")
    var name, offset = date(2020, OCTOBER, 29, 15, 30, 0, 0, loc).zone()
    assert_equal(name, "-03")
    assert_equal(offset, -10800)

    _clear(place)
    _ = env^


def test_a_name_no_source_has() raises:
    var env = _Env()
    var place = _scratch("missing")
    setenv("ZONEINFO", place)
    with assert_raises(contains="unknown time zone Europe/Nowhere"):
        _ = load_location("Europe/Nowhere")
    _clear(place)
    _ = env^


def test_an_empty_zoneinfo_is_the_same_as_none() raises:
    # Go reads `ZONEINFO` once and treats the empty string as not set, so this
    # goes straight to the platform directories. The name is one no database
    # has, so the answer is the same either way and the assertion is that the
    # empty value did not become a source of its own and turn the lookup into a
    # read of `/Europe/Nowhere`.
    var env = _Env()
    setenv("ZONEINFO", "")
    with assert_raises(contains="unknown time zone"):
        _ = load_location("Europe/Nowhere")
    _ = env^


def test_a_file_that_is_not_a_zone_file() raises:
    # Found and refused, which is a different answer from not found: the search
    # stops rather than moving on, because a source that has the name has
    # answered.
    var env = _Env()
    var place = _scratch("rubbish")
    var junk = List[Byte]()
    for i in range(64):
        junk.append(Byte(i))
    _put(String(place, "/Europe/Rubbish"), junk)
    setenv("ZONEINFO", place)
    try:
        _ = load_location("Europe/Rubbish")
        raise Error("a file that is not a zone file should have been refused")
    except e:
        # The code as well as the sentence. The search carried on to the
        # platform directories after this and raised on each of them, and a
        # record lives on the thread only until the next raise, so this is the
        # line that fails if the first failure is held rather than captured.
        assert_true(matches(e, ErrBadZoneData))
    _clear(place)
    _ = env^


def test_the_failure_the_search_reports_is_the_first_real_one() raises:
    """Not the last, and not the file simply not being there.

    `ZONEINFO` points at a regular file here, so joining a name onto it gives a
    path whose parent is not a directory and the platform says `ENOTDIR`. The
    four platform directories are tried after it and each says `ENOENT`, which
    the search steps over. What comes back has to be the `ENOTDIR`, with the
    number still on it: a machine with no zone database anywhere is worth being
    told about, and being told the last of four `ENOENT`s says nothing.
    """
    var env = _Env()
    var place = _scratch("notadir")
    var file = String(place, "/Europe/Berlin")
    _put(file, bytes_of(BERLIN_2020B))
    setenv("ZONEINFO", file)

    try:
        _ = load_location("Europe/Nowhere")
        raise Error("a source that is a file should have failed")
    except e:
        assert_equal(field(e, "errno").value(), String(ENOTDIR))
        assert_equal(field(e, "op").value(), "open")

    _clear(place)
    _ = env^


def test_local_is_utc_when_tz_is_empty() raises:
    # POSIX says an empty TZ is UTC, and Go agrees. Nothing is read.
    var env = _Env()
    setenv("TZ", "")
    assert_equal(String(local()), "UTC")
    assert_false(local().table)
    _ = env^


def test_local_reads_the_file_an_absolute_tz_names() raises:
    var env = _Env()
    var place = _scratch("tzpath")
    var path = String(place, "/Europe/Berlin")
    _put(path, bytes_of(BERLIN_2020B))
    setenv("TZ", path)

    var loc = local()
    # Named after the path, because that is all the caller said. Only
    # `/etc/localtime` becomes `Local`, since that one is the host's own choice
    # rather than a file somebody pointed at.
    assert_equal(String(loc), path)
    var name, offset = date(2020, OCTOBER, 29, 15, 30, 0, 0, loc).zone()
    assert_equal(name, "CET")
    assert_equal(offset, 3600)

    _clear(place)
    _ = env^


def test_a_leading_colon_on_tz_is_dropped() raises:
    # POSIX writes `TZ=:/etc/localtime` and says everything after the colon is
    # the implementation's business, which on every system in the set means a
    # file name.
    var env = _Env()
    var place = _scratch("tzcolon")
    var path = String(place, "/Europe/Berlin")
    _put(path, bytes_of(BERLIN_2020B))
    setenv("TZ", String(":", path))

    var loc = local()
    assert_equal(String(loc), path)
    assert_equal(date(2020, OCTOBER, 29, 15, 30, 0, 0, loc).zone()[1], 3600)

    _clear(place)
    _ = env^


def test_local_falls_back_to_utc_rather_than_failing() raises:
    """The one question in this package that is always answered.

    A program asking what time it is locally wants a time, and a machine with
    no zone database is not a reason to raise at it. Go does the same, and both
    a path that is not there and a name nothing has come back as UTC.
    """
    var env = _Env()

    setenv("TZ", "/tmp/there-is-no-zone-file-here")
    assert_equal(String(local()), "UTC")

    setenv("TZ", "Nowhere/AtAll")
    assert_equal(String(local()), "UTC")

    _ = env^


def test_local_ignores_zoneinfo_when_tz_names_a_zone() raises:
    """Go looks only at the platform directories for this one.

    `ZONEINFO` is consulted by `LoadLocation` and not by the code behind
    `Local`, which is a difference nothing documents and which shows up as a
    program setting both and finding that only one of them mattered. The name
    here is in the scratch directory and nowhere else, so if `local()` did look
    at `ZONEINFO` it would find it, and finding it is the failure.
    """
    var env = _Env()
    var place = _scratch("localignores")
    _put(String(place, "/Europe/Nowhere"), bytes_of(BERLIN_2020B))
    setenv("ZONEINFO", place)
    setenv("TZ", "Europe/Nowhere")

    assert_equal(String(local()), "UTC")

    # Through `load_location`, which does read `ZONEINFO`, the same name loads.
    assert_equal(String(load_location("Europe/Nowhere")), "Europe/Nowhere")

    _clear(place)
    _ = env^


def test_local_by_name_is_local() raises:
    # `load_location("Local")` is `local()`, which is what Go's `LoadLocation`
    # does with the name. With TZ empty both are UTC, and this is checking the
    # name is routed rather than looked for in a directory.
    var env = _Env()
    setenv("TZ", "")
    assert_equal(String(load_location("Local")), "UTC")
    _ = env^
