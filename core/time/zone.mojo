"""A time zone, and the lookup that turns an instant into a wall clock offset.
Go's `Location`.

A location is a geographical area that has agreed to keep the same clock, and
what it holds is the history of that clock: a list of the named offsets the area
has used, a list of the instants it changed between them, and a rule for what
happens after the list runs out. `lookup` is the one question it answers, and
everything about the printed form of a `Time` is that question asked once.

## A location is a value here, not a pointer

Go's `Location` is always used through a pointer. `time.UTC` is a pointer, a
`Time` holds one, and a nil one means UTC. That works because Go has a garbage
collector, so a location outlives every `Time` that points at it without anybody
saying how.

This is a value, and copying one copies its two lists. The copy has to be asked
for with `.copy()`: `Location` is `Copyable` and not `ImplicitlyCopyable`,
which falls out of `List` being the same and is the right answer anyway, since
it means the two allocations are always visible at the point they happen.

That is fine for what is here, where a caller loads a location and asks it
questions, and it is not fine for putting one inside every `Time`: a `Time` is
four machine words that copy for free, and it has to stay that way. So a `Time`
does not hold a `Location` yet, and every method of `Time` still reads UTC. The
mechanism that connects the two is its own piece of work.

## The one element cache

Almost every lookup a program makes is for a time close to now, and finding it
means a binary search through a few hundred transitions. Go keeps a one element
cache of the zone in force when the location was loaded, and so does this. Go's
cache is a pointer into the location's own list of zones, which is a thing this
language declines to hold, so the cache here is a copy of the zone instead. That
is also what lets the cache hold a zone the list does not contain, which happens
when the answer came from the TZ string rather than from the file.
"""

from core.syscall import CLOCK_REALTIME, clock_gettime

from .tzset import _ALPHA, _OMEGA, _tzset


struct Zone(Copyable, Equatable, ImplicitlyCopyable, Movable):
    """One named offset from UTC, such as CET. Go's `zone`.

    Not a time zone in the sense a person means it. A location is the place and
    this is one of the several clocks the place has kept, so `America/New_York`
    has two of these, EST and EDT, and moves between them twice a year.
    """

    var name: String
    """The abbreviation, such as `CET`. Numeric for a zone with no name of its
    own, such as `-03`, which is what tzdata now writes rather than inventing
    letters."""

    var offset: Int
    """Seconds east of UTC. Negative for the Americas."""

    var is_dst: Bool
    """Whether this is the daylight saving clock rather than the standard one.
    """

    def __init__(out self, name: StringSlice, offset: Int, is_dst: Bool):
        """Hold a name, an offset and the daylight flag."""
        self.name = String(name)
        self.offset = offset
        self.is_dst = is_dst

    def __eq__(self, other: Self) -> Bool:
        """Whether these are the same zone in all three fields."""
        return (
            self.name == other.name
            and self.offset == other.offset
            and self.is_dst == other.is_dst
        )

    def __ne__(self, other: Self) -> Bool:
        """Whether these differ in any field."""
        return not (self == other)


struct ZoneTrans(Copyable, Equatable, ImplicitlyCopyable, Movable):
    """One moment at which a location changed clocks. Go's `zoneTrans`.

    Go carries two more fields, `isstd` and `isutc`, which its own comment says
    it has no idea what they mean. They are read out of the file, never looked
    at, and are not here.
    """

    var when: Int
    """The instant of the change, in seconds since 1970 UTC."""

    var index: Int
    """Which zone of the location's list comes into force at that instant."""

    def __init__(out self, when: Int, index: Int):
        """Hold an instant and a zone index."""
        self.when = when
        self.index = index

    def __eq__(self, other: Self) -> Bool:
        """Whether these are the same transition."""
        return self.when == other.when and self.index == other.index

    def __ne__(self, other: Self) -> Bool:
        """Whether these are different transitions."""
        return not (self == other)


