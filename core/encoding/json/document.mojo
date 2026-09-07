"""A whole document, read into an arena. Go's `map[string]any` and `[]any`.

Go reads a document of unknown shape by unmarshalling it into an `any`, which
gives back a tree of `map[string]any`, `[]any`, `string`, `float64`, `bool` and
`nil`, and a caller walks it with type switches. There is no `any` here and no
type switch to do on it, design.md section 1, and a struct cannot hold itself
either, design.md section 5, so neither half of Go's answer is available.

What is here instead is one flat arena. Every value in the document is a node
in a list, a `Value` is an index into that list rather than a pointer at a node,
and an object or an array holds a range of indices into a second list. Nothing
points at anything, so nothing is recursive, and the whole document is three
allocations that grow rather than one allocation per node.

A handle is checked twice. Mojo's origins tie a `Value` to the document it came
from, so a document cannot be moved or parsed into again while a handle on it is
alive, which is the half a generation counter cannot do and a compiler can. The
counter is the other half: it is on the document and on every handle, `reset`
and `parse_into` raise it, and a handle from an earlier generation raises
`ErrJSONStale` rather than reading whatever now lives at its index.

Three things about a document are decided here rather than left to fall out.
Nesting is capped, at the scanner's own ten thousand, so a few kilobytes of
opening brackets are a refusal rather than a stack. A number keeps the text the
document wrote and is converted only when a caller asks for a machine type, so
nothing is rounded on the way in. And a string that is not text is refused
rather than repaired: an escape naming half of a surrogate pair with no other
half, and bytes that are not UTF-8, both raise `ErrJSONText`, where Go turns
each of them into U+FFFD and carries on. That is the one place this parser
refuses a document `valid` accepts, and `docs/deviations.md` has the row.
"""

from core.errors import Report
from core.errors.codes import ErrJSONStale, ErrJSONText
from core.io import Byte
from core.unicode.utf8 import RUNE_ERROR, RUNE_SELF, append_rune, decode_rune

from .decode import _decode_surrogate_pair, _getu4, _is_surrogate
from .number import Number
from .scan import (
    _BACKSLASH,
    _LOWER_B,
    _LOWER_F,
    _LOWER_N,
    _LOWER_R,
    _LOWER_T,
    _LOWER_U,
    _NEWLINE,
    _QUOTE,
    _RETURN,
    _SCAN_BEGIN_ARRAY,
    _SCAN_BEGIN_LITERAL,
    _SCAN_BEGIN_OBJECT,
    _SCAN_CONTINUE,
    _SCAN_END,
    _SCAN_END_ARRAY,
    _SCAN_END_OBJECT,
    _SCAN_ERROR,
    _SCAN_OBJECT_KEY,
    _SCAN_OBJECT_VALUE,
    _Scanner,
    _TAB,
    _syntax_error,
    valid_or_raise,
)
from .token import BOOL, NULL, NUMBER, STRING

comptime ARRAY = 5
"""A list of values. Go's `[]any`.

Numbered past `NULL` so that a document kind and a token kind are the same four
numbers wherever they mean the same thing. `DELIM` has no counterpart here,
because a bracket in a token stream is structure in a document.
"""

comptime OBJECT = 6
"""A list of named values. Go's `map[string]any`, except that this keeps the
order the document wrote and Go's map does not."""


def _describe(kind: Int) -> String:
    """What a kind is called in a message."""
    if kind == BOOL:
        return String("a boolean")
    if kind == NUMBER:
        return String("a number")
    if kind == STRING:
        return String("a string")
    if kind == ARRAY:
        return String("an array")
    if kind == OBJECT:
        return String("an object")
    return String("null")


def _text_error(msg: String, offset: Int) -> Error:
    """A string that is not text, with the byte the parser was on."""
    return (
        Report(msg)
        .with_code(ErrJSONText)
        .with_field("offset", String(offset))
        .error()
    )


