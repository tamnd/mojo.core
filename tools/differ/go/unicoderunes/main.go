// Command unicoderunes prints every answer Go's unicode package gives about a
// run of code points, one line each, for the differ to compare against ours.
//
// -count is how many code points to print, always starting at zero, so the
// nightly run passes 1114112 and covers every code point there is. -seed is
// accepted and ignored: there is nothing random about a character database,
// and starting at zero every time is what makes the differ's case index the
// code point that diverged.
//
// The line is the code point, a bitmask of the thirteen predicates, and then
// the five mappings, all in upper case hexadecimal with fixed widths so that a
// difference lines up under the field it is in. tools/differ/mojo/
// unicode_runes.mojo prints the same line and the two files have to be read
// together.
package main

import (
	"bufio"
	"flag"
	"fmt"
	"os"
	"unicode"
)

// The predicate bits, in alphabetical order of Go's names so that the two
// sides can be checked against each other by reading rather than by trusting.
func mask(r rune) uint {
	bits := []bool{
		unicode.IsControl(r),
		unicode.IsDigit(r),
		unicode.IsGraphic(r),
		unicode.IsLetter(r),
		unicode.IsLower(r),
		unicode.IsMark(r),
		unicode.IsNumber(r),
		unicode.IsPrint(r),
		unicode.IsPunct(r),
		unicode.IsSpace(r),
		unicode.IsSymbol(r),
		unicode.IsTitle(r),
		unicode.IsUpper(r),
	}
	var out uint
	for i, set := range bits {
		if set {
			out |= 1 << uint(i)
		}
	}
	return out
}

func main() {
	count := flag.Int("count", 10000, "how many code points to print")
	flag.Int("seed", 0, "accepted and ignored, the run always starts at zero")
	flag.Parse()

	out := bufio.NewWriterSize(os.Stdout, 1<<20)
	defer out.Flush()

	for i := 0; i < *count; i++ {
		r := rune(i)
		if r > unicode.MaxRune {
			break
		}
		fmt.Fprintf(out, "%06X %04X %06X %06X %06X %06X %06X %06X\n",
			r,
			mask(r),
			unicode.ToUpper(r),
			unicode.ToLower(r),
			unicode.ToTitle(r),
			unicode.SimpleFold(r),
			unicode.TurkishCase.ToUpper(r),
			unicode.TurkishCase.ToLower(r),
		)
	}
}
