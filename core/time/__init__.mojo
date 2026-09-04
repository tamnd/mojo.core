"""Instants, elapsed time, and the calendar between them. Go's `time` package.

Two types carry the package. A `Duration` is a length of time, held as a signed
count of nanoseconds, and a `Time` is a point in time, held as seconds and
nanoseconds from the year 1. Subtracting two of the second gives one of the
first, which is the relationship everything else is built from.

Start with `now` for what time it is, `since` for how long something took, and
`date` for building an instant out of the parts a person would write down. The
constants are the way to say how long: `5 * SECOND` rather than `5000000000`.

```mojo
from core.time import HOUR, MARCH, date, since

var t = date(2024, MARCH, 9, 14, 5, 0, 0)
print(t + 3 * HOUR)  # => 2024-03-09 17:05:00 +0000 UTC
```

## What is here and what is not

Instants, durations, the Gregorian calendar and the arithmetic over all three,
which is enough to measure how long something took, to say what day a date falls
on, and to move about the calendar.

The zones are here too. A `Time` carries a `Location` and reads every field
against it, `load_location` finds one in the host's database by name,
`local()` is the zone the host is set to, `fixed_zone` builds one that never
changes, and `utc()` is the one every `Time` that nobody gave a location to
already has.

```mojo
from core.time import OCTOBER, date, load_location

var berlin = load_location("Europe/Berlin")
print(date(2020, OCTOBER, 29, 15, 30, 0, 0, berlin))
# => 2020-10-29 15:30:00 +0100 CET
```

Not here yet, and each its own piece of work: the layout language and with it
`format` and `parse`, the timers, and `core.time.tzdata`, which is the copy of
the zone database a program can compile into itself so that it does not need the
host to have one. Where what is here behaves differently from Go rather than not
being here at all, `docs/deviations.md` has the row.

## Where the divisions are

Mojo's integer division rounds towards negative infinity and Go's rounds
towards zero, and this is a package full of negative numbers. `divide.mojo`
spells Go's two operators out as functions and says which one every division
here means, and `calendar.mojo` explains the far past epoch that lets the
calendar arithmetic avoid the question entirely.
"""

from .calendar import (
    APRIL,
    AUGUST,
    DECEMBER,
    FEBRUARY,
    FRIDAY,
    JANUARY,
    JULY,
    JUNE,
    MARCH,
    MAY,
    MONDAY,
    NOVEMBER,
    OCTOBER,
    SATURDAY,
    SECONDS_PER_DAY,
    SECONDS_PER_HOUR,
    SECONDS_PER_MINUTE,
    SECONDS_PER_WEEK,
    SEPTEMBER,
    SUNDAY,
    THURSDAY,
    TUESDAY,
    WEDNESDAY,
    Month,
    Weekday,
    days_before,
    days_in,
    is_leap,
)
from .duration import (
    HOUR,
    MICROSECOND,
    MILLISECOND,
    MINUTE,
    NANOSECOND,
    SECOND,
    Duration,
)
from .time import (
    Time,
    date,
    now,
    since,
    unix,
    unix_micro,
    unix_milli,
    until,
)
from .load import load_location, local
from .tzif import load_location_from_tz_data
from .zone import Location, Zone, fixed_zone, utc
