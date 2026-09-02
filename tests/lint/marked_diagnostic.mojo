# A fixture. This file is supposed to fail the linter, and `pixi run
# lint-selftest` fails if the linter accepts it. Nothing here is compiled or
# imported by anything.
#
# What is wrong with it: it produces a compile time diagnostic carrying this
# library's marker prefix, and inside this repository that is a build failure
# rather than a warning. Mojo cannot turn a compile time fact into an error, so
# every compile time check here is a deprecation warning with the prefix on it,
# and the linter is the thing that promotes it. See section 10 of
# docs/design.md.


@deprecated("core: buffer size must be a power of two")
def bad_size():
    pass


def is_power_of_two(n: Int) -> Bool:
    return n > 0 and (n & (n - 1)) == 0


def ring[n: Int]() -> Int:
    comptime if not is_power_of_two(n):
        bad_size()
    return n


def use() -> Int:
    return ring[6]()