def _unquote_strict[o: Origin](quoted: Span[Byte, o], at: Int) raises -> String:
    """The characters a quoted string literal stands for, or a raise.

    `core.encoding.json.decode._unquote` is the same walk with the two refusals
    turned into U+FFFD, which is what Go does and what a token stream wants. A
    document wants the other answer: a handle that says it holds a string should
    hold what the document said, and there is no way to tell a substituted
    U+FFFD from one the document actually contained.

    `at` is where `quoted` starts in the input, so an offset in a failure names
    a byte of the document rather than a byte of the literal.
    """
    var s = quoted[1 : len(quoted) - 1]
    var text = List[Byte](capacity=len(s))
    var r = 0
    while r < len(s):
        var c = s[r]
        if c == _BACKSLASH:
            var esc = s[r + 1]
            if esc == _LOWER_U:
                var first = _getu4(s[r : len(s)])
                if first < 0:
                    raise _syntax_error(
                        "invalid character in \\u escape", at + r + 1
                    )
                r += 6
                if _is_surrogate(first):
                    var paired = _decode_surrogate_pair(
                        first, _getu4(s[r : len(s)])
                    )
                    if paired == RUNE_ERROR:
                        raise _text_error(
                            "unpaired surrogate in string escape",
                            at + r - 5,
                        )
                    r += 6
                    _ = append_rune(text, paired)
                    continue
                _ = append_rune(text, first)
                continue
            r += 2
            if esc == _LOWER_B:
                text.append(Byte(8))
            elif esc == _LOWER_F:
                text.append(Byte(12))
            elif esc == _LOWER_N:
                text.append(_NEWLINE)
            elif esc == _LOWER_R:
                text.append(_RETURN)
            elif esc == _LOWER_T:
                text.append(_TAB)
            else:
                text.append(esc)
        elif c < Byte(RUNE_SELF):
            text.append(c)
            r += 1
        else:
            var decoded = decode_rune(s[r : len(s)])
            if decoded[0] == RUNE_ERROR and decoded[1] == 1:
                raise _text_error(
                    "string holds bytes that are not UTF-8", at + r + 1
                )
            # Copied rather than encoded again, so a document's own bytes are
            # what comes out. `decode_rune` accepting them is what says they are
            # UTF-8, and a surrogate or an overlong sequence is not accepted.
            for k in range(decoded[1]):
                text.append(s[r + k])
            r += decoded[1]
    return String(from_utf8_lossy=Span(text))


struct _Node(Copyable, Movable):
    """One value. Five of the six kinds use one field and ignore the rest."""

    var kind: Int
    """Which of `NULL`, `BOOL`, `NUMBER`, `STRING`, `ARRAY` and `OBJECT`."""

    var boolean: Bool
    """The value, for `true` and `false`."""

    var text: String
    """The characters for a string, with the escapes already expanded, or the
    number as the document wrote it."""

    var start: Int
    """Where this container's children start, in `_elems` or `_members`."""

    var count: Int
    """How many children it has."""

    def __init__(out self, kind: Int):
        """A scalar of `kind`, with nothing in it yet."""
        self.kind = kind
        self.boolean = False
        self.text = String()
        self.start = 0
        self.count = 0


struct _Member(Copyable, Movable):
    """One name and the value it names, in the order the document wrote them."""

    var key: String
    """The name, with its escapes already expanded."""

    var node: Int
    """The value's index in the arena, or -1 while the name has been read and
    the value it names has not."""

    def __init__(out self, var key: String, node: Int):
        self.key = key^
        self.node = node


struct _Frame(Copyable, Movable):
    """One open bracket, and where its children began."""

    var kind: Int
    """`ARRAY` or `OBJECT`."""

    var elems: Int
    """How many pending elements there were when this opened."""

    var members: Int
    """How many pending members there were when this opened."""

    var expect_key: Bool
    """Whether the next literal in this object is a name rather than a value."""

    def __init__(out self, kind: Int, elems: Int, members: Int):
        self.kind = kind
        self.elems = elems
        self.members = members
        self.expect_key = kind == OBJECT


