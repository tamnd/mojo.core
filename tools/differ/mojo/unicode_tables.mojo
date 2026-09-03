"""Our side of the `unicode-tables` differ area.

Where `unicode_runes.mojo` asks questions, this dumps the data behind them:
every range of every table in the five maps, every case range, and every
category alias. That is what turns "the predicates agreed on the code points we
tried" into "the tables are the same tables". `tools/differ/go/unicodetables`
prints the same lines from Go.

`--count` and `--seed` are accepted and ignored. Nothing here is generated and
nothing is random, so a partial dump would only be a weaker check.
"""

from core import unicode
from core.unicode import RangeTable


def _hex(value: Int, width: Int) -> String:
    """`value` in upper case hexadecimal, zero padded to `width`, as Go's `%0*X`."""
    var digits = String(hex(value)[byte=2:]).upper()
    var out = String()
    for _ in range(width - digits.byte_length()):
        out += "0"
    out += digits
    return out


def _decimal(value: Int, width: Int) -> String:
    """`value` zero padded to `width`, as Go's `%0*d`."""
    var digits = String(value)
    var out = String()
    for _ in range(width - digits.byte_length()):
        out += "0"
    out += digits
    return out


def _signed(value: Int, width: Int) -> String:
    """`value` with its sign and zero padded to `width`, as Go's `%+0*d`.

    The sign counts towards the width, which is what Go's verb does and the
    kind of detail that makes every line of a dump differ when it is wrong.
    """
    var digits = String(abs(value))
    var out = String("+") if value >= 0 else String("-")
    for _ in range(width - 1 - digits.byte_length()):
        out += "0"
    out += digits
    return out


def _sorted(var names: List[String]) -> List[String]:
    """The names in byte order, which is what Go's `sort.Strings` gives."""
    sort(names)
    return names^


def _dump(name: String, table: RangeTable) raises -> String:
    """One table: a header line with the three counts, then a line per range."""
    var out = String(name)
    out += " table "
    out += String(table.r16_len())
    out += " "
    out += String(table.r32_len())
    out += " "
    out += String(table.latin_offset)
    out += "\n"
    for index in range(table.r16_len()):
        var r = table.r16(index)
        out += name
        out += " r16 "
        out += _hex(Int(r.lo), 6)
        out += " "
        out += _hex(Int(r.hi), 6)
        out += " "
        out += _hex(Int(r.stride), 6)
        out += "\n"
    for index in range(table.r32_len()):
        var r = table.r32(index)
        out += name
        out += " r32 "
        out += _hex(Int(r.lo), 6)
        out += " "
        out += _hex(Int(r.hi), 6)
        out += " "
        out += _hex(Int(r.stride), 6)
        out += "\n"
    return out


def _group(tag: String, tables: Dict[String, RangeTable]) raises -> String:
    """One of the five maps, tagged so a script and a category cannot collide."""
    var names = List[String]()
    for name in tables.keys():
        names.append(name)
    var out = String()
    for name in _sorted(names^):
        out += _dump(tag + ":" + name, tables[name])
    return out


def main() raises:
    var out = String()
    out += _group("cat", unicode.Categories())
    out += _group("script", unicode.Scripts())
    out += _group("prop", unicode.Properties())
    out += _group("foldcat", unicode.FoldCategory())
    out += _group("foldscript", unicode.FoldScript())

    var cases = unicode.CaseRanges()
    for index in range(len(cases)):
        var row = cases[index]
        out += "case "
        out += _decimal(index, 4)
        out += " "
        out += _hex(Int(row.lo), 6)
        out += " "
        out += _hex(Int(row.hi), 6)
        out += " "
        out += _signed(Int(row.delta[unicode.UPPER_CASE]), 7)
        out += " "
        out += _signed(Int(row.delta[unicode.LOWER_CASE]), 7)
        out += " "
        out += _signed(Int(row.delta[unicode.TITLE_CASE]), 7)
        out += "\n"

    var aliases = unicode.CategoryAliases()
    var longs = List[String]()
    for long in aliases.keys():
        longs.append(long)
    for long in _sorted(longs^):
        out += "alias "
        out += long
        out += " "
        out += aliases[long]
        out += "\n"

    print(out, end="")
