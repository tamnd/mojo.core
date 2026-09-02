"""The thread local error record, and the three ways it can quietly be wrong.

The record surviving a raise is the easy part. The parts that fail silently,
and that this file exists for, are an error that is not ours being handed
somebody else's fields, and an error held past the next raise being handed the
newer error's fields. Both of those still run and still print something
plausible, which is the worst way for a thing to be broken.
"""

from std.testing import assert_equal, assert_false, assert_true

from core.errors import NO_CODE, Code, Report, code, field, has_record, partial


def _raise_path_error() raises:
    raise (
        Report("open /nope: no such file or directory")
        .with_code(Code(2))
        .with_field("op", "open")
        .with_field("path", "/nope")
        .error()
    )


def _one() raises:
    """A raise several frames below the catch, so the record has to outlive them.
    """
    _two()


def _two() raises:
    _three()


def _three() raises:
    _raise_path_error()


def test_message_is_the_error() raises:
    """The record does not change what the error says."""
    try:
        _raise_path_error()
    except e:
        assert_equal(String(e), "open /nope: no such file or directory")


def test_fields_come_back() raises:
    try:
        _raise_path_error()
    except e:
        assert_true(has_record(e))
        assert_equal(field(e, "op").or_else(""), "open")
        assert_equal(field(e, "path").or_else(""), "/nope")


def test_unknown_field_is_nothing() raises:
    """Missing is nothing rather than the empty string, which is a real value.
    """
    try:
        _raise_path_error()
    except e:
        assert_false(Bool(field(e, "mode")))


def test_code_and_count() raises:
    try:
        raise Report("short write").with_code(Code(9)).with_count(300).error()
    except e:
        assert_equal(code(e), Code(9))
        assert_equal(partial(e), 300)


def test_untagged_error_has_no_code() raises:
    """Zero means no code, which is why a registry of codes starts at one."""
    try:
        raise Report("plain").error()
    except e:
        assert_true(has_record(e))
        assert_equal(code(e), NO_CODE)
        assert_equal(partial(e), 0)


def test_record_survives_several_frames() raises:
    """The whole point of the storage. A record written three frames down is
    still there at the catch site, because it does not live in any of them."""
    try:
        _one()
    except e:
        assert_equal(field(e, "path").or_else(""), "/nope")


def test_foreign_error_has_no_record() raises:
    """An error from code that has never heard of this mechanism.

    The record from the previous raise is still in the slot. This is the case
    where the mechanism would hand back somebody else's fields, and it still
    runs and still looks plausible when it does.
    """
    _raise_path_error_and_swallow()
    try:
        raise Error("a plain error from somewhere else")
    except e:
        assert_false(has_record(e))
        assert_false(Bool(field(e, "path")))
        assert_equal(code(e), NO_CODE)
        assert_equal(partial(e), 0)


def _raise_path_error_and_swallow() raises:
    """Leave a record in the slot with nobody holding the error it belongs to.
    """
    try:
        _raise_path_error()
    except e:
        pass


def test_overwritten_record_fails_cleanly() raises:
    """An error held past the next raise reports nothing rather than the newer
    error's fields. This is the one that would be a wrong answer rather than a
    missing one, so it is the one worth being sure about."""
    var held = Error("")
    try:
        _raise_path_error()
    except e:
        held = e

    try:
        raise Report("write /other: disk full").with_field(
            "path", "/other"
        ).error()
    except e:
        # The newer error is fine.
        assert_equal(field(e, "path").or_else(""), "/other")

    # The older one has lost its fields and says so, rather than claiming
    # /other, which is the failure this is here to catch.
    assert_false(has_record(held))
    assert_false(Bool(field(held, "path")))


def test_repeated_field_keeps_the_first() raises:
    """Stated because both answers are defensible and code will depend on one.
    """
    try:
        raise Report("twice").with_field("k", "first").with_field(
            "k", "second"
        ).error()
    except e:
        assert_equal(field(e, "k").or_else(""), "first")


def test_many_raises_reuse_one_record() raises:
    """A thread that raises a lot allocates once, and the last one still reads.

    There is no way to assert the allocation count from here. What this does
    assert is that the reuse path, which overwrites through a pointer and
    destroys the old value, survives being taken a thousand times. A leak or a
    double free in it shows up here under a sanitizer and as a crash without
    one.
    """
    for i in range(1000):
        try:
            raise Report("round " + String(i)).with_field(
                "i", String(i)
            ).error()
        except e:
            assert_equal(field(e, "i").or_else(""), String(i))