struct Document(Movable):
    """One parsed document, as an arena of nodes. Go has no counterpart.

    ```mojo
    from core.encoding.json import parse


    def first_tag() raises -> String:
        var doc = parse('{"tags": ["a", "b"]}'.as_bytes())
        return doc.root().field("tags").at(0).as_string()
    ```

    Not `Copyable`. A copy is a deep copy of the whole document, which is a
    thing to ask for rather than a thing to get by writing an assignment, and
    nothing here needs one.
    """

    var _nodes: List[_Node]
    """Every value in the document. The arena."""

    var _elems: List[Int]
    """Array children, as indices into `_nodes`. Each array owns one run."""

    var _members: List[_Member]
    """Object children. Each object owns one run, in the document's order."""

    var _root: Int
    """The index of the top level value, or -1 for a document with none."""

    var _generation: Int
    """Raised by every `reset`, so that a handle from before one raises."""

    def __init__(out self):
        """An empty document. `new_document` is the name to call this by."""
        self._nodes = List[_Node]()
        self._elems = List[Int]()
        self._members = List[_Member]()
        self._root = -1
        self._generation = 0

    def reset(mut self):
        """Forget the document and keep the memory. Go has no counterpart.

        The three lists keep their capacity, so a program parsing a million
        messages through one document allocates for the largest rather than for
        the total. Every handle taken before this stops working, which is what
        the generation counter is for.
        """
        self._nodes.clear()
        self._elems.clear()
        self._members.clear()
        self._root = -1
        self._generation += 1

    def root(ref self) -> Value[origin_of(self)]:
        """The top level value.

        A document that has not been parsed into has a `null` here, which is the
        node a zero length arena would otherwise have to invent. `parse` never
        produces one, since a document with nothing in it is not JSON.
        """
        return Value[origin_of(self)](self, self._root, self._generation)

    def parse_into[o: Origin](mut self, b: Span[Byte, o]) raises:
        """Read `b`, replacing whatever was here. Go's `Unmarshal` into an
        `any`.

        Two passes. The first is `valid_or_raise`, which decides whether the
        bytes are one JSON value and nothing else and which caps the nesting, so
        the second pass is a walk over bytes already known to be a document and
        has no structural failure left to report. That is Go's arrangement too,
        and it is why the builder below needs no stack of its own beyond one
        frame per open bracket.
        """
        valid_or_raise(b)
        self.reset()
        var scan = _Scanner()
        var stack = List[_Frame]()
        var pending_elems = List[Int]()
        var pending_members = List[_Member]()
        var literal = -1
        var i = 0
        while i < len(b):
            var op = scan.next(b[i])
            if literal >= 0 and op != _SCAN_CONTINUE:
                self._literal(
                    b[literal:i], literal, stack, pending_elems, pending_members
                )
                literal = -1
            if op == _SCAN_BEGIN_LITERAL:
                literal = i
            elif op == _SCAN_BEGIN_ARRAY:
                stack.append(
                    _Frame(ARRAY, len(pending_elems), len(pending_members))
                )
            elif op == _SCAN_BEGIN_OBJECT:
                stack.append(
                    _Frame(OBJECT, len(pending_elems), len(pending_members))
                )
            elif op == _SCAN_END_ARRAY or op == _SCAN_END_OBJECT:
                self._close(stack, pending_elems, pending_members)
            elif op == _SCAN_OBJECT_KEY:
                stack[len(stack) - 1].expect_key = False
            elif op == _SCAN_OBJECT_VALUE:
                stack[len(stack) - 1].expect_key = True
            elif op == _SCAN_END:
                break
            elif op == _SCAN_ERROR:
                # `valid_or_raise` has already been over these bytes, so this is
                # unreachable and is here because a silent miss would be worse
                # than a message nobody expects to see.
                raise scan.error()
            i += 1
        if literal >= 0:
            self._literal(
                b[literal : len(b)],
                literal,
                stack,
                pending_elems,
                pending_members,
            )

    def _literal[
        o: Origin
    ](
        mut self,
        text: Span[Byte, o],
        at: Int,
        mut stack: List[_Frame],
        mut pending_elems: List[Int],
        mut pending_members: List[_Member],
    ) raises:
        """Turn one string, number, boolean or null into a node.

        The first byte says which of the four it is, which the scanner has
        already proved is the only one it can be. A string where a name belongs
        goes onto the member list with no value against it rather than becoming
        a node, and whatever is read next fills the value in. That is what makes
        a name outlast the nested document that may sit between it and its
        value, which a single held key would not.
        """
        var first = text[0]
        if first == _QUOTE:
            var s = _unquote_strict(text, at)
            var depth = len(stack)
            if depth > 0 and stack[depth - 1].expect_key:
                pending_members.append(_Member(s^, -1))
                return
            var node = _Node(STRING)
            node.text = s^
            self._emit(node^, stack, pending_elems, pending_members)
            return
        if first == _LOWER_T or first == _LOWER_F:
            var node = _Node(BOOL)
            node.boolean = first == _LOWER_T
            self._emit(node^, stack, pending_elems, pending_members)
            return
        if first == _LOWER_N:
            self._emit(_Node(NULL), stack, pending_elems, pending_members)
            return
        var node = _Node(NUMBER)
        node.text = String(from_utf8_lossy=text)
        self._emit(node^, stack, pending_elems, pending_members)

    def _emit(
        mut self,
        var node: _Node,
        mut stack: List[_Frame],
        mut pending_elems: List[Int],
        mut pending_members: List[_Member],
    ):
        """Add a finished node and hand it to whatever is holding it."""
        self._nodes.append(node^)
        self._attach(
            len(self._nodes) - 1, stack, pending_elems, pending_members
        )

    def _attach(
        mut self,
        index: Int,
        mut stack: List[_Frame],
        mut pending_elems: List[Int],
        mut pending_members: List[_Member],
    ):
        """Record `index` as an element, a member, or the whole document."""
        var depth = len(stack)
        if depth == 0:
            self._root = index
            return
        if stack[depth - 1].kind == ARRAY:
            pending_elems.append(index)
            return
        # The name went on when it was read, so the last member is always the
        # one waiting for this value.
        pending_members[len(pending_members) - 1].node = index

    def _close(
        mut self,
        mut stack: List[_Frame],
        mut pending_elems: List[Int],
        mut pending_members: List[_Member],
    ):
        """Finish the open bracket and give it its children.

        The children were collected on the pending lists as they were read,
        because a nested container's own children land there in between and a
        run in the arena is only contiguous once the bracket closes. Moving them
        across here is what makes it so.
        """
        var frame = stack.pop()
        var node = _Node(frame.kind)
        if frame.kind == ARRAY:
            node.count = len(pending_elems) - frame.elems
            node.start = len(self._elems)
            for k in range(frame.elems, len(pending_elems)):
                self._elems.append(pending_elems[k])
            pending_elems.resize(frame.elems, 0)
        else:
            node.count = len(pending_members) - frame.members
            node.start = len(self._members)
            # Room first and then filled backwards out of the pending stack, so
            # that every key moves rather than being copied. A document is
            # mostly object keys, and copying each of them once more would be
            # the largest thing this parser does.
            self._members.resize(node.start + node.count, _Member(String(), 0))
            for k in reversed(range(node.count)):
                self._members[node.start + k] = pending_members.pop()
        self._nodes.append(node^)
        self._attach(
            len(self._nodes) - 1, stack, pending_elems, pending_members
        )


