"""Capturing an error so it outlives the raise, and sending it to a thread.

The last of the three ways design.md section 4 can fail silently. The first two
are in `test_record.mojo`: a foreign error mistaken for ours, and an error held
past the next raise. This is the third, where the reading thread's own slot
holds something else entirely and a lookup that went through it would answer
with that instead.

The thread here is raw pthread through `external_call`, which is not how this
library will spawn threads. `core.sync` does not exist yet and this test is the
reason it cannot wait: the capture has to be proved across a real thread before
anything is built on it. It gets rewritten against `core.sync` in M9.
"""

from std.ffi import external_call
from std.testing import assert_equal, assert_false, assert_true

from core.errors import (
    ErrUnsupported,
    ErrorValue,
    Report,
    capture,
    causes,
    field,
    join,
    matches,
    new,
    wrap,
)

comptime Any = AnyOrigin[mut=True]


def test_capture_survives_the_next_raise() raises:
    var kept = capture(Error(""))
    try:
        raise Report("disk full").with_field("device", "sda1").error()
    except e:
        kept = capture(e)

    try:
        raise new("something else entirely")
    except _:
        pass

    assert_equal(kept.message(), "disk full")
    assert_equal(kept.field("device").or_else(""), "sda1")


def test_two_captures_are_both_whole() raises:
    # The motivating case. Each raise replaces the other's record, so without
    # the capture the first would have nothing left by the end of the loop.
    var kept = List[ErrorValue]()
    for name in ["a", "b", "c"]:
        try:
            raise Report("cannot open " + name).with_field("path", name).error()
        except e:
            kept.append(capture(e))

    assert_equal(kept.__len__(), 3)
    assert_equal(kept[0].field("path").or_else(""), "a")
    assert_equal(kept[1].field("path").or_else(""), "b")
    assert_equal(kept[2].field("path").or_else(""), "c")


def test_capture_keeps_the_whole_chain() raises:
    var kept = capture(Error(""))
    try:
        try:
            try:
                raise Report("connection refused").with_code(
                    ErrUnsupported
                ).error()
            except a:
                raise wrap(a, "dialling")
        except b:
            raise Report("querying").wrapping(b).with_field(
                "host", "db1"
            ).error()
    except e:
        kept = capture(e)

    try:
        raise new("wiping the slot")
    except _:
        pass

    assert_equal(kept.message(), "querying: dialling: connection refused")
    assert_equal(kept.field("host").or_else(""), "db1")
    assert_true(kept.matches(ErrUnsupported))

    var one = kept.unwrap().value().copy()
    assert_equal(one.message(), "dialling: connection refused")
    var two = one.unwrap().value().copy()
    assert_equal(two.message(), "connection refused")
    assert_equal(two.code(), ErrUnsupported)
    assert_false(Bool(two.unwrap()))


def test_capture_keeps_every_cause_of_a_join() raises:
    var kept = capture(Error(""))
    try:
        raise join(new("disk full"), new("no such host"))
    except e:
        kept = capture(e)

    try:
        raise new("wiping the slot")
    except _:
        pass

    var found = kept.causes()
    assert_equal(found.__len__(), 2)
    assert_equal(found[0].message(), "disk full")
    assert_equal(found[1].message(), "no such host")
    assert_false(Bool(kept.unwrap()))


def test_capture_of_a_foreign_error_is_its_message() raises:
    # Nothing wrote a record for this one, so its message is all there is and
    # that is what comes back. Never somebody else's fields.
    try:
        raise Report("ours").with_field("path", "/a").error()
    except _:
        var kept = capture(Error("from somewhere else"))
        assert_equal(kept.message(), "from somewhere else")
        assert_false(Bool(kept.field("path")))


def test_reraising_a_capture_restores_the_record() raises:
    var kept = capture(Error(""))
    try:
        raise Report("no such file").with_field("path", "/etc/x").error()
    except e:
        kept = capture(e)

    try:
        raise new("wiping the slot")
    except _:
        pass

    try:
        raise kept.error()
    except again:
        assert_equal(field(again, "path").or_else(""), "/etc/x")
        assert_true(matches(again, ErrUnsupported) == False)


