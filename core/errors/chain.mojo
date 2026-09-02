"""Wrapping, sentinel matching and joining: the rest of Go's `errors` package.

Go builds a chain with `fmt.Errorf("reading config: %w", err)` and walks it
with `errors.Is` and `errors.As`. The chain is real here, in the record, and
these are the functions that build and walk it.

```mojo
from core.errors import ErrUnsupported, Report, matches, unwrap, wrap


def save() raises:
    try:
        raise Report("read only filesystem").with_code(ErrUnsupported).error()
    except e:
        raise wrap(e, "saving draft")


def main():
    try:
        save()
    except e:
        print(e)  # saving draft: read only filesystem
        print(matches(e, ErrUnsupported))  # True, found on the cause
        print(String(unwrap(e).value()))  # read only filesystem
```

`matches` walks the whole chain and everything each link joins, so it is the
one to use for a sentinel. `code`, `field` and `partial` in `record.mojo`
deliberately do not, because two links can each carry a `path` and answering
with the wrong one is worse than answering nothing.
"""

from .record import Code, Report, _at, _extract, _slot


def new(var message: String) -> Error:
    """An error with a message and nothing else. Go's `errors.New`.

    Identical to `Report(message).error()`, and here because a reader coming
    from Go looks for this name first.

    ```mojo
    from core.errors import new

    def main():
        try:
            raise new("no such host")
        except e:
            print(e)
    ```
    """
    return Report(message^).error()


def wrap(e: Error, var context: String) -> Error:
    """Wrap an error in context, keeping its fields and its own chain.

    The message becomes `context: cause`, which is the shape Go's `%w`
    convention produces. `Report(context).wrapping(e)` is the same thing when
    the wrapper also needs fields or a code of its own.

    ```mojo
    from core.errors import field, unwrap, wrap, Report

    def main():
        try:
            try:
                raise Report("no such file").with_field("path", "/a").error()
            except inner:
                raise wrap(inner, "loading")
        except e:
            print(e)                                  # loading: no such file
            print(field(unwrap(e).value(), "path").or_else(""))  # /a
    ```
    """
    return Report(context^).wrapping(e).error()


def join(*errs: Error) -> Error:
    """One error standing for several, all of them reachable. Go's `errors.Join`.

    The message is every cause separated by a newline, as Go's is. `causes`
    gives them back and `matches` searches all of them, so a joined error
    reports all of its causes rather than the first.

    Go holds error values and keeps every field. Only one of these errors can
    still own the thread's record, because a record is written at raise time
    and the next raise replaces it, so the others contribute their message and
    nothing more. `capture` is what closes that gap; the limitation is in
    docs/deviations.md.

    ```mojo
    from core.errors import causes, join, new

    def main():
        try:
            raise join(new("disk full"), new("no such host"))
        except e:
            print(causes(e).__len__())  # 2
    ```
    """
    var report = Report(String(""))
    for i in range(len(errs)):
        report = report^.absorbing(errs[i], String("\n"))
    return report^.error()


def matches(e: Error, code: Code) -> Bool:
    """Whether this error or anything it wraps carries this sentinel.

    Go's `errors.Is`, renamed because `is` is a Mojo keyword. The walk covers
    every cause of a joined error and not merely the first, which is the part
    of Go's contract that is easy to get wrong.

    `NO_CODE` matches nothing. An untagged error is not a kind of error, it is
    the absence of a kind, and letting it match would make every sentinel
    comparison against an untagged chain true.

    ```mojo
    from core.errors import ErrUnsupported, Report, matches

    def main():
        try:
            raise Report("read only").with_code(ErrUnsupported).error()
        except e:
            print(matches(e, ErrUnsupported))
    ```
    """
    if not code:
        return False
    var start = _at(e)
    if start < 0:
        return False

    ref record = _slot().value()[]
    var todo = List[Int]()
    todo.append(start)
    var seen = 0
    while seen < todo.__len__():
        ref link = record.links[todo[seen]]
        if link.code == code:
            return True
        for k in range(link.kids.__len__()):
            todo.append(link.kids[k])
        seen += 1
    return False


def unwrap(e: Error) -> Optional[Error]:
    """What this error wraps, or nothing.

    Go's `errors.Unwrap`, with Go's rule that a joined error does not unwrap:
    Go's `Unwrap() error` and `Unwrap() []error` are different methods and
    `Unwrap` only calls the first. `causes` is the other one.

    The error handed back still resolves against the record, so `field` and
    `code` on it answer about the inner error.

    ```mojo
    from core.errors import new, unwrap, wrap

    def main():
        try:
            raise wrap(new("no such file"), "loading")
        except e:
            print(String(unwrap(e).value()))
    ```
    """
    var found = causes(e)
    if found.__len__() != 1:
        return Optional[Error]()
    return Optional[Error](found[0])


def causes(e: Error) -> List[Error]:
    """Every error this one wraps or joins, in order. Empty when it wraps none.

    Go exposes this only as an `Unwrap() []error` method on a type it does not
    export, so there is nothing here to be at parity with. It is what makes a
    joined error's causes reachable rather than merely counted.

    ```mojo
    from core.errors import causes, join, new

    def main():
        try:
            raise join(new("disk full"), new("no such host"))
        except e:
            for c in causes(e):
                print(c)
    ```
    """
    var out = List[Error]()
    var index = _at(e)
    if index < 0:
        return out^

    ref record = _slot().value()[]
    for k in range(record.links[index].kids.__len__()):
        out.append(Error(record.links[record.links[index].kids[k]].message))
    return out^