struct Value[o: ImmOrigin](
    Copyable, ImplicitlyCopyable, Movable, Sized, Writable
):
    """One value in a document. Go's `any` from an `Unmarshal`.

    ```mojo
    from core.encoding.json import parse


    def names() raises -> List[String]:
        var doc = parse('{"a": 1, "b": 2}'.as_bytes())
        var root = doc.root()
        var found = List[String]()
        for i in range(len(root)):
            found.append(root.key(i))
        return found^
    ```

    An index into the document rather than a pointer at a node, so it is two
    integers and a borrow and copying one costs nothing. `kind` says which of
    the six this is and the accessors raise rather than hand back a value that
    is not there, exactly as `Token`'s do.

    A handle does not keep the document alive: it borrows it, so the compiler
    refuses a handle that outlives what it points into and refuses a `parse_into`
    while one is alive. `ErrJSONStale` is what is left after that, for a handle
    that was copied out of an origin the compiler could not follow.
    """

    var doc: Pointer[Document, Self.o]
    """The document this indexes into."""

    var index: Int
    """Which node, or -1 for the root of a document with nothing in it."""

    var generation: Int
    """Which generation of the document this was made in."""

    def __init__(out self, ref[Self.o] doc: Document, index: Int, gen: Int):
        """A handle on `index`. Built by the document, not by a caller."""
        self.doc = Pointer(to=doc)
        self.index = index
        self.generation = gen

    def _at(self) raises -> Int:
        """Which node this names, or a raise for a handle that cannot be used.

        Every accessor starts here. An index on its own says nothing about
        whether the arena it indexes is still the one it was made for, and this
        is where that gets checked.
        """
        if self.generation != self.doc[]._generation:
            raise (
                Report("json: handle from an earlier parse")
                .with_code(ErrJSONStale)
                .error()
            )
        if self.index < 0:
            raise Error("json: the document is empty")
        return self.index

    def kind(self) raises -> Int:
        """Which of `NULL`, `BOOL`, `NUMBER`, `STRING`, `ARRAY` and `OBJECT`."""
        return self.doc[]._nodes[self._at()].kind

    def is_null(self) raises -> Bool:
        """Whether this is `null`."""
        return self.kind() == NULL

    def as_bool(self) raises -> Bool:
        """The boolean, or a raise if this is something else."""
        var n = self._at()
        self._must_be(self.doc[]._nodes[n].kind, BOOL, "a boolean")
        return self.doc[]._nodes[n].boolean

    def as_number(self) raises -> Number:
        """The number as the document wrote it, or a raise if this is something
        else.

        Nothing was converted on the way in, so `1e400` and a twenty digit
        integer are both here as they were written, and `float64` or `int64` on
        the `Number` is where a caller finds out whether the machine type they
        wanted can hold it.
        """
        var n = self._at()
        self._must_be(self.doc[]._nodes[n].kind, NUMBER, "a number")
        return Number(self.doc[]._nodes[n].text)

    def as_string(self) raises -> String:
        """The characters, or a raise if this is something else."""
        var n = self._at()
        self._must_be(self.doc[]._nodes[n].kind, STRING, "a string")
        return self.doc[]._nodes[n].text.copy()

    def __len__(self) -> Int:
        """How many elements an array has, or members an object has.

        Zero for the other four kinds and zero for a handle that cannot be used,
        because there is no way to raise from here and a scalar having no
        children is a true answer rather than a stand in for a failure. `kind`
        is the call that says which of those it was.
        """
        try:
            return self.doc[]._nodes[self._at()].count
        except:
            return 0

    def at(self, i: Int) raises -> Self:
        """The `i`th element of an array."""
        var n = self._at()
        self._must_be(self.doc[]._nodes[n].kind, ARRAY, "an array")
        self._must_hold(i, self.doc[]._nodes[n].count)
        return Self(
            self.doc[],
            self.doc[]._elems[self.doc[]._nodes[n].start + i],
            self.generation,
        )

    def key(self, i: Int) raises -> String:
        """The name of the `i`th member of an object, in the document's order.
        """
        var n = self._at()
        self._must_be(self.doc[]._nodes[n].kind, OBJECT, "an object")
        self._must_hold(i, self.doc[]._nodes[n].count)
        return self.doc[]._members[self.doc[]._nodes[n].start + i].key.copy()

    def member(self, i: Int) raises -> Self:
        """The value of the `i`th member of an object, in the document's order.
        """
        var n = self._at()
        self._must_be(self.doc[]._nodes[n].kind, OBJECT, "an object")
        self._must_hold(i, self.doc[]._nodes[n].count)
        return Self(
            self.doc[],
            self.doc[]._members[self.doc[]._nodes[n].start + i].node,
            self.generation,
        )

    def has(self, name: StringSlice) raises -> Bool:
        """Whether an object has a member of that name."""
        return self._find(name) >= 0

    def field(self, name: StringSlice) raises -> Self:
        """The member of that name, or a raise if the object has none.

        RFC 8259 section 4 says the names in an object SHOULD be unique and does
        not say what to do when they are not, so a document may carry two of
        them and this has to answer. The last one wins, which is what Go's map
        ends up with because each assignment overwrites the one before, and both
        are still there in the order the document wrote them for a caller
        walking with `key` and `member` who would rather see that.
        """
        var found = self._find(name)
        if found < 0:
            raise Error("json: no member named " + repr(String(name)))
        var n = self._at()
        return Self(
            self.doc[],
            self.doc[]._members[self.doc[]._nodes[n].start + found].node,
            self.generation,
        )

    def _find(self, name: StringSlice) raises -> Int:
        """Which member has that name, counting from the last, or -1."""
        var n = self._at()
        self._must_be(self.doc[]._nodes[n].kind, OBJECT, "an object")
        var start = self.doc[]._nodes[n].start
        for k in reversed(range(self.doc[]._nodes[n].count)):
            if self.doc[]._members[start + k].key == name:
                return k
        return -1

    def _must_be(self, kind: Int, wanted: Int, description: StringSlice) raises:
        """Refuse to answer a question the wrong kind was asked."""
        if kind != wanted:
            raise Error(
                "json: value is "
                + _describe(kind)
                + ", not "
                + String(description)
            )

    def _must_hold(self, i: Int, count: Int) raises:
        """Refuse an index outside the container. Go panics here."""
        if i < 0 or i >= count:
            raise Error(
                "json: index "
                + String(i)
                + " out of range, the container holds "
                + String(count)
            )

    def write_to[W: Writer](self, mut writer: W):
        """The value written back out as JSON, with no whitespace in it.

        A round trip through `parse` gives the same document, which is not the
        same thing as giving the same bytes: the insignificant whitespace is
        gone, a number is as the document wrote it rather than reformatted, and
        an escape that named a character the document could have written
        directly is written directly. `indent` is the call for a shape, and
        `html_escape` for a document going into a script tag, since this escapes
        what JSON requires and nothing more.

        An explicit stack rather than recursion, so a document nested ten
        thousand deep costs a list rather than ten thousand frames.
        """
        ref doc = self.doc[]
        if self.generation != doc._generation or self.index < 0:
            writer.write("null")
            return
        var at = List[Int]()
        var written = List[Int]()
        at.append(self.index)
        written.append(0)
        while len(at) > 0:
            var top = len(at) - 1
            var index = at[top]
            var kind = doc._nodes[index].kind
            if kind != ARRAY and kind != OBJECT:
                if kind == NULL:
                    writer.write("null")
                elif kind == BOOL:
                    writer.write(
                        "true" if doc._nodes[index].boolean else "false"
                    )
                elif kind == NUMBER:
                    writer.write(doc._nodes[index].text)
                else:
                    _write_quoted(writer, doc._nodes[index].text)
                at.resize(top, 0)
                written.resize(top, 0)
                continue
            var done = written[top]
            if done == 0:
                writer.write("[" if kind == ARRAY else "{")
            if done == doc._nodes[index].count:
                writer.write("]" if kind == ARRAY else "}")
                at.resize(top, 0)
                written.resize(top, 0)
                continue
            if done > 0:
                writer.write(",")
            written[top] = done + 1
            var start = doc._nodes[index].start
            var child: Int
            if kind == ARRAY:
                child = doc._elems[start + done]
            else:
                _write_quoted(writer, doc._members[start + done].key)
                writer.write(":")
                child = doc._members[start + done].node
            at.append(child)
            written.append(0)


