// Command strconvfloat32 writes every float32 there is out and reads it back,
// printing one line per block of 2^20 of them: a hash of everything the
// formatter produced in the block and the number of round trips that did not
// come back to the bits they started as. 4096 blocks is all 4,294,967,296 of
// them, which is what the nightly run does.
//
// A hash rather than the strings themselves, because the strings are two
// hundred gigabytes and the question being asked of them is only whether the
// two sides agree. The differ compares this against
// tools/differ/mojo/strconv_float32.mojo, which prints the same line.
//
// -seed is accepted and ignored: there is nothing random about an enumeration,
// and starting at zero every time is what makes a divergence reproducible from
// the line that reports it.
package main

import (
	"bufio"
	"flag"
	"fmt"
	"math"
	"os"
	"strconv"
)

const (
	block  = 1 << 20 // floats per line
	blocks = 1 << 12 // blocks in the whole enumeration

	fnvOffset = 14695981039346656037
	fnvPrime  = 1099511628211
)

func main() {
	count := flag.Int("count", blocks, "how many blocks of 2^20 floats to check")
	flag.Int("seed", 0, "accepted and ignored, the run always starts at zero")
	flag.Parse()

	out := bufio.NewWriterSize(os.Stdout, 1<<16)
	defer out.Flush()

	// Reused across the whole run. AppendFloat writes into it rather than
	// allocating a string per float, which is four billion allocations saved.
	buf := make([]byte, 0, 32)

	for b := 0; b < *count && b < blocks; b++ {
		hash := uint64(fnvOffset)
		broken := 0
		start := uint32(b) * uint32(block)
		for step := 0; step < block; step++ {
			bits := start + uint32(step)
			f := math.Float32frombits(bits)
			buf = strconv.AppendFloat(buf[:0], float64(f), 'g', -1, 32)

			// FNV-1a over the bytes of the shortest form, then one more round
			// over a zero byte, so that a boundary between two floats cannot
			// move without the hash noticing. Mixing a zero is the multiply on
			// its own, since the exclusive or with it changes nothing.
			for _, c := range buf {
				hash = (hash ^ uint64(c)) * fnvPrime
			}
			hash = hash * fnvPrime

			// The round trip. A NaN comes back as some NaN rather than as the
			// same one, so the payload is not part of the question.
			v, err := strconv.ParseFloat(string(buf), 32)
			back := float32(v)
			switch {
			case err != nil:
				broken++
			case f != f:
				if back == back {
					broken++
				}
			case math.Float32bits(back) != bits:
				broken++
			}
		}
		fmt.Fprintf(out, "%04X %016X %d\n", b, hash, broken)
		out.Flush()
	}
}
