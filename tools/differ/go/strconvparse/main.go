// Command strconvparse prints one line per generated string: the string, then
// what each of the five parsers made of it, either the exact bits of the answer
// or the name of the failure. The differ compares that against
// tools/differ/mojo/strconv_parse.mojo, which prints the same line, and the two
// files have to be read together.
//
// The strings are made rather than drawn from a table, and eight shapes make
// them: plain digits, a decimal with a point and an exponent, a hexadecimal
// float, the words for infinity and not a number, digits with underscores in
// them, outright junk, a few hundred digits at once, and a small mantissa with
// an exponent near the ends of the range. The last two reach the exact decimal
// path behind Eisel-Lemire, which is where a parser that is nearly right goes
// wrong.
//
// A failing field prints the failure and nothing else, because the other side
// raises and a raise carries no value, so Go's clamped infinity beside ErrRange
// has nothing to be compared with.
package main

import (
	"bufio"
	"errors"
	"flag"
	"fmt"
	"math"
	"os"
	"strconv"
)

// The stride between one input's seed and the next.
const gap = 2862933555777941757

const (
	digitAlphabet = "0123456789"
	hexAlphabet   = "0123456789abcdefABCDEF"
	junkAlphabet  = "0123456789abcdefxXpP+-._eE"
)

// The words Go's parser knows, and the spellings it refuses next to them.
var words = []string{
	"inf", "Inf", "INF", "+inf", "-inf",
	"infinity", "Infinity", "-INFINITY",
	"nan", "NaN", "NAN", "+nan",
}

// One splitmix64 step. The same three lines are in the Mojo program.
func mix(state uint64) uint64 {
	z := state + 0x9E3779B97F4A7C15
	z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9
	z = (z ^ (z >> 27)) * 0x94D049BB133111EB
	return z ^ (z >> 31)
}

// The shared source of choices. Every decision either program makes comes from
// next and the two make them in the same written order, which is the whole
// reason both sides produce the same string.
type stream struct{ state uint64 }

func (s *stream) next() uint64 {
	s.state = mix(s.state)
	return s.state
}

func (s *stream) below(n int) int {
	return int(s.next() % uint64(n))
}

func (s *stream) pick(alphabet string, n int) string {
	out := make([]byte, n)
	for i := 0; i < n; i++ {
		out[i] = alphabet[s.below(len(alphabet))]
	}
	return string(out)
}

func (s *stream) sign() string {
	switch s.below(3) {
	case 0:
		return "-"
	case 1:
		return "+"
	}
	return ""
}

// The string this input stands for. Eight shapes, one per branch.
func text(s *stream, shape int) string {
	switch shape {
	case 0:
		sign := s.sign()
		n := 1 + s.below(20)
		return sign + s.pick(digitAlphabet, n)
	case 1:
		sign := s.sign()
		whole := s.pick(digitAlphabet, 1+s.below(17))
		frac := s.pick(digitAlphabet, s.below(17))
		out := sign + whole + "." + frac
		if s.below(2) == 0 {
			mark := "E"
			if s.below(2) == 0 {
				mark = "e"
			}
			esign := s.sign()
			out += mark + esign + s.pick(digitAlphabet, 1+s.below(3))
		}
		return out
	case 2:
		sign := s.sign()
		whole := s.pick(hexAlphabet, 1+s.below(14))
		frac := s.pick(hexAlphabet, s.below(14))
		mark := "P"
		if s.below(2) == 0 {
			mark = "p"
		}
		esign := s.sign()
		exp := s.pick(digitAlphabet, 1+s.below(3))
		return sign + "0x" + whole + "." + frac + mark + esign + exp
	case 3:
		return words[s.below(len(words))]
	case 4:
		// Underscores, which Go allows between digits and only there, so half
		// of these are legal and half are the mistakes next door to legal.
		sign := s.sign()
		body := ""
		n := 1 + s.below(12)
		for i := 0; i < n; i++ {
			body += s.pick(digitAlphabet, 1)
			if i+1 < n && s.below(3) == 0 {
				body += "_"
			}
		}
		out := sign + body
		if s.below(4) == 0 {
			out = sign + "0x_" + body
		}
		return out
	case 5:
		return s.pick(junkAlphabet, 1+s.below(8))
	case 6:
		sign := s.sign()
		body := s.pick(digitAlphabet, 100+s.below(300))
		out := sign + body
		if s.below(2) == 0 {
			esign := s.sign()
			out += "e" + esign + s.pick(digitAlphabet, 1+s.below(3))
		}
		return out
	}
	sign := s.sign()
	mantissa := s.pick(digitAlphabet, 1+s.below(17))
	esign := s.sign()
	return sign + mantissa + "e" + esign + s.pick(digitAlphabet, 1+s.below(3))
}

// The name of a failure, which is what the other side has instead of a value.
func failure(err error) string {
	switch {
	case errors.Is(err, strconv.ErrSyntax):
		return "syntax"
	case errors.Is(err, strconv.ErrRange):
		return "range"
	}
	return "other"
}

func parseFloat(s string, bitSize int) string {
	f, err := strconv.ParseFloat(s, bitSize)
	if err != nil {
		return failure(err)
	}
	if bitSize == 32 {
		return fmt.Sprintf("%08X", math.Float32bits(float32(f)))
	}
	return fmt.Sprintf("%016X", math.Float64bits(f))
}

func parseInt(s string, base int) string {
	n, err := strconv.ParseInt(s, base, 64)
	if err != nil {
		return failure(err)
	}
	return fmt.Sprintf("%016X", uint64(n))
}

func parseUint(s string, base int) string {
	n, err := strconv.ParseUint(s, base, 64)
	if err != nil {
		return failure(err)
	}
	return fmt.Sprintf("%016X", n)
}

func main() {
	count := flag.Int("count", 10000, "how many strings to print")
	seed := flag.Int("seed", 1, "which stream of strings to print")
	flag.Parse()

	out := bufio.NewWriterSize(os.Stdout, 1<<20)
	defer out.Flush()

	for i := 0; i < *count; i++ {
		w := mix(uint64(*seed) + uint64(i)*gap + 1)
		s := &stream{state: w}
		in := text(s, int(w%8))

		fmt.Fprintf(out, "%s %s %s %s %s %s\n",
			in,
			parseFloat(in, 64),
			parseFloat(in, 32),
			parseInt(in, 10),
			parseInt(in, 0),
			parseUint(in, 0),
		)
	}
}
