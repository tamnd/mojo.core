"""The LZ77 sliding window the decompressor writes into. Go's `dictDecoder`.

DEFLATE is two commands over a window of recently emitted bytes. A literal is a
byte inserted as it is. A backward copy is a pair, a distance saying how far
back to start and a length saying how many bytes to take, and it is read out of
the bytes this window already holds. The length may be larger than the
distance, which is not a mistake: copying forward one byte at a time over the
bytes being written is how DEFLATE spells a repeated run, so `(dist=1,
length=258)` is two hundred and fifty eight copies of the last byte.

The window is one buffer used as a ring, and `read_flush` is what empties it.
Nothing here checks its arguments, which is Go's decision as well: every call
site has already checked, and the invariants are written on each method. The
one difference from Go is that `read_flush` hands back a pair of indices rather
than a slice of the window, because a slice of a field cannot outlive the call
that made it here and the decompressor needs what it returned to survive until
the caller's next `read`.
"""

from core.io import Byte


struct _DictDecoder(Movable):
    """A window of already emitted bytes, and a writer position inside it."""

    var hist: List[Byte]
    """The window. Its length is the window size and never changes after
    `reset`."""

    var wr_pos: Int
    """Where the next byte written goes. Invariant: `0 <= rd_pos <= wr_pos <=
    len(hist)`."""

    var rd_pos: Int
    """Everything before this has been handed to the caller already."""

    var full: Bool
    """Whether a whole window has been written yet, which is what decides
    whether a distance reaching past `wr_pos` is history or is nothing."""

    def __init__(out self):
        self.hist = List[Byte]()
        self.wr_pos = 0
        self.rd_pos = 0
        self.full = False

    def reset[o: Origin](mut self, size: Int, dict: Span[Byte, o]):
        """Size the window and seed it. Go's `init`.

        The last `size` bytes of `dict` are treated as though they had already
        been emitted, which is what makes a preset dictionary work: the stream
        may point back into it from its very first command. A longer dictionary
        is cut from the front, since only the tail is reachable.
        """
        if len(self.hist) != size:
            self.hist = List[Byte](length=size, fill=0)
        var d = dict
        if len(d) > size:
            d = d[len(d) - size :]
        for i in range(len(d)):
            self.hist[i] = d[i]
        self.wr_pos = len(d)
        if self.wr_pos == size:
            self.wr_pos = 0
            self.full = True
        else:
            self.full = False
        self.rd_pos = self.wr_pos

    def hist_size(self) -> Int:
        """How far back a distance may reach. Go's `histSize`."""
        if self.full:
            return len(self.hist)
        return self.wr_pos

    def avail_read(self) -> Int:
        """How many bytes `read_flush` would hand over. Go's `availRead`."""
        return self.wr_pos - self.rd_pos

    def avail_write(self) -> Int:
        """How much room is left before a flush is needed. Go's `availWrite`."""
        return len(self.hist) - self.wr_pos

    def write_byte(mut self, c: Byte):
        """Write one byte. Go's `writeByte`.

        Invariant: `0 < avail_write()`.
        """
        self.hist[self.wr_pos] = c
        self.wr_pos += 1

    def write_mark(mut self, count: Int):
        """Account for bytes written into the window from outside.

        Go's `writeMark`, and the other half of its `writeSlice`. The slice
        itself is built by the caller, because a span of a field cannot be
        returned from a method here.

        Invariant: `0 <= count <= avail_write()`.
        """
        self.wr_pos += count

    def write_copy(mut self, dist: Int, length: Int) -> Int:
        """Copy `length` bytes from `dist` back. Go's `writeCopy`.

        Returns how many were copied, which is fewer than asked for when the
        window filled up first. The caller flushes and asks again for the rest.

        Invariant: `0 < dist <= hist_size()`.
        """
        var dst_base = self.wr_pos
        var dst_pos = dst_base
        var src_pos = dst_pos - dist
        var end_pos = dst_pos + length
        if end_pos > len(self.hist):
            end_pos = len(self.hist)

        # The section after the write position, which is the part of the
        # window the distance wrapped around to reach. It cannot overlap the
        # destination, because a distance is never longer than the window.
        if src_pos < 0:
            src_pos += len(self.hist)
            var n = min(end_pos - dst_pos, len(self.hist) - src_pos)
            for i in range(n):
                self.hist[dst_pos + i] = self.hist[src_pos + i]
            dst_pos += n
            src_pos = 0

        # The section before the write position, which may overlap it. Copying
        # forward one byte at a time is what makes a length longer than the
        # distance mean a repeated run rather than a mistake.
        for i in range(end_pos - dst_pos):
            self.hist[dst_pos + i] = self.hist[src_pos + i]
        dst_pos = end_pos

        self.wr_pos = dst_pos
        return dst_pos - dst_base

    def try_write_copy(mut self, dist: Int, length: Int) -> Int:
        """`write_copy` for the case that does not wrap. Go's `tryWriteCopy`.

        Zero comes back when the copy would wrap or would overrun the window,
        and the caller falls through to `write_copy`. Go keeps this separate so
        the common case inlines; it is kept here because it is also the shorter
        thing to read, and the hot path of a decompressor is worth two
        functions.

        Invariant: `0 < dist <= hist_size()`.
        """
        var dst_pos = self.wr_pos
        var end_pos = dst_pos + length
        if dst_pos < dist or end_pos > len(self.hist):
            return 0
        var dst_base = dst_pos
        var src_pos = dst_pos - dist
        for i in range(end_pos - dst_pos):
            self.hist[dst_pos + i] = self.hist[src_pos + i]
        self.wr_pos = end_pos
        return end_pos - dst_base

    def read_flush(mut self) -> Tuple[Int, Int]:
        """The part of the window ready to go out. Go's `readFlush`.

        A half open range into `hist` rather than a slice of it. The caller
        must consume it before calling anything else here, which is Go's rule
        as well, and the window wraps to the start once it is full.
        """
        var start = self.rd_pos
        var end = self.wr_pos
        self.rd_pos = self.wr_pos
        if self.wr_pos == len(self.hist):
            self.wr_pos = 0
            self.rd_pos = 0
            self.full = True
        return (start, end)
