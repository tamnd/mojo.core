"""The environment as `core.os` presents it.

`core.syscall` already has tests for the three libc calls underneath these, and
the suite there asserts that the array and `getenv` agree. What is asserted here
is the part `core.os` adds, which is Go's two answers to one question, the shape
of a refusal, and `expand`.

The variable names have the process id in them so that two suites on one machine
do not land on each other, and every test that sets one takes it away again. The
environment is process wide and a variable left behind changes what a later test
sees.
"""

from std.testing import assert_equal, assert_false, assert_true

from core.errors import matches
from core.errors.codes import ErrInvalid
from core.os import (
    SyscallError,
    clearenv,
    environ,
    expand,
    expand_env,
    getenv,
    lookup_env,
    setenv,
    unsetenv,
)
from core.syscall import EINVAL, getpid


def _name(suffix: String) -> String:
    return String("MOJO_CORE_OS_", getpid(), "_", suffix)


def test_getenv_of_a_name_that_is_not_set_is_empty() raises:
    assert_equal(getenv(_name("absent")), "")


def test_getenv_and_lookup_env_agree_on_a_value() raises:
    var name = _name("roundtrip")
    setenv(name, "a value")
    assert_equal(getenv(name), "a value")
    assert_equal(lookup_env(name).value(), "a value")
    unsetenv(name)


def test_lookup_env_tells_empty_apart_from_absent() raises:
    # The whole reason both functions exist. `getenv` gives the same answer for
    # these two states and `lookup_env` does not.
    var name = _name("emptyvalue")
    setenv(name, "")
    assert_equal(getenv(name), "")
    var set = lookup_env(name)
    assert_true(set)
    assert_equal(set.value(), "")

    unsetenv(name)
    assert_equal(getenv(name), "")
    assert_false(lookup_env(name))


def test_setenv_replaces_what_was_there() raises:
    var name = _name("overwrite")
    setenv(name, "first")
    setenv(name, "second")
    assert_equal(getenv(name), "second")
    unsetenv(name)


def test_setenv_refuses_a_name_with_a_zero_byte_in_it() raises:
    # The refusal never reaches libc, so it carries no errno, the same
    # arrangement the path calls use for a name with a zero byte in it.
    try:
        setenv(String("MOJO\0CORE"), "x")
        raise Error("a name with a zero byte in it should have been refused")
    except e:
        assert_true(matches(e, ErrInvalid))


def test_setenv_refuses_a_value_with_a_zero_byte_in_it() raises:
    var name = _name("nulvalue")
    try:
        setenv(name, String("a\0b"))
        raise Error("a value with a zero byte in it should have been refused")
    except e:
        assert_true(matches(e, ErrInvalid))
    assert_false(lookup_env(name))


def test_setenv_refuses_an_empty_name() raises:
    # This one does reach libc, which answers `EINVAL`, so it comes back as a
    # `SyscallError` rather than as the refusal made here. It does not match
    # `ErrInvalid`: that sentinel is for a call this library would not make,
    # and Go's own errno mapping does not turn `EINVAL` into it either.
    try:
        setenv("", "x")
        raise Error("an empty name should have been refused")
    except e:
        var reported = SyscallError.of(e)
        assert_true(reported)
        assert_equal(reported.value().syscall, "setenv")
        assert_equal(reported.value().err.value, EINVAL)


def test_setenv_refuses_a_name_with_an_equals_sign_in_it() raises:
    # The `=` is the separator in the array, so a name holding one would make
    # an entry nothing could read back. libc refuses it and this reports what
    # libc said.
    try:
        setenv(_name("has=equals"), "x")
        raise Error("a name with an equals sign should have been refused")
    except e:
        assert_equal(SyscallError.of(e).value().err.value, EINVAL)


def test_unsetting_something_that_is_not_set_is_not_a_failure() raises:
    unsetenv(_name("neverset"))


def test_environ_sees_a_variable_this_test_set() raises:
    var name = _name("visible")
    setenv(name, "here")
    var wanted = String(name, "=here")
    var found = False
    for entry in environ():
        if entry == wanted:
            found = True
    assert_true(found)
    unsetenv(name)


