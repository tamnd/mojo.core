# PINS: Smaller facts that change how code is written
# EXPECT: rejected
# ERROR: is not a child trait of
# WHY: A where clause narrows an associated type where the type stands alone,
# WHY: and not where it has to be inferred through another type. `sorted` in
# WHY: core.slices takes a Cursor whose Element is only Deinitable & Movable,
# WHY: narrows it to Copyable, and still cannot pass Span(list) to a sort that
# WHY: infers its element type. The workaround there is a helper whose type
# WHY: parameter is bound explicitly instead of inferred, and when this file
# WHY: compiles that helper can go.


trait Cursor:
    comptime Element: Deinitable & Movable

    def has_next(mut self) raises -> Bool:
        ...

    def next(mut self) raises -> Self.Element:
        ...


# The element type is inferred from the argument, which is the ordinary way to
# write this and the way `core.slices.sort` is written.
def sort_it[T: Copyable & Deinitable, o: MutOrigin, //](s: Span[T, o]):
    pass


def collect[C: Cursor, //](mut c: C) raises -> List[C.Element]:
    var out = List[C.Element]()
    while c.has_next():
        out.append(c.next())
    return out^


def sorted[
    C: Cursor, //
](mut c: C) raises -> List[C.Element] where conforms_to(C.Element, Copyable):
    var out = collect(c)
    # The where clause above says C.Element is Copyable. Passing one to a
    # function that takes a bare `T: Copyable` is accepted; inferring `T` from
    # `Span[C.Element, ...]` is not, and this is the line that fails.
    sort_it(Span(out))
    return out^


def main():
    print("unreachable")
