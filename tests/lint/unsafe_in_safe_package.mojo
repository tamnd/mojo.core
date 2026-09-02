# A fixture. This file is supposed to fail the linter, and `pixi run
# lint-selftest` fails if the linter accepts it. Nothing here is compiled or
# imported by anything.
#
# What is wrong with it: foreign calls, reinterpretation, pointer arithmetic and
# building a pointer out of an integer are named in a package whose PACKAGE.toml
# does not say `unsafe = true`. Seventeen packages declare it and the rest may
# not, so that the number of places memory safety rests on a person being
# careful is a number somebody can read off the linter's output rather than a
# thing nobody tracks.
#
# Holding a `Pointer` is not on the list and deliberately is not: in Mojo 1.0 it
# is the origin tracked reference type and `UnsafePointer` is an alias for it.
# What is on the list is every operation that turns one into something the
# borrow checker is no longer standing behind, and all four below are those.


def read_at[
    o: Origin[mut=False]
](base: Pointer[UInt8, o], offset: Int) -> UInt8:
    return base.unsafe_offset(offset)[]


def reinterpret[o: Origin[mut=False]](base: Pointer[UInt8, o]) -> Int:
    return base.unsafe_bitcast[Int]()[]


def out_of_thin_air(address: Int) -> Pointer[UInt8, MutAnyOrigin]:
    return Pointer(unsafe_from_address=address)


def now() -> Int:
    return external_call["time", Int](0)
