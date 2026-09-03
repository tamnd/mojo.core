"""Many replacements in one pass. Go's `strings.Replacer`.

`replace_all` called four times reads the string four times and builds three
throwaway copies, and worse, it lets the second pass see what the first one
wrote: replacing `&` with `&amp;` and then `<` with `&lt;` is fine, but doing
those two in the other order is fine too only by luck, and the pair `a`->`b`,
`b`->`c` turns every `a` into `c`. A `Replacer` reads the string once, and a
piece it has written is never looked at again, so the pairs cannot feed each
other.

The matching rule is Go's, exactly: replacements happen in the order they
appear in the target string, matches do not overlap, and when two keys match at
the same position the one that came first in the argument list wins. That last
part is why this is not longest-match: `new_replacer` with `a` before `ab`
replaces the `a` in `ab` and leaves the `b`.

The structure is a trie of the keys with the edges compressed, so a position in
the string is tested against every key at once, and the whole search costs one
pass with a small constant rather than one pass per pair. Go picks between four
implementations depending on the shape of the pairs, three of which are the
trie with the general case optimised out; this is the trie alone. The fast path
that skips a byte no key can start with is kept, which is the part that carries
most of the difference on the single byte pairs Go writes a whole
implementation for.

The nodes live in one `List` and refer to each other by index rather than by
pointer, with -1 where Go has nil. That is the ordinary way to write a tree in
a language that checks lifetimes: the arena owns every node, the indices cannot
dangle, and freeing the trie is freeing one list.
"""

from core.io import Byte, Writer


struct _Node(Copyable, Movable):
    """One node of the key trie.

    Holds a complete key when `priority` is positive, and has either one child
    reached by `prefix` and `next`, or a table of children, or neither. Go's
    `trieNode`, with `Int` indices into the replacer's node list standing in
    for its pointers.
    """

    var value: List[Byte]
    """What a key ending here is replaced with. Empty unless `priority` > 0."""

    var priority: Int
    """Higher wins when two keys match here. Zero means this is not a key."""

    var prefix: List[Byte]
    """The bytes between this node and `next`. Empty when there is no `next`.

    Bytes and not text, because splitting an edge cuts wherever two keys stop
    agreeing and that is not always a rune boundary.
    """

    var next: Int
    """The single child reached by `prefix`, or -1."""

    var table: List[Int]
    """A child per distinct key byte, -1 where there is none."""

    var has_table: Bool
    """Whether `table` is the way out of this node.

    Separate from `len(table)`, because a replacer built from no pairs at all
    has a table of length zero at the root, which is Go's non-nil empty slice
    and is not the same thing as having no table.
    """

    def __init__(out self):
        """A node with no key and no children."""
        self.value = List[Byte]()
        self.priority = 0
        self.prefix = List[Byte]()
        self.next = -1
        self.table = List[Int]()
        self.has_table = False


