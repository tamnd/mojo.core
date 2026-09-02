# PINS: Smaller facts that change how code is written
# EXPECT: rejected
# ERROR: is not subscriptable
# WHY: A `where` clause can say an associated type is a `Tuple[K, V]` and the
# WHY: compiler will not take it apart again. `C.Element` stays opaque inside
# WHY: the body: subscripting it is an error, and so is anything else that
# WHY: needs to know it is a tuple. The clause is not ignored — it is checked
# WHY: at the call site — it just does not narrow the type for the body.
# WHY:
# WHY: This is what decides the shape of `core.maps.insert` and
# WHY: `core.maps.collect`. Go's take an `iter.Seq2[K, V]`, and the natural
# WHY: translation is a `core.iter.Cursor` yielding pairs, which is what
# WHY: `core.slices.collect` does for single values. It cannot be written,
# WHY: because a dict needs the key and the value separately and there is no
# WHY: way to get them out of `C.Element`. So both take a `Span[Tuple[K, V]]`
# WHY: instead and a fallible source is drained with `slices.collect` first.
# WHY:
# WHY: If this ever compiles, those two get a `Cursor` overload and the row in
# WHY: deviations.md goes. It is a near relation of
# WHY: `refined_associated_type.mojo`, which pins the inference half of the
# WHY: same limitation, and both should be looked at together.


trait Cursor:
    """`core.iter.Cursor`, cut down to the part this is about.

    Written out rather than imported because a probe is built on its own, with
    no include path, so that what it pins is a fact about the language and not
    about this library.
    """

    comptime Element: Deinitable & Movable

    def has_next(mut self) raises -> Bool:
        ...

    def next(mut self) raises -> Self.Element:
        ...


def collect_pairs[
    K: KeyElement & Copyable & Deinitable,
    V: Copyable & Deinitable,
    C: Cursor, //,
](mut c: C) raises -> Dict[K, V] where C.Element == Tuple[K, V]:
    var out = Dict[K, V]()
    while c.has_next():
        var pair = c.next()
        out[pair[0].copy()] = pair[1].copy()
    return out^


def main():
    print("unreachable, this probe is not supposed to compile")
