// Command unicodetables prints the whole contents of Go's unicode tables, one
// line per range, for the differ to compare against ours.
//
// Where unicoderunes asks questions, this dumps the data behind them: every
// range of every table in Go's five maps, every case range, and every category
// alias. It is what turns "the predicates agree on the code points we tried"
// into "the tables are the same tables", and it is small, around seven and a
// half thousand lines, because a range covers many code points.
//
// -count and -seed are accepted and ignored. There is nothing generated here
// and nothing random, so a partial dump would only be a weaker check.
package main

import (
	"bufio"
	"flag"
	"fmt"
	"os"
	"sort"
	"unicode"
)

// The five maps, in the order they are printed, tagged so that a script and a
// category of the same name cannot collide and so that a divergence names the
// group it is in.
var groups = []struct {
	tag   string
	table map[string]*unicode.RangeTable
}{
	{"cat", unicode.Categories},
	{"script", unicode.Scripts},
	{"prop", unicode.Properties},
	{"foldcat", unicode.FoldCategory},
	{"foldscript", unicode.FoldScript},
}

func dump(out *bufio.Writer, name string, t *unicode.RangeTable) {
	fmt.Fprintf(out, "%s table %d %d %d\n", name, len(t.R16), len(t.R32), t.LatinOffset)
	for _, r := range t.R16 {
		fmt.Fprintf(out, "%s r16 %06X %06X %06X\n", name, r.Lo, r.Hi, r.Stride)
	}
	for _, r := range t.R32 {
		fmt.Fprintf(out, "%s r32 %06X %06X %06X\n", name, r.Lo, r.Hi, r.Stride)
	}
}

func main() {
	flag.Int("count", 0, "accepted and ignored, the dump is always whole")
	flag.Int("seed", 0, "accepted and ignored, there is nothing random here")
	flag.Parse()

	out := bufio.NewWriterSize(os.Stdout, 1<<20)
	defer out.Flush()

	for _, group := range groups {
		names := make([]string, 0, len(group.table))
		for name := range group.table {
			names = append(names, name)
		}
		sort.Strings(names)
		for _, name := range names {
			dump(out, group.tag+":"+name, group.table[name])
		}
	}

	for i, c := range unicode.CaseRanges {
		fmt.Fprintf(out, "case %04d %06X %06X %+07d %+07d %+07d\n",
			i, c.Lo, c.Hi, c.Delta[unicode.UpperCase],
			c.Delta[unicode.LowerCase], c.Delta[unicode.TitleCase])
	}

	aliases := make([]string, 0, len(unicode.CategoryAliases))
	for long := range unicode.CategoryAliases {
		aliases = append(aliases, long)
	}
	sort.Strings(aliases)
	for _, long := range aliases {
		fmt.Fprintf(out, "alias %s %s\n", long, unicode.CategoryAliases[long])
	}
}