struct Location(Copyable, Movable, Writable):
    """The clock history of a place. Go's `Location`.

    ```mojo
    from core.time import fixed_zone

    var loc = fixed_zone("CET", 3600)
    print(loc)  # => CET
    ```

    The default value is UTC, and so is any location with no zones in it, which
    is what makes a location that failed to load behave like UTC rather than
    like nothing.
    """

    var name: String
    """What to call it: an IANA name such as `Europe/Berlin`, or `UTC`, or
    whatever was passed to `fixed_zone`."""

    var zone: List[Zone]
    """Every clock the place has kept, in the order the file lists them."""

    var tx: List[ZoneTrans]
    """Every change between them, in increasing order of instant."""

    var extend: String
    """The TZ string for what happens after the last transition, or nothing.

    See `tzset.mojo`. A file that ends in 2037 and a file that ends in 1996
    both answer questions about next year, and this is how.
    """

    var cache_start: Int
    """The instant `cache_zone` came into force."""

    var cache_end: Int
    """The instant `cache_zone` goes out of force."""

    var cache_zone: Zone
    """The zone in force when this location was loaded."""

    var has_cache: Bool
    """Whether the three cache fields mean anything."""

    def __init__(out self):
        """UTC, which is what a location with nothing in it is."""
        self.name = "UTC"
        self.zone = []
        self.tx = []
        self.extend = ""
        self.cache_start = 0
        self.cache_end = 0
        self.cache_zone = Zone("UTC", 0, False)
        self.has_cache = False

    def __init__(
        out self,
        name: StringSlice,
        var zone: List[Zone],
        var tx: List[ZoneTrans],
        extend: StringSlice,
    ):
        """Hold a name, the zones, the transitions and the TZ string.

        The cache is left empty. `load_location_from_tz_data` fills it, because
        filling it means reading the clock and a constructor is not where that
        belongs.
        """
        self.name = String(name)
        self.zone = zone^
        self.tx = tx^
        self.extend = String(extend)
        self.cache_start = 0
        self.cache_end = 0
        self.cache_zone = Zone("UTC", 0, False)
        self.has_cache = False

    def write_to[W: Writer](self, mut writer: W):
        """The name, which is Go's `Location.String`."""
        writer.write(self.name)

    def lookup(self, sec: Int) -> Tuple[String, Int, Int, Int, Bool]:
        """The zone in force at `sec`, a Unix second. Go's `Location.lookup`.

        The answer is the zone name, its offset in seconds east of UTC, the
        instant it came into force, the instant it goes out, and whether it is
        daylight time. The two instants are `_ALPHA` and `_OMEGA` where there is
        nothing before or after.

        The name is copied out rather than borrowed. Go returns a string header
        that shares the location's bytes, which a value type cannot do without
        tying the answer to the lifetime of the location, and a zone
        abbreviation is at most a handful of bytes.
        """
        if len(self.zone) == 0:
            return (String("UTC"), 0, _ALPHA, _OMEGA, False)

        if self.has_cache and self.cache_start <= sec and sec < self.cache_end:
            return (
                self.cache_zone.name,
                self.cache_zone.offset,
                self.cache_start,
                self.cache_end,
                self.cache_zone.is_dst,
            )

        if len(self.tx) == 0 or sec < self.tx[0].when:
            var z = self.zone[self._lookup_first_zone()]
            var end = self.tx[0].when if len(self.tx) > 0 else _OMEGA
            return (z.name, z.offset, _ALPHA, end, z.is_dst)

        # The largest transition at or before `sec`. Go writes the search out
        # rather than calling into `sort` so that `time` depends on nothing, and
        # this does the same for the same reason.
        var end = _OMEGA
        var lo = 0
        var hi = len(self.tx)
        while hi - lo > 1:
            var m = (lo + hi) // 2
            var lim = self.tx[m].when
            if sec < lim:
                end = lim
                hi = m
            else:
                lo = m

        var z = self.zone[self.tx[lo].index]
        var start = self.tx[lo].when

        # Past the last recorded change, the TZ string is the answer if there is
        # one. This is the ordinary case for a slim file, not a corner of it.
        if lo == len(self.tx) - 1 and self.extend != "":
            var ext = _tzset(self.extend, start, sec)
            if ext[5]:
                return (ext[0], ext[1], ext[2], ext[3], ext[4])

        return (z.name, z.offset, start, end, z.is_dst)

    def lookup_name(self, name: StringSlice, unix: Int) -> Tuple[Int, Bool]:
        """The offset of the zone called `name` around `unix`. Go's
        `lookupName`.

        `unix` is what the wall clock time being looked up would be if it were
        UTC, which is what the layout language has in hand while parsing and
        before it knows the offset. Two zones of a location can share a name,
        which is why the time is needed at all: Sydney called both of its clocks
        EST for years.

        The first pass asks which zone was actually in force, and the second
        settles for any zone with the right name. Around a backward change the
        first pass can pick either, and Go says so too.
        """
        for i in range(len(self.zone)):
            var z = self.zone[i]
            if z.name == name:
                var got = self.lookup(unix - z.offset)
                if got[0] == z.name:
                    return (got[1], True)
        for i in range(len(self.zone)):
            var z = self.zone[i]
            if z.name == name:
                return (z.offset, True)
        return (0, False)

    def _lookup_first_zone(self) -> Int:
        """Which zone to use before the first recorded change. Go's
        `lookupFirstZone`.

        The four cases are tzcode's, in tzcode's order, and the reason they are
        not simply "the first zone" is that a file whose first zone is unused
        has it there as a placeholder. Go's comment cites the release of tzcode
        the algorithm is from and this follows it step for step.
        """
        # A first zone no transition names is a placeholder, and is the answer.
        if not self._first_zone_used():
            return 0

        # Otherwise, if the first change is into daylight time, the standard
        # zone before it is what was in force before.
        if len(self.tx) > 0 and self.zone[self.tx[0].index].is_dst:
            var zi = self.tx[0].index - 1
            while zi >= 0:
                if not self.zone[zi].is_dst:
                    return zi
                zi -= 1

        # Otherwise the first standard zone anywhere in the list.
        for i in range(len(self.zone)):
            if not self.zone[i].is_dst:
                return i

        # Otherwise there is nothing better than the first.
        return 0

    def _first_zone_used(self) -> Bool:
        """Whether any transition names the first zone. Go's `firstZoneUsed`."""
        for i in range(len(self.tx)):
            if self.tx[i].index == 0:
                return True
        return False

    def _fill_cache(mut self) raises:
        """Point the cache at the zone in force right now.

        Go does this at the end of `LoadLocationFromTZData` for the same reason:
        the next lookup is almost certainly for a time near now, and this turns
        that lookup into two comparisons.
        """
        var sec = clock_gettime(CLOCK_REALTIME).sec
        for i in range(len(self.tx)):
            var at_or_before = self.tx[i].when <= sec
            var before_next = i + 1 == len(self.tx) or sec < self.tx[i + 1].when
            if not (at_or_before and before_next):
                continue
            self.cache_start = self.tx[i].when
            self.cache_end = _OMEGA
            self.cache_zone = self.zone[self.tx[i].index]
            self.has_cache = True
            if i + 1 < len(self.tx):
                self.cache_end = self.tx[i + 1].when
            elif self.extend != "":
                var ext = _tzset(self.extend, self.cache_start, sec)
                if ext[5]:
                    self.cache_start = ext[2]
                    self.cache_end = ext[3]
                    self.cache_zone = Zone(ext[0], ext[1], ext[4])
            return


