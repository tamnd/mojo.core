"""How long a string is, asked three ways. The replacement for Go's `len`.

Go's `len(s)` on a string is the byte count. It is written the same way as
`len` on a slice, it is O(1), and it is the wrong answer to almost every
question anybody asks it. `len(name) > 20` for a form field, `len(s) == 1` for
a single character, indexing at `len(s)/2` to split a label in half: all three
are bugs that only show up when somebody types a character outside ASCII, and
all three are common enough in Go code to be a genre.

Mojo makes `len(s)` a compile error and tells you to say which one you meant.
This library agrees with that and does not paper over it, so instead of one
function there are three, and choosing between them is the point:

- `count_bytes` is how much memory it takes and how far a byte offset can go.
  It is what every function in this package returns offsets in, and it is what
  a wire protocol with a length prefix wants.
- `count_runes` is how many code points there are. It is what Go's
  `utf8.RuneCountInString` answers and what a terminal-width estimate starts
  from.
- `count_graphemes` is how many characters a reader would say there are. It is
  what a length limit on a name field wants, and it is the only one of the
  three that answers 1 for a flag emoji or a family emoji.

The three disagree by a lot. `count_bytes` of "a👩‍👩‍👧‍👦é" is 28,
`count_runes` is 9 and `count_graphemes` is 3, which is one `a`, one family
built out of four people and three zero width joiners, and one `é`. A field
that allows twenty characters means twenty graphemes, and there is no reading
of that sentence under which it means twenty eight.

Only the first is O(1). `count_runes` is a scan and `count_graphemes` is a scan
with the grapheme break rules applied, so a loop that asks for either one on
every iteration is doing quadratic work, and the fix is the same as it is in
Go: ask once and keep the number.
"""


def count_bytes[o: ImmOrigin](s: StringSlice[o]) -> Int:
    """How many bytes `s` occupies. Go's `len(s)`, and O(1) as that is.

    This is the unit every offset in this package is in, so it is the one to
    compare an `index` result against and the one to bound `s[byte=i:j]` with.
    """
    return s.byte_length()


def count_runes[o: ImmOrigin](s: StringSlice[o]) -> Int:
    """How many code points `s` holds. Go's `utf8.RuneCountInString`.

    A scan, so hold the answer rather than asking for it in a loop.
    """
    return len(s.codepoints())


def count_graphemes[o: ImmOrigin](s: StringSlice[o]) -> Int:
    """How many user perceived characters `s` holds. Go has no equivalent.

    Go's answer to this lives in `golang.org/x/text` and is not in the standard
    library at all, so this is the one function in the package with no Go row
    behind it. It is here because it is the answer to the question people
    actually ask, and because leaving it out would mean every caller reaching
    for `count_runes` and getting a family emoji counted as seven.

    A scan with the Unicode grapheme cluster break rules applied, so it is the
    most expensive of the three by some distance.
    """
    return len(s.graphemes())
