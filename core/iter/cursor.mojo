"""`Cursor`, the shape every fallible iterator in this library has.

A Mojo `for` loop silently drops an error raised out of `__next__`. Not
reports it late, not turns it into a different error: drops it, and the loop
ends looking exactly like a clean end of input. A csv reader that hits a
malformed row halfway through a file therefore returns the rows before it and
the program carries on believing it read the whole thing.
`tools/probe/probes/for_swallows_raise.mojo` pins that behaviour so that a
Mojo release which fixes it makes a test fail and this whole rule gets
revisited.

So nothing fallible here gets an `__iter__`. It gets this instead, and the
loop is written out:

```mojo
from core.iter import Cursor


def count[C: Cursor](mut cursor: C) raises -> Int:
    var seen = 0
    while cursor.has_next():
        _ = cursor.next()
        seen += 1
    return seen
```

That is three lines longer than a `for` and it is the entire point: the
failure comes out of the `while` or out of the `next` and lands on whoever
called this, because there is nowhere for it to go quietly. The linter
enforces the rule, `docs/testing.md` says how, and a convention defended only
by memory is not defended.

## Not called `Iterator`

The hazard this exists to prevent is a reader assuming `for x in it` works.
A trait called `Iterator` invites that assumption at every use site, so this
one is not called that. A cursor is a position in a sequence you advance by
hand, which is what this is, and it reads correctly for everything that is
going to implement it: csv records, bufio lines, sql rows, directory walks,
zip entries.

Infallible iteration keeps Mojo's own `__iter__` and `__next__`, which are
safe for exactly the reason this is not: nothing in them can fail. A `List`
iterator is not a `Cursor` and should not be made into one.
"""


trait Cursor:
    """A sequence advanced by hand, because advancing it can fail.

    Both methods may raise and the implementation chooses which one does the
    work. A csv reader cannot know whether there is another record without
    parsing one, so the failure has to be allowed on either side; a reader
    sitting on a buffer answers `has_next` cheaply and fails in `next`.

    Three rules make misuse loud rather than quiet, and an implementation that
    breaks them is a bug even though nothing can check it:

    - `has_next` returning `False` is a clean end of input, and it keeps
      returning `False` once it has.
    - `next` raises when there is nothing to hand over. It does not return a
      zero value, because this library has none.
    - A failure comes out of whichever call found it. There is no `Err()` to
      check afterwards, which is the flaw in Go's `bufio.Scanner`: the loop
      reads correctly, ends early, and the check that would have caught it is
      somewhere else and easy to leave out.

    ```mojo
    from core.iter import Cursor


    struct Countdown(Cursor):
        comptime Element = Int

        var left: Int

        def __init__(out self, from_: Int):
            self.left = from_

        def has_next(mut self) raises -> Bool:
            return self.left > 0

        def next(mut self) raises -> Int:
            if self.left == 0:
                raise Error("countdown: past the end")
            self.left -= 1
            return self.left
    ```
    """

    comptime Element: Deinitable & Movable
    """What one step hands back.

    An associated type rather than a parameter on the trait, because
    `trait Cursor[T]` does not compile: trait declarations do not support
    parameters. A generic function reads it off the bound as `C.Element`, so
    `List[C.Element]` works and nothing has to be spelled twice.

    `Deinitable & Movable` is the least a caller needs to own what it is handed
    and let it go again. Requiring `Copyable` would have ruled out a cursor
    yielding a buffer, a file or anything else that is deliberately not
    copyable, and those are most of the interesting ones.
    """

    def has_next(mut self) raises -> Bool:
        """Whether another element is available.

        `mut self`, because answering this honestly can mean reading ahead,
        and a cursor that had to lie about being unchanged would have to hide
        the lookahead somewhere worse.
        """
        ...

    def next(mut self) raises -> Self.Element:
        """The next element, moved out of the cursor.

        Raises if there is not one. Calling this without `has_next` is not
        forbidden, and for a cursor whose end is a failure anyway it is the
        natural way to write the loop.
        """
        ...