def _write_quoted[W: Writer](mut writer: W, s: StringSlice):
    """`s` as a JSON string literal, quotes and all.

    The four characters RFC 8259 section 7 says have to be escaped are, and
    every other control character goes out as a `\\u` escape. Nothing else is
    touched, so a document that arrived in UTF-8 leaves in UTF-8 rather than as
    a wall of escapes.
    """
    writer.write(chr(34))
    var raw = s.as_bytes()
    var run = 0
    for i in range(len(raw)):
        var c = raw[i]
        if c >= Byte(0x20) and c != _QUOTE and c != _BACKSLASH:
            continue
        # Everything since the last escape goes out in one piece. A byte that
        # has to be escaped is ASCII, so the run either side of it ends on a
        # character boundary and slicing by byte is safe.
        if i > run:
            writer.write(s[byte=run:i])
        run = i + 1
        if c == _QUOTE:
            writer.write("\\", chr(34))
        elif c == _BACKSLASH:
            writer.write("\\\\")
        elif c == _NEWLINE:
            writer.write("\\n")
        elif c == _RETURN:
            writer.write("\\r")
        elif c == _TAB:
            writer.write("\\t")
        elif c == Byte(8):
            writer.write("\\b")
        elif c == Byte(12):
            writer.write("\\f")
        else:
            writer.write(
                "\\u00", _hex_digit(Int(c) >> 4), _hex_digit(Int(c) & 15)
            )
    if len(raw) > run:
        writer.write(s[byte = run : len(raw)])
    writer.write(chr(34))


def _hex_digit(v: Int) -> String:
    """One of the four digits of a `\\u` escape. Lower case, as Go writes
    them."""
    if v < 10:
        return chr(48 + v)
    return chr(87 + v)


def new_document() -> Document:
    """An empty document. Go has no counterpart.

    Worth having on its own so that a document can be made once and parsed into
    many times, which is the arrangement `reset` exists for.
    """
    return Document()


def parse[o: Origin](b: Span[Byte, o]) raises -> Document:
    """`b` as a document. Go's `Unmarshal` into an `any`.

    ```mojo
    from core.encoding.json import parse


    def total() raises -> Int64:
        var doc = parse("[1, 2, 3]".as_bytes())
        var root = doc.root()
        var sum = Int64(0)
        for i in range(len(root)):
            sum += root.at(i).as_number().int64()
        return sum
    ```

    Raises `ErrJSONSyntax` for bytes that are not one JSON value and nothing
    else, including nesting deeper than ten thousand, and `ErrJSONText` for a
    string holding bytes that are not UTF-8 or an escape naming half of a
    surrogate pair. Nothing else can fail.
    """
    var doc = Document()
    doc.parse_into(b)
    return doc^