def _braced(s: String) raises -> String:
    """`expand` with a mapping that shows what name it was handed.

    The mapping is a nested `@parameter def` because `expand` takes it as a
    compile time parameter spelled `capturing [_]`, which is what lets a caller
    capture; a function declared at the top of a file is not one of those. Both
    of these are here rather than in each test so that the tests read as
    assertions about the rules rather than about Mojo.
    """

    @parameter
    def braced(name: String) -> String:
        return String("<", name, ">")

    return expand[braced](s)


def _blanked(s: String) raises -> String:
    """`expand` with a mapping that replaces every name with nothing."""

    @parameter
    def empty(name: String) -> String:
        return String()

    return expand[empty](s)


def test_expand_replaces_both_spellings() raises:
    assert_equal(_braced("$one and ${two}"), "<one> and <two>")


def test_expand_leaves_a_string_with_no_dollar_alone() raises:
    assert_equal(_braced("nothing to do here"), "nothing to do here")


def test_a_dollar_at_the_end_stays() raises:
    # There is no name after it, so there is nothing to replace and Go keeps
    # the character rather than dropping it.
    assert_equal(_braced("costs 5$"), "costs 5$")


def test_a_dollar_before_something_that_cannot_start_a_name_stays() raises:
    assert_equal(_braced("$ $, $."), "$ $, $.")


def test_a_name_stops_at_the_first_byte_that_is_not_one() raises:
    assert_equal(_braced("$one.two"), "<one>.two")
    assert_equal(_braced("$one/two"), "<one>/two")
    assert_equal(_braced("${one}two"), "<one>two")


def test_an_underscore_and_digits_are_part_of_a_name() raises:
    assert_equal(_braced("$a_1b"), "<a_1b>")


def test_an_unclosed_brace_eats_the_brace_and_keeps_the_rest() raises:
    # Go's rule, and it is odd enough to be worth a test of its own: the `${`
    # goes and everything after it is ordinary text.
    assert_equal(_braced("${one"), "one")


def test_empty_braces_disappear() raises:
    assert_equal(_braced("a${}b"), "ab")


def test_a_shell_special_name_is_one_byte_long() raises:
    # `$1x` is the name `1` followed by an `x`, not the name `1x`, which is
    # what a shell does with its positional arguments.
    assert_equal(_braced("$1x"), "<1>x")
    assert_equal(_braced("$$"), "<$>")
    assert_equal(_braced("${*}"), "<*>")


def test_two_dollars_in_a_row_before_a_name() raises:
    assert_equal(_braced("$$one"), "<$>one")


def test_expand_with_a_mapping_that_returns_nothing() raises:
    assert_equal(_blanked("$one and ${two} and $3"), " and  and ")


def test_expand_env_uses_the_environment() raises:
    var name = _name("expanded")
    setenv(name, "world")
    assert_equal(expand_env(String("hello, $", name)), "hello, world")
    assert_equal(expand_env(String("hello, ${", name, "}!")), "hello, world!")
    unsetenv(name)


def test_expand_env_of_a_name_that_is_not_set_is_nothing() raises:
    # A shell does the same and it is why this is the wrong tool for a
    # template: a typo in a name is silent.
    var name = _name("nevertheretoo")
    assert_equal(expand_env(String("[$", name, "]")), "[]")


def test_clearenv_and_putting_it_back() raises:
    # Destructive, so everything is read first and restored in a `finally`.
    var saved = environ()
    try:
        clearenv()
        assert_equal(len(environ()), 0)
        assert_equal(getenv("PATH"), "")
        assert_false(lookup_env("PATH"))
    finally:
        clearenv()
        for entry in saved:
            var cut = entry.find("=")
            if cut > 0:
                setenv(
                    String(entry[byte=0:cut]), String(entry[byte = cut + 1 :])
                )
    assert_true(lookup_env("PATH"))
    assert_equal(len(environ()), len(saved))
