"""Changing case. Go's `strings.ToUpper`, `ToLower`, `ToTitle` and the three
special cases.

Six functions, all of them `core.bytes` doing the mapping and this file putting
a `String` around the answer. The result is owned rather than a view, which it
has to be: upper casing U+0250 gives U+2C6F and grows a byte, lower casing
U+2C6D gives U+0251 and loses one, so there is no offset arithmetic that could
turn the answer back into a slice of the input.

The `String` is built with `from_utf8_lossy`, which never fails and therefore
keeps these functions non-raising exactly as Go has them. The lossy part is
unreachable: the input is a `StringSlice` and so is valid UTF-8, and every case
mapping takes a valid rune to a valid rune. `core.bytes` would produce U+FFFD
for an invalid byte anyway, which is itself valid, so there is no input to this
package for which the substitution can fire.

`to_title` is rune-wise title casing, not the capitalise-each-word function.
Go's `strings.Title` is that one, it is deprecated in Go itself because its
word boundary rule turns "they're" into "They'Re", and it is waived here.
"""

import core.bytes.casing as bc
from core.unicode import SpecialCase


def to_upper[o: ImmOrigin](s: StringSlice[o]) -> String:
    """`s` with every rune upper cased. Go's `strings.ToUpper`.

    ```mojo
    from core.strings import to_upper

    print(to_upper("go"))  # => GO
    ```

    One rune in, one rune out, so the German ß upper cases to ß and not to SS.
    That expansion is full case mapping, which needs the Unicode text tables
    neither library carries, and Go answers the same way.
    """
    return String(from_utf8_lossy=Span(bc.to_upper(s.as_bytes())))


def to_lower[o: ImmOrigin](s: StringSlice[o]) -> String:
    """`s` with every rune lower cased. Go's `strings.ToLower`."""
    return String(from_utf8_lossy=Span(bc.to_lower(s.as_bytes())))


def to_title[o: ImmOrigin](s: StringSlice[o]) -> String:
    """`s` with every rune title cased. Go's `strings.ToTitle`.

    Every rune, not the first letter of every word, so `" aaa aaa "` becomes
    `" AAA AAA "`. Title case differs from upper case only for the few dozen
    digraphs: U+01C6 dž upper cases to U+01C4 DŽ and title cases to U+01C5 Dž,
    the form with one capital, and those runes are the entire reason this is a
    separate function.
    """
    return String(from_utf8_lossy=Span(bc.to_title(s.as_bytes())))


def to_upper_special[o: ImmOrigin](c: SpecialCase, s: StringSlice[o]) -> String:
    """`s` upper cased under `c`. Go's `strings.ToUpperSpecial`.

    ```mojo
    from core.strings import to_upper_special
    from core.unicode import TurkishCase

    print(to_upper_special(TurkishCase(), "istanbul"))  # => İSTANBUL
    ```

    A rune the special case says nothing about is mapped the ordinary way, so
    this can be run over a whole document rather than over the letters somebody
    picked out of it.
    """
    return String(from_utf8_lossy=Span(bc.to_upper_special(c, s.as_bytes())))


def to_lower_special[o: ImmOrigin](c: SpecialCase, s: StringSlice[o]) -> String:
    """`s` lower cased under `c`. Go's `strings.ToLowerSpecial`.

    Turkish is the language these exist for: `I` lower cases to U+0131, the
    dotless small i, and without the special case it goes to plain `i` and the
    word changes.
    """
    return String(from_utf8_lossy=Span(bc.to_lower_special(c, s.as_bytes())))


def to_title_special[o: ImmOrigin](c: SpecialCase, s: StringSlice[o]) -> String:
    """`s` title cased under `c`. Go's `strings.ToTitleSpecial`."""
    return String(from_utf8_lossy=Span(bc.to_title_special(c, s.as_bytes())))
