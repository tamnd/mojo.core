"""Wrapping, sentinel matching and joining.

The cases that matter are the ones where the answer is plausible and wrong: a
sentinel found on the wrong link, a joined error reporting only its first
cause, and a chain that loses the fields of everything but its outer layer.
"""

from std.testing import assert_equal, assert_false, assert_true

from core.errors import (
    Code,
    ErrUnsupported,
    Report,
    causes,
    field,
    join,
    matches,
    new,
    unwrap,
    wrap,
)


def test_new_is_a_plain_error() raises:
    try:
        raise new("no such host")
    except e:
        assert_equal(String(e), "no such host")
        assert_equal(causes(e).__len__(), 0)


def test_wrap_reads_the_way_gos_does() raises:
    try:
        try:
            raise new("no such file")
        except inner:
            raise wrap(inner, "loading config")
    except e:
        assert_equal(String(e), "loading config: no such file")


def test_four_levels_of_wrapping() raises:
    try:
        try:
            try:
                try:
                    raise new("connection refused")
                except a:
                    raise wrap(a, "dialling")
            except b:
                raise wrap(b, "querying")
        except c:
            raise wrap(c, "loading user")
    except e:
        assert_equal(
            String(e), "loading user: querying: dialling: connection refused"
        )

        var one = unwrap(e).value()
        assert_equal(String(one), "querying: dialling: connection refused")
        var two = unwrap(one).value()
        assert_equal(String(two), "dialling: connection refused")
        var three = unwrap(two).value()
        assert_equal(String(three), "connection refused")
        assert_false(Bool(unwrap(three)))


def test_a_chain_keeps_every_levels_fields() raises:
    try:
        try:
            raise Report("no such file").with_field("path", "/etc/x").error()
        except inner:
            raise Report("loading").wrapping(inner).with_field(
                "user", "tam"
            ).error()
    except e:
        assert_equal(field(e, "user").or_else(""), "tam")
        # The outer error does not inherit the inner one's field, because two
        # links can each have a `path` and the wrong answer is worse than none.
        assert_false(Bool(field(e, "path")))
        assert_equal(field(unwrap(e).value(), "path").or_else(""), "/etc/x")


def test_matches_finds_a_sentinel_on_a_cause() raises:
    try:
        try:
            raise Report("read only").with_code(ErrUnsupported).error()
        except inner:
            raise wrap(inner, "saving")
    except e:
        assert_true(matches(e, ErrUnsupported))


def test_matches_is_false_for_another_sentinel() raises:
    try:
        raise Report("read only").with_code(ErrUnsupported).error()
    except e:
        assert_false(matches(e, Code(9999)))


def test_an_untagged_error_matches_nothing() raises:
    try:
        raise new("plain")
    except e:
        assert_false(matches(e, ErrUnsupported))


def test_a_foreign_error_matches_nothing() raises:
    # A record exists on this thread, and this error is not the one that wrote
    # it. Matching against the record anyway is the silent failure this guards.
    try:
        raise Report("ours").with_code(ErrUnsupported).error()
    except _:
        assert_false(matches(Error("theirs"), ErrUnsupported))


def test_join_reports_every_cause() raises:
    var first = new("disk full")
    var second = new("no such host")
    try:
        raise join(first, second)
    except e:
        var found = causes(e)
        assert_equal(found.__len__(), 2)
        assert_equal(String(found[0]), "disk full")
        assert_equal(String(found[1]), "no such host")


def test_join_message_is_newline_separated() raises:
    try:
        raise join(new("disk full"), new("no such host"))
    except e:
        assert_equal(String(e), "disk full\nno such host")


def test_matches_searches_past_the_first_cause() raises:
    # `second` is created last, so it is the one that still owns the thread's
    # record, and it is deliberately not the first cause. A `matches` that
    # stopped at the first cause would say False here.
    var first = new("disk full")
    var second = Report("read only").with_code(ErrUnsupported).error()
    try:
        raise join(first, second)
    except e:
        assert_true(matches(e, ErrUnsupported))


def test_unwrap_of_a_join_is_nothing() raises:
    # Go's `Unwrap() error` and `Unwrap() []error` are different methods and
    # `errors.Unwrap` only calls the first. `causes` is the other one.
    try:
        raise join(new("a"), new("b"))
    except e:
        assert_false(Bool(unwrap(e)))
        assert_equal(causes(e).__len__(), 2)


def test_unwrap_of_a_plain_error_is_nothing() raises:
    try:
        raise new("alone")
    except e:
        assert_false(Bool(unwrap(e)))


def test_wrapping_a_foreign_error_keeps_its_message() raises:
    # An error from anything that has never heard of this mechanism. All that
    # is known about it is its text, and that is what the chain gets.
    try:
        try:
            raise Error("from somewhere else")
        except inner:
            raise wrap(inner, "calling out")
    except e:
        assert_equal(String(e), "calling out: from somewhere else")
        assert_equal(String(unwrap(e).value()), "from somewhere else")
        assert_false(Bool(field(unwrap(e).value(), "path")))


def test_a_wrapped_error_survives_a_later_raise() raises:
    # The record is replaced by the next raise on this thread, so the chain has
    # to be copied at wrap time rather than referred to. This is that test.
    try:
        try:
            raise Report("inner").with_code(ErrUnsupported).error()
        except inner:
            raise wrap(inner, "outer")
    except e:
        assert_true(matches(e, ErrUnsupported))


def test_a_chain_dies_when_something_else_raises() raises:
    # The other half of the same fact. Holding an error past the next raise
    # loses its record, and the answer is nothing rather than the newer
    # error's causes.
    var held = Error("")
    try:
        try:
            raise wrap(new("inner"), "outer")
        except e:
            held = e
        raise new("something else entirely")
    except _:
        assert_equal(causes(held).__len__(), 0)
        assert_false(matches(held, ErrUnsupported))
