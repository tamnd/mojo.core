"""The thread local error record.

Mojo has exactly one error type and it carries a string. There is no hierarchy
and nothing to type assert against, so everything Go does with a concrete error
struct has to be built rather than translated.

The mechanism: raising code writes a record into this thread's slot holding the
fields Go would have put in a struct, and the raise itself carries the message.
The catch site looks the record up and gets the fields back.

```mojo
from core.errors import Report, field


def open_it(name: String) raises:
    raise (
        Report("open " + name + ": no such file or directory")
        .with_field("op", "open")
        .with_field("path", name)
        .error()
    )


def main():
    try:
        open_it("/nope")
    except e:
        print(field(e, "path").or_else("unknown"))
```

The slot itself is C, in shim/slot.c, because Mojo has no global mutable state
to build one out of. See that directory's README.

## Telling our errors from everybody else's

A record is matched to an error by the message it was raised with, and nothing
else. The record stores the message, the lookup compares it against the caught
error's message, and a mismatch means no fields.

That is what makes the two failure modes safe. An error raised by `std`, or by
any library that has never heard of this mechanism, finds a record whose
message is not its own and is correctly reported as carrying no fields. An
error held past the next raise on the same thread finds the newer record, sees
a different message, and reports no fields rather than the newer error's.

The limit is worth stating: two errors with the same message text on the same
thread are indistinguishable here, and the later one's fields win. In practice
the message is built from the fields, so two identical messages come from
identical fields, but that is a convention rather than something enforced.
Holding an error for longer than the next raise is what `capture` is for.
"""

from std.ffi import external_call
from std.sys import size_of

comptime _Any = AnyOrigin[mut=True]


struct Report(Movable):
    """An error being built, and the record it leaves behind.

    One struct doing both jobs rather than a builder and a record, because
    Mojo will not move a struct valued field out of an owned `self`. Splitting
    them means `error()` has to move the record out of the report, and that is
    the exact operation the compiler refuses with "field destroyed out of the
    middle of a value". So the thing that is built is the thing that is stored.

    Building is a chain so the fields read down the page in the order somebody
    would say them out loud, and so the common case of an error with no fields
    at all stays `Report(message).error()`.

    Nothing reads a `Report` back. The catch site uses the free functions below,
    which copy out of it, so no caller ends up holding a reference into storage
    the next raise is going to overwrite.
    """

    var message: String
    """The message the error was raised with. This is the identity check."""

    var code: Int
    """Which kind of error this is, for matching against a sentinel."""

    var count: Int
    """Go returns `(n, err)` and a raise drops the n. This is where it goes."""

    var names: List[String]
    """Field names, parallel to `values`."""

    var values: List[String]
    """Field values, parallel to `names`.

    Two lists rather than a map because an error has a handful of fields and is
    on the cold path. A map would cost more to build at raise time than the
    scan costs at catch time, and raises happen whether or not anybody looks.
    """

    def __init__(out self, var message: String):
        """Start an error with a message and no fields.

        ```mojo
        from core.errors import Report

        def main():
            try:
                raise Report("nothing went right").error()
            except e:
                print(e)
        ```
        """
        self.message = message^
        self.code = 0
        self.count = 0
        self.names = List[String]()
        self.values = List[String]()

    def with_code(var self, code: Int) -> Self:
        """Tag this error so it can be recognised without a value to compare.

        ```mojo
        from core.errors import Report, code

        def main():
            try:
                raise Report("file does not exist").with_code(2).error()
            except e:
                print(code(e))
        ```
        """
        self.code = code
        return self^

    def with_count(var self, n: Int) -> Self:
        """Carry the count Go returns alongside an error and a raise would drop.

        ```mojo
        from core.errors import Report, partial

        def main():
            try:
                raise Report("short write").with_count(300).error()
            except e:
                print(partial(e))
        ```
        """
        self.count = n
        return self^

    def with_field(var self, var name: String, var value: String) -> Self:
        """Add one field. A repeated name is allowed and the first one wins.

        ```mojo
        from core.errors import Report, field

        def main():
            try:
                raise Report("open /nope").with_field("path", "/nope").error()
            except e:
                print(field(e, "path").or_else(""))
        ```
        """
        self.names.append(name^)
        self.values.append(value^)
        return self^

    def find(self, name: String) -> Optional[String]:
        """The value of one field, or nothing."""
        for i in range(self.names.__len__()):
            if self.names[i] == name:
                return Optional[String](self.values[i])
        return Optional[String]()

    def error(var self) -> Error:
        """Install the record on this thread and give back the error to raise.

        The record goes in before the error exists, which is the order that
        matters. An installed record that never gets raised is harmless,
        because nothing will ever carry its message. A raise that happens
        before its record is installed is a real error with no fields.

        ```mojo
        from core.errors import Report

        def main():
            try:
                raise Report("no").error()
            except e:
                print(e)
        ```
        """
        var message = self.message.copy()
        _install(self^)
        return Error(message^)


