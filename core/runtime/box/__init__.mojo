"""The refcounted type erased heap box every erased struct in this library sits on.

Go has no package here. This exists because Mojo has no trait objects, so
`io.Reader`, `net.Conn`, the nine `database/sql` driver interfaces and the
values in a JSON document are all built by hand out of a box and a table of
function pointers. `erased.mojo` is the box and explains what is not checked.

The four free functions are here for the same reason the box is. A vtable slot
has one concrete type, so it cannot be parametric over the caller's origin and
cannot hold a tracked pointer: every span crossing one has to be laundered
first, and every address crossing one travels as an `Int`. Doing that means
naming methods the linter will not let a safe package name, so it happens here
and `core.io` stays safe.
"""

from .erased import (
    ErasedBox,
    address_of,
    at,
    launder,
    launder_ro,
    value,
)
