# A fixture. This file is supposed to fail the linter, and `pixi run
# lint-selftest` fails if the linter accepts it. Nothing here is compiled or
# imported by anything.
#
# What is wrong with it: a `must_` function aborts on bad input, and a Mojo
# program cannot catch an abort. On a literal that is a constant the programmer
# has asserted and the abort can never fire. On a variable it is a crash
# waiting for the right input, and there is a fallible sibling that returns an
# error instead. See docs/deviations.md for the eleven `must_` functions.


fn compile_pattern(pattern: String) -> Regexp:
    return must_compile(pattern)


fn known_good() -> Regexp:
    # This one is fine, and the linter has to keep accepting it, otherwise the
    # rule is just a ban on the whole family.
    return must_compile("^[a-z]+$")
