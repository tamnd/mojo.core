# A fixture. This file is supposed to fail the linter, and `pixi run
# lint-selftest` fails if the linter accepts it. Nothing here is compiled or
# imported by anything.
#
# What is wrong with it: raw pointers, foreign calls and reinterpretation are
# named in a package whose PACKAGE.toml does not say `unsafe = true`. Fifteen
# packages declare it and the rest may not, so that the number of places memory
# safety rests on a person being careful is a number somebody can read off the
# linter's output rather than a thing nobody tracks.


def read_at[
    o: Origin[mut=False]
](base: Pointer[UInt8, o], offset: Int) -> UInt8:
    return base.offset(offset)[]


def reinterpret[o: Origin[mut=False]](base: Pointer[UInt8, o]) -> Int:
    return base.unsafe_bitcast[Int]()[]


def now() -> Int:
    return external_call["time", Int](0)