def utc() -> Location:
    """Universal Coordinated Time. Go's `UTC`.

    ```mojo
    from core.time import utc

    print(utc())  # => UTC
    ```

    A function rather than a constant, because a location holds two lists and a
    list cannot live at module scope in this language. It holds no zones, so
    building one allocates nothing.
    """
    return Location()


def fixed_zone(name: StringSlice, offset: Int) -> Location:
    """A location that keeps one clock forever. Go's `FixedZone`.

    ```mojo
    from core.time import fixed_zone

    var cet = fixed_zone("CET", 3600)
    print(cet)  # => CET
    ```

    `offset` is seconds east of UTC, so an hour ahead is 3600 and New York's
    standard time is -18000. Nothing about it changes with the date, which is
    what makes it the wrong thing to use for a place: use `load_location` for
    somewhere real and this for a fixed offset that came off the wire.

    Go interns the unnamed whole hour offsets and hands the same pointer back
    for each. There is no pointer here to hand back, so there is nothing to
    intern and every call builds one.
    """
    var zones: List[Zone] = [Zone(name, offset, False)]
    var txs: List[ZoneTrans] = [ZoneTrans(_ALPHA, 0)]
    var loc = Location(name, zones^, txs^, "")
    loc.cache_start = _ALPHA
    loc.cache_end = _OMEGA
    loc.cache_zone = Zone(name, offset, False)
    loc.has_cache = True
    return loc^
