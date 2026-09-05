"""The four directories the environment names.

Every one of these is a variable lookup and a rule, so every test here sets the
variables it cares about, reads the answer into a value, puts the variables back
and only then asserts. That order is the point: an assertion that failed with
`HOME` still pointing at a made up path would change what every later test in
this process sees, and `HOME` is read by more of this library than it looks like
from here.

The two that differ by platform are asserted for both spellings, because the
answer on macOS is a `Library` path and the answer everywhere else is the XDG
one, and a test that only knew one of them would pass on one host and be
untested on the other.
"""

from std.sys import CompilationTarget
from std.testing import assert_equal, assert_false, assert_true

from core.errors import matches
from core.errors.codes import ErrInvalid
from core.os import (
    lookup_env,
    setenv,
    temp_dir,
    unsetenv,
    user_cache_dir,
    user_config_dir,
    user_home_dir,
)

comptime _MACOS = CompilationTarget.is_macos()
"""Whether the two `Library` paths are the answer rather than the XDG ones."""


struct _Held(Copyable, Movable):
    """One variable, remembered so it can be put back."""

    var name: String
    var was: Optional[String]

    def __init__(out self, name: String):
        self.name = name
        self.was = lookup_env(name)

    def put(self, value: String) raises:
        setenv(self.name, value)

    def clear(self) raises:
        unsetenv(self.name)

    def restore(self) raises:
        if self.was:
            setenv(self.name, self.was.value())
        else:
            unsetenv(self.name)


def test_temp_dir_uses_tmpdir_when_it_is_set() raises:
    var held = _Held("TMPDIR")
    held.put("/somewhere/else")
    var got = temp_dir()
    held.restore()
    assert_equal(got, "/somewhere/else")


def test_temp_dir_falls_back_to_tmp() raises:
    # The one of the four that guesses rather than failing, because `/tmp` is
    # in the standard and is on every host this builds for.
    var held = _Held("TMPDIR")
    held.clear()
    var got = temp_dir()
    held.restore()
    assert_equal(got, "/tmp")


def test_user_home_dir_is_home() raises:
    var held = _Held("HOME")
    held.put("/home/somebody")
    var got = String()
    try:
        got = user_home_dir()
    except e:
        got = String("failed: ", e)
    held.restore()
    assert_equal(got, "/home/somebody")


def test_user_home_dir_fails_when_home_is_not_set() raises:
    # Nothing here reads the password database, which is what a shell does
    # when `HOME` is missing. That is `os/user`'s job and Go does not do it in
    # this function either.
    var held = _Held("HOME")
    held.clear()
    var refused = False
    try:
        _ = user_home_dir()
    except e:
        refused = matches(e, ErrInvalid)
    held.restore()
    assert_true(refused)


def _cache_with(home: String, xdg: Optional[String]) raises -> String:
    """`user_cache_dir` with the two variables put where the caller asked.

    Everything is restored before this returns, including on the failing path,
    so a test that gets an unexpected answer does not leave the environment
    pointing somewhere invented.
    """
    var held_home = _Held("HOME")
    var held_xdg = _Held("XDG_CACHE_HOME")
    if home == "":
        held_home.clear()
    else:
        held_home.put(home)
    if xdg:
        held_xdg.put(xdg.value())
    else:
        held_xdg.clear()
    var got = String()
    try:
        got = user_cache_dir()
    except e:
        got = String("refused" if matches(e, ErrInvalid) else "failed")
    held_xdg.restore()
    held_home.restore()
    return got^


def _config_with(home: String, xdg: Optional[String]) raises -> String:
    """`user_config_dir`, the same way."""
    var held_home = _Held("HOME")
    var held_xdg = _Held("XDG_CONFIG_HOME")
    if home == "":
        held_home.clear()
    else:
        held_home.put(home)
    if xdg:
        held_xdg.put(xdg.value())
    else:
        held_xdg.clear()
    var got = String()
    try:
        got = user_config_dir()
    except e:
        got = String("refused" if matches(e, ErrInvalid) else "failed")
    held_xdg.restore()
    held_home.restore()
    return got^


def test_user_cache_dir_under_home() raises:
    var got = _cache_with("/home/somebody", None)
    comptime if _MACOS:
        assert_equal(got, "/home/somebody/Library/Caches")
    else:
        assert_equal(got, "/home/somebody/.cache")


def test_user_cache_dir_and_the_xdg_variable() raises:
    # macOS ignores the XDG variables, which is Go's behaviour and is what
    # makes a file written here land where a macOS user would look for it.
    var got = _cache_with("/home/somebody", Optional(String("/var/cache/mine")))
    comptime if _MACOS:
        assert_equal(got, "/home/somebody/Library/Caches")
    else:
        assert_equal(got, "/var/cache/mine")


def test_user_cache_dir_fails_when_nothing_is_set() raises:
    assert_equal(_cache_with("", None), "refused")


def test_a_relative_xdg_path_is_refused() raises:
    # The variable is documented as absolute. A relative one would put a cache
    # wherever the program happened to be started from, which is the failure
    # that only shows up the day somebody runs the program from elsewhere.
    var got = _cache_with("/home/somebody", Optional(String("relative/cache")))
    comptime if _MACOS:
        # Not read at all here, so the `HOME` answer comes back instead.
        assert_equal(got, "/home/somebody/Library/Caches")
    else:
        assert_equal(got, "refused")


def test_user_config_dir_under_home() raises:
    var got = _config_with("/home/somebody", None)
    comptime if _MACOS:
        assert_equal(got, "/home/somebody/Library/Application Support")
    else:
        assert_equal(got, "/home/somebody/.config")


def test_user_config_dir_and_the_xdg_variable() raises:
    var got = _config_with("/home/somebody", Optional(String("/etc/xdg/mine")))
    comptime if _MACOS:
        assert_equal(got, "/home/somebody/Library/Application Support")
    else:
        assert_equal(got, "/etc/xdg/mine")


def test_user_config_dir_fails_when_nothing_is_set() raises:
    assert_equal(_config_with("", None), "refused")


def test_the_cache_and_the_config_directory_are_not_the_same_place() raises:
    # A machine may throw the cache away and may not throw the configuration
    # away, so a library that gave the same answer for both would lose a user's
    # settings on the day the cache was cleaned.
    var cache = _cache_with("/home/somebody", None)
    var config = _config_with("/home/somebody", None)
    assert_true(cache != config)


def test_the_real_environment_still_answers() raises:
    # Every other test in this file invents an environment. This one asks the
    # question the way a program would, so a rule that only worked for made up
    # values would be caught here.
    assert_true(temp_dir().startswith("/"))
    if lookup_env("HOME"):
        assert_true(user_home_dir().startswith("/"))
        assert_true(user_cache_dir().startswith("/"))
        assert_true(user_config_dir().startswith("/"))
    else:
        assert_false(lookup_env("HOME"))
