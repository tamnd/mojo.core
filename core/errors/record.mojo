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

## The record is a tree

Wrapping and joining both produce a tree of errors, so a record is an arena: a
list of links, each with its own message, code, count and fields, plus the
indices of its children. The root is index zero. That is the same technique
design.md section 5 commits to for every recursive type in this library, and
`chain.mojo` is what builds the shapes.

A record with no wrapping is a single link, which is the common case and costs
one list of one element.

## Telling our errors from everybody else's

A link is matched to an error by the message it was raised with, and nothing
else. The lookup walks the record for a link whose message equals the caught
error's message, and finding none means no fields.

That is what makes the two failure modes safe. An error raised by `std`, or by
any library that has never heard of this mechanism, finds no link with its
message and is correctly reported as carrying no fields. An error held past the
next raise on the same thread finds a record built by somebody else, matches
nothing in it, and reports no fields rather than the newer error's.

The limit is worth stating: two errors with the same message text on the same
thread are indistinguishable here, and the newer record wins. Since the lookup
searches inner links too, that now includes an error whose text happens to
equal a link inside somebody else's chain. In practice the message is built
from the fields, so identical messages come from identical fields, but that is
a convention rather than something enforced. Holding an error for longer than
the next raise is what `capture` is for.
"""

from std.ffi import external_call
from std.sys import size_of

comptime _Any = AnyOrigin[mut=True]


struct Code(Copyable, Equatable, ImplicitlyCopyable, Movable, Writable):
    """A sentinel, in the only form this library can compare.

    Go's `errors.Is(err, io.EOF)` works because `io.EOF` is a value you can
    hold. There is no comparable error value here, so a sentinel is a number
    tagged onto the record and `matches` is a lookup.

    Nobody writes the number. `codes.toml` lists the sentinels and the
    generator assigns them, because two packages picking the same constant by
    hand makes `matches(e, io.EOF)` quietly true for an `os` error, and a wrong
    answer that never crashes is the category this repository generates rather
    than reviews.

    **A code is meaningless outside the process that produced it.** The numbers
    come from a position in a generated table and they move when a line is
    added above. Never write one to a file, a socket or a log and expect to
    read it back; write the message, or a name you chose yourself.

    A struct rather than a bare `Int` so that `with_code(2)` where
    `with_count(2)` was meant does not compile.
    """

    var value: Int
    """Zero means no code. The generator therefore starts numbering at one."""

    def __init__(out self, value: Int):
        """Wrap a number. Called by the generated table and by nothing else."""
        self.value = value

    def __eq__(self, other: Self) -> Bool:
        """Whether these are the same sentinel."""
        return self.value == other.value

    def __ne__(self, other: Self) -> Bool:
        """Whether these are different sentinels."""
        return self.value != other.value

    def __bool__(self) -> Bool:
        """Whether this is a code at all, as opposed to the absence of one."""
        return self.value != 0

    def write_to[W: Writer](self, mut writer: W):
        """The number, so that a failing assertion says which sentinel it was.

        There is no name to print. The names live in `codes.toml` and the
        generated constants, and carrying them into the binary would put a
        string table for every sentinel in the library into every program.
        """
        writer.write(self.value)


comptime NO_CODE = Code(0)
"""What `code` returns for an error that was never tagged."""


struct Link(Copyable, Movable):
    """One error in a record: its message, its fields, and what it wraps.

    Copyable because splicing a chain into a longer one copies links from the
    old record into the new. That happens once per wrap on the cold path, and
    the alternative is sharing, which means deciding who frees what across a
    pthread key destructor.
    """

    var message: String
    """The message the error was raised with. This is the identity check."""

    var code: Code
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

    var kids: List[Int]
    """Indices of the errors this one wraps, into the same record.

    Empty for a plain error, one for a wrap, several for a join. Indices rather
    than pointers because a struct cannot hold itself, which is design.md
    section 5.
    """

    def __init__(out self, var message: String):
        """A link with a message and nothing else."""
        self.message = message^
        self.code = NO_CODE
        self.count = 0
        self.names = List[String]()
        self.values = List[String]()
        self.kids = List[Int]()

    def find(self, name: String) -> Optional[String]:
        """The value of one field, or nothing. A repeated name keeps the first.
        """
        for i in range(self.names.__len__()):
            if self.names[i] == name:
                return Optional[String](self.values[i])
        return Optional[String]()


struct Report(Movable):
    """An error being built, and the record it leaves behind.

    One struct doing both jobs rather than a builder and a record, because
    Mojo will not move a struct valued field out of an owned `self`. Splitting
    them means `error()` has to move the record out of the report, and that is
    the exact operation the compiler refuses, either with "field destroyed out
    of the middle of a value" or with "cannot be consumed, because `self` is
    used later" depending on the order. `move_out_of_field.mojo` pins the rule.
    So the thing that is built is the thing that is stored, and `error()` moves
    the whole of `self` into the slot.

    Building is a chain so the fields read down the page in the order somebody
    would say them out loud, and so the common case of an error with no fields
    at all stays `Report(message).error()`.

    Nothing reads a `Report` back. The catch site uses the free functions
    below and in `chain.mojo`, which copy out of it, so no caller ends up
    holding a reference into storage the next raise is going to overwrite.
    """

    var links: List[Link]
    """The error at index zero, then everything it wraps or joins.

    A flat arena with integer indices rather than links holding links, because
    a struct cannot hold itself, which is design.md section 5. An error with no
    wrapping is one element, which is the common case.
    """

    def __init__(out self, var message: String):
        """Start an error with a message and no causes.

        ```mojo
        from core.errors import Report

        def main():
            try:
                raise Report("nothing went right").error()
            except e:
                print(e)
        ```
        """
        self.links = List[Link]()
        self.links.append(Link(message^))

    def with_code(var self, code: Code) -> Self:
        """Tag this error so it can be recognised without a value to compare.

        ```mojo
        from core.errors import Code, Report, code

        def main():
            try:
                raise Report("file does not exist").with_code(Code(2)).error()
            except e:
                print(code(e))
        ```
        """
        self.links[0].code = code
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
        self.links[0].count = n
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
        self.links[0].names.append(name^)
        self.links[0].values.append(value^)
        return self^

    def wrapping(var self, e: Error) -> Self:
        """Wrap an error, keeping its fields and its own chain.

        The message grows: `Report("reading config").wrapping(e)` raises
        `reading config: <e>`, which is the shape Go's `%w` convention produces
        and the shape every reader expects.

        ```mojo
        from core.errors import Report, field, unwrap

        def main():
            try:
                try:
                    raise Report("no such file").with_field("path", "/a").error()
                except inner:
                    raise Report("reading config").wrapping(inner).error()
            except e:
                print(e)
        ```
        """
        return self^.absorbing(e, String(": "))

    def absorbing(var self, e: Error, var separator: String) -> Self:
        """`wrapping` with the separator spelled out. `join` uses a newline.

        The cause is copied out of the thread\'s slot **now**, not at
        `error()`, because `error()` is what overwrites the slot. A cause with
        no record, which is any error this mechanism did not raise, contributes
        its message and nothing else, which is all anybody knows about it.

        Splicing happens here rather than at `error()` for the same reason the
        struct is shaped this way: assembling at the end means reading one
        field of an owned `self` after moving another out of it, and that does
        not compile.
        """
        var cause = _extract(e)

        # An empty message so far is `join`, which is Go\'s shape: the causes
        # and the separators between them, with nothing in front.
        if self.links[0].message:
            self.links[0].message += separator^
        self.links[0].message += cause.links[0].message

        # The cause\'s links were numbered from zero in their own record and
        # they stay contiguous here, so every index inside them shifts by the
        # same amount. That is the whole reason the arena is a flat list.
        var offset = self.links.__len__()
        self.links[0].kids.append(offset)
        for i in range(cause.links.__len__()):
            var moved = cause.links[i].copy()
            for k in range(moved.kids.__len__()):
                moved.kids[k] += offset
            self.links.append(moved^)
        return self^

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
        var message = self.links[0].message.copy()
        _install(self^)
        return Error(message^)

    def locate(self, message: String) -> Int:
        """The index of the link raised with this message, or -1.

        A linear scan rather than a walk from the root, because the arena holds
        exactly the links of one tree and nothing else.
        """
        for i in range(self.links.__len__()):
            if self.links[i].message == message:
                return i
        return -1


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
    destroys the old value, which is what releases the old messages and fields.

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


def _at(e: Error) -> Int:
    """Where this error sits in this thread's record, or -1 if it does not.

    Everything public goes through here. See the module docstring for why the
    message is the identity and what that does and does not guarantee.
    """
    var held = _slot()
    if not held:
        return -1
    return held.value()[].locate(String(e))


def _extract(e: Error) -> Report:
    """A standalone record for this error and everything below it.

    Used by `wrapping` and `join` to take a cause out of the slot before the
    slot is overwritten. An error with nothing in the slot yields a record of
    one link holding its message, which is exactly what is known about an error
    somebody else raised.
    """
    var out = Report(String(e))
    var held = _slot()
    var index = -1
    if held:
        index = held.value()[].locate(String(e))
    if index < 0:
        return out^

    # Copy the subtree rooted at `index`, renumbering as it goes. `old` holds
    # the source index of each link already copied, so `old[i]` and
    # `out.links[i]` stay in step and a link is copied before anything asks
    # where its children went.
    ref source = held.value()[]
    out.links[0] = source.links[index].copy()
    out.links[0].kids = List[Int]()
    var old = List[Int]()
    old.append(index)
    var seen = 0
    while seen < old.__len__():
        var here = old[seen]
        for k in range(source.links[here].kids.__len__()):
            var kid = source.links[here].kids[k]
            var copied = source.links[kid].copy()
            copied.kids = List[Int]()
            out.links.append(copied^)
            out.links[seen].kids.append(out.links.__len__() - 1)
            old.append(kid)
        seen += 1
    return out^


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
    return _at(e) >= 0


def field(e: Error, name: String) -> Optional[String]:
    """One field of this error, or nothing when it has none by that name.

    Only this error's own fields. An error that wraps another does not inherit
    the inner one's fields, because two links in a chain can each have a `path`
    and silently answering with the wrong one is worse than answering nothing.
    Reach the inner one with `unwrap`.

    ```mojo
    from core.errors import Report, field

    def main():
        try:
            raise Report("open /nope").with_field("path", "/nope").error()
        except e:
            print(field(e, "path").or_else(""))
    ```
    """
    var index = _at(e)
    if index < 0:
        return Optional[String]()
    return _slot().value()[].links[index].find(name)


def code(e: Error) -> Code:
    """The code this error was tagged with, or `NO_CODE`.

    This error's own code and not its causes'. `matches` is what walks the
    chain, and it is what a sentinel comparison should use.

    ```mojo
    from core.errors import Code, Report, code

    def main():
        try:
            raise Report("nope").with_code(Code(2)).error()
        except e:
            print(code(e).value)
    ```
    """
    var index = _at(e)
    if index < 0:
        return NO_CODE
    return _slot().value()[].links[index].code


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
    var index = _at(e)
    if index < 0:
        return 0
    return _slot().value()[].links[index].count