comptime _Held = Optional[Pointer[Report, _Any]]


def _slot() -> _Held:
    """This thread's record, if it has one.

    The address comes back as an integer rather than a pointer because a
    `Pointer` is non-nullable by design and an empty slot is exactly the null
    case. That is design.md section 6, and it is the shape every foreign call
    in this library that can return null has.
    """
    var address = external_call["core_errors_slot_get", Int]()
    if address == 0:
        return _Held()
    return _Held(Pointer[Report, _Any](unsafe_from_address=address))


def _install(var record: Report):
    """Put a record in this thread's slot, replacing whatever was there.

    The allocation is reused rather than freed and made again, so a thread that
    raises a million times allocates once. Assigning through the pointer
    destroys the old value, which is what releases the old message and fields.

    `malloc` rather than the standard library's allocator, because this block
    is handed to C and comes back through a pthread key destructor. One
    allocator on both sides of that boundary is the only version of this that
    can be reasoned about, and the `free` in the destructor below is the other
    half of it.
    """
    var existing = _slot()
    if existing:
        existing.value()[] = record^
        return

    var address = external_call["malloc", Int](size_of[Report]())
    if address == 0:
        # Out of memory while reporting an error. There is nothing useful to do
        # and nowhere to report it, so the record is dropped and the error
        # still carries its message. Fewer fields, never wrong ones.
        return
    Pointer[Report, _Any](unsafe_from_address=address).unsafe_write(record^)
    external_call["core_errors_slot_set", NoneType](address, _free)


def _free(raw: OpaquePointer[_Any]) abi("C"):
    """Release a record when its thread exits. Called by the C shim, never by us.

    Handed to the shim on every set rather than exported under a C name for it
    to find, because a function that only C calls is a function nothing in Mojo
    calls, and that is exactly what a dead code pass removes.

    This is the whole reason the slot is a pthread key rather than a
    `_Thread_local` pointer: a key has a destructor. The main thread is the
    exception, and that is pthread's rule rather than ours, since key
    destructors do not run for the thread that calls exit. One record outlives
    the process by a few microseconds.

    pthread only calls a destructor for a value that is not null, so there is
    no null case to handle here.
    """
    var record = raw.unsafe_bitcast[Report]()
    record.unsafe_deinit_pointee()
    external_call["free", NoneType](raw)


def _mine(e: Error) -> _Held:
    """This thread's record, but only if it belongs to this error.

    Everything public goes through here. See the module docstring for why the
    message is the identity and what that does and does not guarantee.
    """
    var held = _slot()
    if not held:
        return _Held()
    if held.value()[].message != String(e):
        return _Held()
    return held


def has_record(e: Error) -> Bool:
    """Whether this error still has its record on this thread.

    False for an error raised by anything that does not know about this
    mechanism, and false for one held past the next raise.

    ```mojo
    from core.errors import Report, has_record

    def main():
        try:
            raise Report("bad").error()
        except e:
            print(has_record(e))
    ```
    """
    return Bool(_mine(e))


def field(e: Error, name: String) -> Optional[String]:
    """One field of this error, or nothing when it has none by that name.

    ```mojo
    from core.errors import Report, field

    def main():
        try:
            raise Report("open /nope").with_field("path", "/nope").error()
        except e:
            print(field(e, "path").or_else(""))
    ```
    """
    var held = _mine(e)
    if not held:
        return Optional[String]()
    return held.value()[].find(name)


def code(e: Error) -> Int:
    """The code this error was tagged with, or zero when it has none.

    Zero means no code rather than a code of zero, which is why the registry
    that hands these out starts at one.

    ```mojo
    from core.errors import Report, code

    def main():
        try:
            raise Report("nope").with_code(2).error()
        except e:
            print(code(e))
    ```
    """
    var held = _mine(e)
    if not held:
        return 0
    return held.value()[].code


def partial(e: Error) -> Int:
    """The count Go would have returned alongside this error.

    Go's `(n, err)` says how much work happened before the failure and a raise
    drops the n. A short write that moved 300 of 512 bytes carries 300 here.

    ```mojo
    from core.errors import Report, partial

    def main():
        try:
            raise Report("short write").with_count(300).error()
        except e:
            print(partial(e))
    ```
    """
    var held = _mine(e)
    if not held:
        return 0
    return held.value()[].count
