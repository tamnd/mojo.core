// Command strconvfloats prints one line per generated float: the bits it was
// built from, the number written out in fourteen ways at 64 bits and four ways
// at 32, and then the shortest form read back. The differ compares that against
// tools/differ/mojo/strconv_floats.mojo, which prints the same line, and the two
// files have to be read together.
//
// -seed picks the stream and -count says how many. The floats are made rather
// than drawn from a table: a splitmix64 step per input, then one of four shapes
// chosen by two bits of it. Uniformly random bits are almost all enormous
// exponents, and the interesting failures are near one, near zero and on
// numbers a person would type, which is what the shapes are for.
package main

import (
	"bufio"
	"flag"
	"fmt"
	"math"
	"os"
	"strconv"
)

// The stride between one input's seed and the next. Knuth's multiplier, used
// here only because two adjacent seeds have to land far apart.
const gap = 2862933555777941757

// One splitmix64 step. The same three lines are in the Mojo program.
func mix(state uint64) uint64 {
	z := state + 0x9E3779B97F4A7C15
	z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9
	z = (z ^ (z >> 27)) * 0x94D049BB133111EB
	return z ^ (z >> 31)
}

// 10^n for n up to 18, by multiplication, which is exact that far.
func pow10(n int) float64 {
	out := float64(1)
	for i := 0; i < n; i++ {
		out *= 10
	}
	return out
}

// The float this word stands for. Four shapes, chosen by its low two bits.
// Shape 0 is the raw bits, shape 1 puts the exponent within 32 of one, shape 2
// clears the exponent, and shape 3 is a ratio of two integers.
func value(w uint64) float64 {
	shape := w & 3
	m := w & 0x800FFFFFFFFFFFFF
	switch shape {
	case 0:
		return math.Float64frombits(w)
	case 1:
		exp := 991 + ((w >> 52) & 63)
		return math.Float64frombits(m | (exp << 52))
	case 2:
		return math.Float64frombits(m)
	}
	return float64(w%1000000000000000000) / pow10(int((w>>60)%16))
}

// The float32 half of the line. Half the words give their top 32 bits straight
// to a float32 and half round the float64 above.
func half(w uint64, v float64) float64 {
	if w&1 == 0 {
		return float64(math.Float32frombits(uint32(w >> 32)))
	}
	return float64(float32(v))
}

type spec struct {
	fmt  byte
	prec int
}

func main() {
	count := flag.Int("count", 10000, "how many floats to print")
	seed := flag.Int("seed", 1, "which stream of floats to print")
	flag.Parse()

	// Every formatter in the package: shortest, fixed exponent, fixed point,
	// the shorter of the two, and hexadecimal.
	wide := []spec{
		{'b', -1}, {'e', -1}, {'e', 5}, {'E', 17},
		{'f', -1}, {'f', 0}, {'f', 8},
		{'g', -1}, {'g', 1}, {'g', 3}, {'G', 17},
		{'x', -1}, {'x', 3}, {'X', 13},
	}
	narrow := []spec{{'g', -1}, {'e', 9}, {'f', -1}, {'x', -1}}

	out := bufio.NewWriterSize(os.Stdout, 1<<20)
	defer out.Flush()

	for i := 0; i < *count; i++ {
		w := mix(uint64(*seed) + uint64(i)*gap + 1)
		v := value(w)
		h := half(w, v)

		fmt.Fprintf(out, "%016X", math.Float64bits(v))
		for _, s := range wide {
			fmt.Fprintf(out, " %s", strconv.FormatFloat(v, s.fmt, s.prec, 64))
		}
		for _, s := range narrow {
			fmt.Fprintf(out, " %s", strconv.FormatFloat(h, s.fmt, s.prec, 32))
		}

		// The shortest form read back, which is the one property no single
		// formatting check can see.
		shortest := strconv.FormatFloat(v, 'g', -1, 64)
		if back, err := strconv.ParseFloat(shortest, 64); err != nil {
			fmt.Fprint(out, " unreadable")
		} else {
			fmt.Fprintf(out, " %016X", math.Float64bits(back))
		}
		fmt.Fprintln(out)
	}
}
