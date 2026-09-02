# A fixture. This file is supposed to fail the linter, and `pixi run
# lint-selftest` fails if the linter accepts it. Nothing here is compiled or
# imported by anything.
#
# What is wrong with it: it reaches raw memory through methods on safe types, in
# a package whose PACKAGE.toml does not say `unsafe = true`.
#
# It is a second fixture rather than more lines in unsafe_in_safe_package.mojo
# because it has to be caught by the `unsafe_` family match and by nothing else.
# The older fixture names the raw types and the foreign call machinery outright,
# so it would still be rejected if the family match were deleted tomorrow, which
# means it cannot prove that match is alive. This one can, and that is its only
# job. Nothing in it, comment included, may use a name from the older list.
#
# The two methods below are the pair core.runtime.box is built out of: one hands
# back an address, the other forgets which region that address came from. Any
# package that can call them can hand a borrowed span to something that outlives
# it, which is the failure the unsafe flag exists to keep countable.


def borrow[
    o: Origin[mut=True]
](s: Span[UInt8, o]) -> Span[UInt8, AnyOrigin[mut=True]]:
    return Span[UInt8, AnyOrigin[mut=True]](
        unsafe_ptr=s.unsafe_ptr().as_unsafe_any_origin(), length=len(s)
    )


def first(s: Span[UInt8, AnyOrigin[mut=False]]) -> UInt8:
    return s.unsafe_get(0)
