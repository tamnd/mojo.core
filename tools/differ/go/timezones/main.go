// Command timezones prints every answer Go's time package gives about an
// instant in a real time zone, one line each, for the differ to compare
// against ours.
//
// The four locations are the four slim TZif files vendored under
// tests/data/go-time, read here with the same LoadLocationFromTZData both
// sides use, so neither side touches the host's zone database and the check is
// the same on a machine with no /usr/share/zoneinfo at all.
//
// -count is how many instants to print and -seed picks the stream. The instant
// is a splitmix64 word folded into 1880 to 2120, which is wide enough to reach
// the local mean time zone at the front of every file and the trailing POSIX
// rule at the back of the slim ones, and dense enough near now that most lines
// land in the part of the table that has real transitions in it.
//
// Every line holds the location, the instant, the fields the location's clock
// gives, the zone name and offset, both zone bounds, the String form, the
// wall clock reading turned back into an instant by Date, and the same date a
// month later. tools/differ/mojo/time_zones.mojo prints the same line and the
// two files have to be read together.
package main

import (
	"bufio"
	"flag"
	"fmt"
	"os"
	"time"
)

// The stride between one instant's seed and the next. Knuth's multiplier, used
// here only because two adjacent seeds have to land far apart.
const gap = 2862933555777941757

// The window the instants fall in, as Unix seconds: 1880-01-01 to 2120-01-01.
// Before the first is a range no zone file describes and after the last is a
// range only the trailing rule does, and both ends are worth reaching.
const (
	first = -2840140800
	last  = 4733510400
)

// One splitmix64 step. The same three lines are in the Mojo program.
func mix(state uint64) uint64 {
	z := state + 0x9E3779B97F4A7C15
	z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9
	z = (z ^ (z >> 27)) * 0x94D049BB133111EB
	return z ^ (z >> 31)
}

// The four files, in the order the Mojo program has them, since the low bits
// of each word pick between them by index. The paths climb out of the module
// directory because `go run -C tools/differ/go` is what starts this, so the
// working directory is that module and not the repository root.
var files = []struct {
	name string
	path string
}{
	{"Europe/Berlin", "../../../tests/data/go-time/2020b_Europe_Berlin"},
	{"America/Nuuk", "../../../tests/data/go-time/2021a_America_Nuuk"},
	{"Asia/Gaza", "../../../tests/data/go-time/2021a_Asia_Gaza"},
	{"Europe/Dublin", "../../../tests/data/go-time/2021a_Europe_Dublin"},
}

// A bound as the line writes it: the Unix second, or `none` where the zone has
// no bound on that side. Go leaves the zero Time there and so do we, and the
// word is written out rather than printing the zero time's Unix second,
// because that number looks like an answer and is not one.
func bound(t time.Time) string {
	if t.IsZero() {
		return "none"
	}
	return fmt.Sprintf("%d", t.Unix())
}

func main() {
	count := flag.Int("count", 10000, "how many instants to print")
	seed := flag.Int("seed", 1, "which stream of instants to print")
	flag.Parse()

	locs := make([]*time.Location, len(files))
	for i, f := range files {
		data, err := os.ReadFile(f.path)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		loc, err := time.LoadLocationFromTZData(f.name, data)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		locs[i] = loc
	}

	out := bufio.NewWriterSize(os.Stdout, 1<<20)
	defer out.Flush()

	for i := 0; i < *count; i++ {
		w := mix(uint64(*seed) + uint64(i)*gap + 1)
		which := int(w & 3)
		sec := first + int64((w>>2)%uint64(last-first))

		loc := locs[which]
		t := time.Unix(sec, 0).In(loc)
		name, offset := t.Zone()
		start, end := t.ZoneBounds()

		year, month, day := t.Date()
		hour, min, s := t.Clock()

		// The wall clock reading put back through Date, which is the inverse
		// of everything above it and the one that goes wrong on the hours
		// daylight saving skips or repeats.
		back := time.Date(year, month, day, hour, min, s, 0, loc)

		fmt.Fprintf(out, "%s %d %04d-%02d-%02d %02d:%02d:%02d %s %d %s %d %s %s %d | %s | %s\n",
			files[which].name,
			sec,
			year, int(month), day,
			hour, min, s,
			t.Weekday(),
			t.YearDay(),
			name,
			offset,
			bound(start),
			bound(end),
			back.Unix(),
			t.String(),
			t.AddDate(0, 1, 0).String(),
		)
	}
}
