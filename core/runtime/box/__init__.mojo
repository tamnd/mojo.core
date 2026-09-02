"""The refcounted type erased heap box every erased struct in this library sits on.

Go has no package here. This exists because Mojo has no trait objects, so
`io.Reader`, `net.Conn`, the nine `database/sql` driver interfaces and the
values in a JSON document are all built by hand out of a box and a table of
function pointers. `erased.mojo` is the box and explains what is not checked.
"""

from .erased import ErasedBox, value