def test_a_capture_can_be_reraised_twice() raises:
    # `error()` borrows rather than consumes, so a captured error kept in a
    # list can be re-raised by every caller that looks at the list.
    var kept = capture(Error(""))
    try:
        raise Report("busy").with_code(ErrUnsupported).error()
    except e:
        kept = capture(e)

    for _ in range(2):
        try:
            raise kept.error()
        except again:
            assert_true(matches(again, ErrUnsupported))


struct Crossing:
    """What crosses the boundary, and what the far side found when it looked."""

    var sent: ErrorValue
    var message: String
    var path: String
    var inner: String
    var matched: Bool
    var causes: Int

    def __init__(out self, var sent: ErrorValue):
        self.sent = sent^
        self.message = String("")
        self.path = String("")
        self.inner = String("")
        self.matched = False
        self.causes = 0


def reader(arg: OpaquePointer[Any]) -> OpaquePointer[Any]:
    """Read the captured error on a thread that never saw it raised."""
    ref shared = arg.unsafe_bitcast[Crossing]()[]

    # This thread's own slot holds something else entirely, which is the case
    # a lookup through the slot would get wrong. Every assertion after this
    # would still pass against an empty slot, so the wrong record has to be
    # there for the test to mean anything.
    try:
        raise Report("what this thread was doing").with_field(
            "path", "/the wrong one"
        ).error()
    except _:
        pass

    shared.message = shared.sent.message()
    shared.path = shared.sent.field("path").or_else("")
    shared.matched = shared.sent.matches(ErrUnsupported)
    shared.causes = shared.sent.causes().__len__()
    var one = shared.sent.unwrap()
    if one:
        shared.inner = one.value().message()
    return arg


def test_a_capture_crosses_a_thread() raises:
    var kept = capture(Error(""))
    try:
        try:
            raise Report("read only filesystem").with_code(
                ErrUnsupported
            ).with_field("path", "/mnt/ro").error()
        except inner:
            raise wrap(inner, "saving draft")
    except e:
        kept = capture(e)

    var shared = Crossing(kept^)
    var id = UInt64(0)
    var started = external_call["pthread_create", Int32](
        Pointer(to=id),
        Int(0),
        reader,
        Pointer(to=shared).unsafe_bitcast[NoneType](),
    )
    assert_equal(Int(started), 0)
    _ = external_call["pthread_join", Int32](id, Int(0))

    assert_equal(shared.message, "saving draft: read only filesystem")
    assert_equal(shared.inner, "read only filesystem")
    assert_equal(shared.causes, 1)
    assert_true(shared.matched)
    # The outer link has no `path`, and the record this thread put in its own
    # slot does. Reading `/the wrong one` here is the failure being ruled out.
    assert_equal(shared.path, "")
    assert_equal(
        shared.sent.unwrap().value().field("path").or_else(""), "/mnt/ro"
    )


def test_join_over_captures_keeps_every_field() raises:
    # `join` over live errors keeps the fields of at most one of them, because
    # a record is written at raise time and the next raise replaces it. Over
    # captured errors it keeps all of them, which is the gap capture closes.
    var kept = List[ErrorValue]()
    for name in ["a", "b"]:
        try:
            raise Report("cannot open " + name).with_field("path", name).error()
        except e:
            kept.append(capture(e))

    try:
        raise join(kept[0], kept[1])
    except e:
        var found = causes(e)
        assert_equal(found.__len__(), 2)
        assert_equal(field(found[0], "path").or_else(""), "a")
        assert_equal(field(found[1], "path").or_else(""), "b")


def test_join_over_live_errors_keeps_only_the_last() raises:
    # The other side of the same fact, pinned so that the deviations page and
    # the code cannot drift apart. `first` lost its record when `second` was
    # raised, so it arrives as a message and nothing else.
    var first = Report("cannot open a").with_field("path", "a").error()
    var second = Report("cannot open b").with_field("path", "b").error()
    try:
        raise join(first, second)
    except e:
        var found = causes(e)
        assert_equal(found.__len__(), 2)
        assert_false(Bool(field(found[0], "path")))
        assert_equal(field(found[1], "path").or_else(""), "b")
