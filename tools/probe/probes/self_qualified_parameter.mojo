# PINS: Smaller facts that change how code is written
# EXPECT: rejected
# ERROR: unqualified access to struct parameter
# WHY: A struct that wraps another type keeps it in a field, and the obvious
# WHY: spelling of that field's type is the parameter's own name. Mojo refuses
# WHY: it and asks for `Self.R`, which is not a style preference: the same name
# WHY: is legal everywhere else in the file, including in the return type of a
# WHY: free function alongside it, so nothing about the code around a field
# WHY: declaration suggests the rule exists. `core.io`'s `LimitedReader`,
# WHY: `SectionReader` and `OffsetWriter` all hit it, and so will every
# WHY: wrapper written after them. If Mojo ever allows the short spelling this
# WHY: probe starts running and the `Self.` prefixes can come off.

trait Source:
    def get(self) -> Int:
        ...


struct Wrapper[S: Source & Copyable](Copyable, Movable):
    # `var inner: Self.S` compiles. This does not, and the two are the same
    # name in the same struct three lines apart.
    var inner: S

    def __init__(out self, inner: S):
        self.inner = inner

    def get(self) -> Int:
        return self.inner.get()


def main():
    print("unreached")