struct Replacer(Copyable, Movable):
    """A set of replacements to run over strings. Go's `strings.Replacer`.

    ```mojo
    from core.strings import new_replacer

    var esc = new_replacer([("<", "&lt;"), ("&", "&amp;")])
    print(esc.replace("a<b & c"))  # => a&lt;b &amp; c
    ```

    Build it once and use it many times. The trie is built by the constructor
    and never changes afterwards, so the same replacer can be shared freely.

    Go's is careful about being copied, because it builds itself lazily behind
    a `sync.Once` and a copied `Once` would build twice; `go vet` reports it.
    Here the work is done up front and there is nothing mutable left, so a copy
    is just a copy. That is the opposite call from `Builder` in the same
    package, and for the opposite reason: a builder that is copied is a bug, a
    replacer that is copied is not.
    """

    var _nodes: List[_Node]
    """The trie. Index 0 is the root and is always present."""

    var _mapping: List[Int]
    """Byte to dense table index, `_table_size` for a byte no key uses."""

    var _table_size: Int
    """How many distinct bytes the keys use, and so how wide a table is."""

    def __init__(out self, pairs: List[Tuple[String, String]]):
        """Build a replacer for `pairs`, each an old string and its new one.

        Earlier pairs win over later ones at the same position, which is the
        priority the trie carries. A pair whose old string is empty matches
        between every pair of runes, as it does in Go.
        """
        self._nodes = List[_Node]()
        self._mapping = List[Int](length=256, fill=0)
        self._table_size = 0

        # Every byte any key uses gets a column in the tables, and the rest
        # share the one index past the end, which is how a lookup rejects a
        # byte no key starts with in a single comparison.
        for i in range(len(pairs)):
            var key = pairs[i][0].as_bytes()
            for j in range(len(key)):
                self._mapping[Int(key[j])] = 1
        for i in range(256):
            self._table_size += self._mapping[i]
        var index = 0
        for i in range(256):
            if self._mapping[i] == 0:
                self._mapping[i] = self._table_size
            else:
                self._mapping[i] = index
                index += 1

        # The root always looks up through a table rather than a prefix, since
        # every search starts there and pays for it.
        self._nodes.append(_Node())
        self._nodes[0].table = List[Int](length=self._table_size, fill=-1)
        self._nodes[0].has_table = True

        for i in range(len(pairs)):
            self._add(
                pairs[i][0].as_bytes(),
                pairs[i][1].as_bytes(),
                len(pairs) - i,
            )

    def _new_node(mut self) -> Int:
        """Append an empty node and return its index."""
        self._nodes.append(_Node())
        return len(self._nodes) - 1

    def _add[
        o1: ImmOrigin, o2: ImmOrigin
    ](mut self, key: Span[Byte, o1], val: Span[Byte, o2], priority: Int):
        """Put `key` into the trie with `val` and `priority`.

        Go's `trieNode.add`, written as a loop rather than as recursion. Each
        turn either walks one edge down or splits one edge in two, so it runs
        at most once per byte of the key.
        """
        var t = 0
        var at = 0
        while True:
            if at == len(key):
                # A key ending here. The first pair to claim a node keeps it,
                # which is where earlier arguments win.
                if self._nodes[t].priority == 0:
                    self._nodes[t].value = List[Byte](val)
                    self._nodes[t].priority = priority
                return

            if len(self._nodes[t].prefix) != 0:
                var pfx = self._nodes[t].prefix.copy()
                var n = 0
                while (
                    n < len(pfx) and at + n < len(key) and pfx[n] == key[at + n]
                ):
                    n += 1

                if n == len(pfx):
                    # The key agrees with the whole edge, so carry on below it.
                    t = self._nodes[t].next
                    at += n
                elif n == 0:
                    # Nothing in common, so this node has to branch. What was
                    # the edge becomes one child and the key becomes the other.
                    var prefix_node: Int
                    if len(pfx) == 1:
                        prefix_node = self._nodes[t].next
                    else:
                        prefix_node = self._new_node()
                        self._nodes[prefix_node].prefix = List[Byte](
                            Span(pfx)[1 : len(pfx)]
                        )
                        self._nodes[prefix_node].next = self._nodes[t].next
                    var key_node = self._new_node()
                    self._nodes[t].table = List[Int](
                        length=self._table_size, fill=-1
                    )
                    self._nodes[t].has_table = True
                    self._nodes[t].table[
                        self._mapping[Int(pfx[0])]
                    ] = prefix_node
                    self._nodes[t].table[self._mapping[Int(key[at])]] = key_node
                    self._nodes[t].prefix = List[Byte]()
                    self._nodes[t].next = -1
                    t = key_node
                    at += 1
                else:
                    # They agree for a while. Cut the edge at the point they
                    # stop and go on from there.
                    var nxt = self._new_node()
                    self._nodes[nxt].prefix = List[Byte](
                        Span(pfx)[n : len(pfx)]
                    )
                    self._nodes[nxt].next = self._nodes[t].next
                    self._nodes[t].prefix = List[Byte](Span(pfx)[0:n])
                    self._nodes[t].next = nxt
                    t = nxt
                    at += n
            elif self._nodes[t].has_table:
                var m = self._mapping[Int(key[at])]
                if self._nodes[t].table[m] == -1:
                    self._nodes[t].table[m] = self._new_node()
                t = self._nodes[t].table[m]
                at += 1
            else:
                # A leaf, so the rest of the key becomes one edge and no table
                # is needed until something else arrives to disagree with it.
                self._nodes[t].prefix = List[Byte](key[at : len(key)])
                var nn = self._new_node()
                self._nodes[t].next = nn
                t = nn
                at = len(key)

    def _lookup[
        o: ImmOrigin
    ](self, s: Span[Byte, o], at: Int, ignore_root: Bool) -> Tuple[
        Int, Int, Bool
    ]:
        """Find the best key matching at `at`, as (node, key length, found).

        Go's `genericReplacer.lookup`. Walks as far down the trie as the text
        allows and keeps the highest priority key seen on the way, which is not
        the longest one: priority is argument order, so an earlier short key
        beats a later long one.

        `ignore_root` skips an empty key at the root, which is how a pair with
        an empty old string is stopped from matching twice in the same place.
        """
        var best_priority = 0
        var best_node = -1
        var keylen = 0
        var found = False
        var node = 0
        var n = 0
        var i = at

        while node != -1:
            var p = self._nodes[node].priority
            if p > best_priority and not (ignore_root and node == 0):
                best_priority = p
                best_node = node
                keylen = n
                found = True

            if i == len(s):
                break

            if self._nodes[node].has_table:
                var index = self._mapping[Int(s[i])]
                if index == self._table_size:
                    break
                node = self._nodes[node].table[index]
                i += 1
                n += 1
            elif len(self._nodes[node].prefix) != 0 and self._prefix_at(
                s, i, node
            ):
                var w = len(self._nodes[node].prefix)
                n += w
                i += w
                node = self._nodes[node].next
            else:
                break

        return (best_node, keylen, found)

    def _prefix_at[
        o: ImmOrigin
    ](self, s: Span[Byte, o], at: Int, node: Int) -> Bool:
        """Whether the edge out of `node` matches `s` starting at `at`."""
        var pfx = Span(self._nodes[node].prefix)
        if at + len(pfx) > len(s):
            return False
        for i in range(len(pfx)):
            if s[at + i] != pfx[i]:
                return False
        return True

    def _append[
        o: ImmOrigin
    ](self, mut out: List[Byte], s: Span[Byte, o]) -> Int:
        """Append `s` with every replacement made and return how many bytes.

        The single pass everything else here goes through. Go's
        `genericReplacer.WriteString` without the writer.
        """
        var last = 0
        var i = 0
        var n = 0
        var prev_match_empty = False

        while i <= len(s):
            # Nothing can start with this byte, so there is no point asking the
            # trie about it. This is the check that makes a replacer over a
            # handful of punctuation nearly as cheap as scanning the string.
            if i != len(s) and self._nodes[0].priority == 0:
                var index = self._mapping[Int(s[i])]
                if (
                    index == self._table_size
                    or self._nodes[0].table[index] == -1
                ):
                    i += 1
                    continue

            var best, keylen, matched = self._lookup(s, i, prev_match_empty)
            prev_match_empty = matched and keylen == 0
            if matched:
                for j in range(last, i):
                    out.append(s[j])
                n += i - last
                var val = Span(self._nodes[best].value)
                for j in range(len(val)):
                    out.append(val[j])
                n += len(val)
                i += keylen
                last = i
                continue
            i += 1

        if last != len(s):
            for j in range(last, len(s)):
                out.append(s[j])
            n += len(s) - last
        return n

    def replace[o: ImmOrigin](self, s: StringSlice[o]) -> String:
        """A copy of `s` with all the replacements made. Go's `Replace`.

        ```mojo
        from core.strings import new_replacer

        var r = new_replacer([("a", "b"), ("b", "c")])
        print(r.replace("ab"))  # => bc
        ```

        Note what that example is showing: the `a` becomes a `b` and is then
        left alone, so the answer is `bc` and not `cc`. Running the two
        replacements one after the other would give `cc`, and that is the
        difference a replacer buys.
        """
        var out = List[Byte](capacity=s.byte_length())
        _ = self._append(out, s.as_bytes())
        return String(from_utf8_lossy=Span(out))

    def write_string[
        W: Writer, o: ImmOrigin
    ](self, mut w: W, s: StringSlice[o]) raises -> Int:
        """Write `s` to `w` with all the replacements made. Go's `WriteString`.

        Returns how many bytes were written, which is the length of the result
        and not of `s`, since replacing changes the length.

        The result is built and then handed to `w` in one call. Go writes each
        unchanged run and each replacement separately as it goes, which keeps
        the peak memory down but means two writes per match, and against a
        writer with no buffer of its own that is two system calls per match.
        One buffer here costs the length of the answer, which the caller was
        going to pay for anyway if they used `replace`.
        """
        var out = List[Byte](capacity=s.byte_length())
        _ = self._append(out, s.as_bytes())
        return w.write(Span(out))


def new_replacer(pairs: List[Tuple[String, String]]) -> Replacer:
    """A replacer for `pairs`, each an old string and the new one.

    ```mojo
    from core.strings import new_replacer

    var r = new_replacer([("<", "&lt;"), (">", "&gt;"), ("&", "&amp;")])
    print(r.replace("<a & b>"))  # => &lt;a &amp; b&gt;
    ```

    Go's `NewReplacer` takes the old and new strings as one flat variadic list
    and panics on an odd number of them, which is a mistake it can only catch
    when the program runs. Pairs cannot be odd, so there is nothing to check
    and nothing to panic about, and the compiler catches a forgotten
    replacement at the call.

    Go also defers the building until the first use, so that a replacer in a
    package level variable costs nothing in a program that never reaches it.
    This one builds now. The lazy version needs a lock, a lock in a value makes
    the value hazardous to copy, and this way the cost is where the caller
    wrote it.
    """
    return Replacer(pairs)
