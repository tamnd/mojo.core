"""An error that owns its record, so it can outlive the raise that made it.

Go's errors are values. They live as long as whoever holds them, go in a slice,
go in a struct field, and travel down a channel to another goroutine. Ours live
in a slot that the next raise on that thread overwrites, which is the price of
carrying fields on an error type that is only a string.

`capture` is how to stop paying it. It copies the error's whole subtree out of
the thread and hands back an `ErrorValue` that owns every message, field and
cause it can reach.

```mojo
from core.errors import Report, capture


def main():
    var failures = List[ErrorValue]()
    for name in ["a", "b"]:
        try:
            raise Report("cannot open " + name).with_field("path", name).error()
        except e:
            failures.append(capture(e))
    # Both are still complete here, though each raise replaced the other's
    # record. Without the capture the first one would have nothing left.
    for f in failures:
        print(f.message(), f.field("path").or_else(""))
```

An `ErrorValue` reads without touching the thread's slot at all, which is what
makes it safe to send somewhere else. `error()` is the other direction: it
installs the record on whatever thread calls it and gives back an `Error` to
raise, so a task's failure can be re-raised by the thread that collected it and
every function in this package works on it as if it had just happened.
"""

from .record import Code, Link, Report, _extract


struct ErrorValue(Copyable, Movable):
    """An error and everything reachable from it, owned outright.

    Copyable, because the point of it is to be stored, and a value that cannot
    be put in a list twice is not much of a value. The copy is deep: the arena
    is a flat list of links with integer indices, so copying the list copies
    the whole tree and nothing is shared with the original or with any thread.

    Not implicitly copyable, so `unwrap().value().copy()` says out loud that a
    subtree is being duplicated. `Optional.value()` hands back a reference, and
    the reference is into a temporary, so the copy is real and worth seeing.

    The reading methods here are deliberately duplicates of the free functions
    in `record.mojo` and `chain.mojo` rather than wrappers around them. Those
    ask the thread's slot; these ask the value. Routing an `ErrorValue` through
    the slot to read it would reintroduce the exact lifetime problem it exists
    to remove.
    """

    var record: Report
    """The arena, with this error at index zero.

    A `Report` because that is the record type. It is the builder as well,
    which is a single struct doing two jobs for the reason its own docstring
    gives, and this is the third.
    """

    def __init__(out self, var record: Report):
        """Take ownership of a record. `capture` is the way to get one."""
        self.record = record^

    def message(self) -> String:
        """The message this error was raised with."""
        return self.record.links[0].message.copy()

    def field(self, name: String) -> Optional[String]:
        """One of this error's own fields, or nothing.

        Its own, not its causes'. Same rule as `errors.field`, for the same
        reason: two links in a chain can each carry a `path`.
        """
        return self.record.links[0].find(name)

    def code(self) -> Code:
        """The code this error was tagged with, or `NO_CODE`."""
        return self.record.links[0].code

    def partial(self) -> Int:
        """The count Go would have returned alongside this error."""
        return self.record.links[0].count

    def matches(self, code: Code) -> Bool:
        """Whether this error or anything it wraps carries this sentinel.

        ```mojo
        from core.errors import ErrUnsupported, Report, capture

        def main():
            try:
                raise Report("read only").with_code(ErrUnsupported).error()
            except e:
                print(capture(e).matches(ErrUnsupported))
        ```
        """
        if not code:
            return False
        return self.record.carries(0, code)

    def causes(self) -> List[Self]:
        """Every error this one wraps or joins, each owning its own subtree.

        Each one is a fresh copy rather than a view, so a cause outlives the
        value it came from and can be sent somewhere else on its own.
        """
        var out = List[Self]()
        for k in range(self.record.links[0].kids.__len__()):
            out.append(Self(self.record.subtree(self.record.links[0].kids[k])))
        return out^

    def unwrap(self) -> Optional[Self]:
        """What this error wraps, or nothing. A joined error unwraps to nothing.

        Go's rule, where `Unwrap() error` and `Unwrap() []error` are different
        methods and `errors.Unwrap` only calls the first. `causes` is the other.
        """
        var found = self.causes()
        if found.__len__() != 1:
            return Optional[Self]()
        return Optional[Self](found[0].copy())

    def error(self) -> Error:
        """Install this record on **this** thread and give back the error.

        The other direction across a thread boundary. A task that failed can
        have its error captured on the thread that ran it and re-raised by the
        thread that collected it, and every function in this package then works
        on it as though it had just been raised here.

        Borrowed rather than consuming, because re-raising the same captured
        error twice is an ordinary thing to want and a value that a re-raise
        destroys would be a trap.

        ```mojo
        from core.errors import Report, capture, field

        def main():
            var held = ErrorValue(Report("x"))
            try:
                raise Report("no such file").with_field("path", "/a").error()
            except e:
                held = capture(e)
            try:
                raise held.error()
            except again:
                print(field(again, "path").or_else(""))
        ```
        """
        var mine = self.record.copy()
        return mine^.error()


def capture(e: Error) -> ErrorValue:
    """Take an error out of the thread, with its fields and its whole chain.

    The copy happens now, so the next raise on this thread cannot reach it.
    An error this mechanism did not raise captures as its message and nothing
    else, which is all anybody knows about it.

    ```mojo
    from core.errors import Report, capture

    def main():
        try:
            raise Report("disk full").with_field("device", "sda1").error()
        except e:
            var kept = capture(e)
            print(kept.field("device").or_else(""))
    ```
    """
    return ErrorValue(_extract(e))
