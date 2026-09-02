# PINS: Where this is better than Go
# EXPECT: runs
# OUTPUT: the span saw the write 9
# WHY: This section used to claim that a slice handed out by a buffer is
# WHY: invalidated by the next write to that buffer, and that using it
# WHY: afterwards is a compile error here where it is a documented hazard in
# WHY: Go. It is not. A `Span` built from a `List` stays usable across a
# WHY: mutation of that list, and the compiler says nothing. This probe shows
# WHY: the benign half, an in place write with no reallocation, because it is
# WHY: fully defined and still proves the point: an immutable borrow and a
# WHY: mutable use of the same value overlap and nothing complains. The
# WHY: dangerous half is the same code with an `append` that grows the list,
# WHY: which also compiles and reads freed memory, and is not written here
# WHY: because a probe should not be undefined behaviour.
# WHY:
# WHY: `core.bufio` is the first package this decides. Go's `Peek`,
# WHY: `ReadSlice`, `ReadLine` and `Scanner.Bytes` all return a view into the
# WHY: buffer; ours return owned bytes, and the copy is the price of the
# WHY: guarantee. If Mojo ever starts rejecting the snippet below this probe
# WHY: fails, the section goes back to what it said, and those four can hand
# WHY: out views again.

comptime Byte = UInt8


def main():
    var buffer = List[Byte]()
    buffer.append(1)
    buffer.append(2)

    # The borrow. Everything below this line is a use of `buffer` while the
    # span derived from it is still live.
    var view = Span(buffer)

    buffer[0] = 9

    # Reads the write through a borrow taken before it happened.
    print("the span saw the write", view[0])
