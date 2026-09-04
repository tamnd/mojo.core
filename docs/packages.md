# Packages

This is the parity contract. Every one of Go 1.26's 176 non-internal, non-vendored packages has a row. Nothing says "partial".

Counts come from Go's own `api/go1.*.txt` manifests and are written into this table by `tools/gen/packages.py`, so no number here is typed from memory. A symbol is a top level declaration or a member of one, which means a method and an exported struct field each count, and a constant that exists on eleven platforms counts once.

They are the target, not an estimate of effort: `unicode`'s 309 symbols are mostly generated range tables and are a week's work, while `regexp`'s 49 are a matcher and are not.

## The four verdicts

| Verdict | Meaning |
| --- | --- |
| **Port** | Implemented in Mojo with Go's API shape, in Mojo's spelling. The translation rules in [design](design.md) are applied mechanically and the result is reviewable against Go's docs line by line. |
| **Adapt** | Implemented, but the shape changes because Mojo cannot express Go's. Reflection, interfaces in a container, or a captured closure. Every adaptation is argued in the owning section and recorded in [deviations](deviations.md). |
| **Wrap** | Mojo's `std`, or a system library, already does the work. `core` supplies Go's API over it and adds only what is missing. Gaps found in `std` are raised upstream rather than forked. |
| **Excluded** | Not implemented, with a reason about Go rather than about effort. |

Totals: **135 implemented** (8,914 symbols, plus generated `syscall` bindings), **41 excluded** (2,781 symbols).

## Foundations

Everything else depends on these, and they are the first three milestones.

| Go package | Symbols | `core` package | Verdict | Note |
| --- | --- | --- | --- | --- |
| `errors` | 7 | `core.errors` | Adapt | Go's `error` is an interface. Mojo has one string-shaped error type, so the payload travels beside the raise. [design](design.md). |
| `io` | 104 | `core.io` | Adapt | `Reader`/`Writer` become a trait plus an erased vtable, and Go's type assertion for optional interfaces becomes capability bits on the trait. The single most important design here. [design](design.md). `Pipe` waits for `core.sync`. |
| `io/fs` | 90 | `core.io.fs` | Adapt | Same treatment; `fs.FS` is an interface. |
| `bufio` | 78 | `core.bufio` | Port | Composes over `core.io`, which is the proof that the erasure design works. `Scanner` is a `core.iter.Cursor` so it has no `Err`, the split function is a trait rather than a closure, and nothing returns a view into the buffer. [deviations](deviations.md). |
| `bytes` | 99 | `core.bytes` | Port | `Buffer` and `Reader` plus the search functions. |
| `strings` | 82 | `core.strings` | Port | `Builder`, `Reader`, `Replacer` and the same function set over text, every one of them delegating to `core.bytes` rather than holding a second copy of the search code. There is no `len`: `count_bytes`, `count_runes` and `count_graphemes` are three names for the three answers. `Title` is waived, deprecated in Go. [deviations](deviations.md). |
| `strconv` | 43 | `core.strconv` | Port | Dragonbox for the shortest float that reads back, Eisel-Lemire for parsing, and the same big decimal as Go behind both. Correctly rounded either way, checked against Go byte for byte. All 43 symbols; `parse_complex` and `format_complex` work on Mojo's `ComplexFloat64` because Go's `complex128` is a language type. [deviations](deviations.md). |
| `unicode` | 309 | `core.unicode` | Adapt | Tables generated from the Unicode database by `tools/gen/unicode.py`, checked in and re-verified in CI. A `RangeTable` is a `comptime` constant naming a slice of one array rather than an object, so it cannot be built at run time, and Go's six maps are functions because a `Dict` cannot be a compile time value. [deviations](deviations.md). |
| `unicode/utf8` | 19 | `core.unicode.utf8` | Port | Operates on `Span[UInt8]`, not `String`, because the input is often invalid. Arithmetic only, no tables, which is why it lands with the foundations rather than with `core.unicode`. All 19 symbols, no waivers. |
| `unicode/utf16` | 7 | `core.unicode.utf16` | Port | |
| `cmp` | 4 | `core.cmp` | Adapt | Go's `cmp.Ordered` is a type constraint; Mojo's is a trait, which is a better fit. |
| `sort` | 40 | `core.sort` | Port | Was going to be a wrap over `std.builtin.sort`, and is not, because that sort hands the comparator indices from outside the span it was given when the comparator is inconsistent and Go's does not. Go's pdqsort and SymMerge, ported. `sort.Interface` is a trait taken as a generic parameter and a comparator is a compile time parameter. [deviations](deviations.md). |
| `slices` | 40 | `core.slices` | Port | Over `Span` and `List`, with the sorting delegated to `core.sort` so that there is one sort in this library and not two. |
| `maps` | 10 | `core.maps` | Adapt | Over `Dict`. `keys`, `values` and `all` return a list rather than an iterator, each with an `_into` sibling, and `insert` and `collect` take a span of pairs rather than a `Cursor`. All 10 symbols, no waivers. [deviations](deviations.md). |
| `iter` | 4 | `core.iter` | Adapt | All four of Go's symbols are range-over-func and need storable closures, so all four are waived. What is here instead is `Cursor`, the fallible-iteration rule in [design](design.md) written as a trait. |
| `unique` | 3 | `core.unique` | Port | Interning. Needs the atomics from [design](design.md). |
| `weak` | 3 | `core.weak` | Adapt | Go's weak pointers assume a tracing collector. Here it is a weak count beside the strong one in the shared box. |
| `container/heap` | 11 | `core.container.heap` | Adapt | `heap.Interface` becomes a trait for the static path. |
| `container/list` | 21 | `core.container.list` | Port | Doubly linked list over an arena, per the recursive-struct constraint. |
| `container/ring` | 10 | `core.container.ring` | Port | Same. |

## Numbers and time

| Go package | Symbols | `core` package | Verdict | Note |
| --- | --- | --- | --- | --- |
| `math` | 97 | `core.math` | Port | All 97 symbols, no waivers, and the thirty constants are renamed one line at a time. Was going to be a wrap over `std.math` and is half a port, because that library trades digits for speed and Go's tests are an accuracy contract: `erf` there is off by a hundred and seventy million parts in the last place where Go's tolerance is forty five. Nine functions are ported for accuracy, `sinh` and `tanh` because the system versions are wrong at a special value, the four Bessel functions keep the system library behind Go's special case switch, and nine had nothing to call. [deviations](deviations.md). |
| `math/bits` | 50 | `core.math.bits` | Wrap | All 50 symbols. Over `std.bit` for the counting and reversing and `UInt128` for the wide arithmetic, where Go carries byte tables and Knuth's algorithm D because its compiler intrinsifies them only on some architectures. The six division functions raise instead of panicking. [deviations](deviations.md). |
| `math/cmplx` | 27 | `core.math.cmplx` | Port | All 27 symbols, on `std.complex.ComplexFloat64`, which is Mojo's own type. Was going to be a wrap over that type and is a full port, because the type carries the four operators and a conjugate and none of the functions. Cephes by way of Go, with the C99 Annex G special case switches in front, which are most of the source. [deviations](deviations.md). |
| `math/big` | 166 | `core.math.big` | Port | `Int`, `Rat`, `Float`. Arbitrary precision. Done, with `Format` and `Scan` waived on all three types because they are Go's `fmt.Formatter` and `fmt.Scanner` and there is no run time verb here to hand them. Karatsuba for the wide multiplies, a divisor table for base conversion, Montgomery and a sliding window for the modular exponent, Baillie-PSW for the primality test. `Float` is correctly rounded under six modes and reports an accuracy after every operation. `Rat` keeps its denominator at one or more from the start, so Go's two helpers for an empty one have no counterpart. The destination argument every Go method takes is a return value instead, so a `Float`'s precision and mode come from its operands, and a panic is a raise. [deviations](deviations.md). |
| `math/rand/v2` | 59 | `core.math.rand` | Port | All 59 symbols, no waivers. PCG and ChaCha8, as Go has. Named without the `/v2` because there is no v1 to disambiguate from. Declares `unsafe`, and only `globals.mojo` is: the top level functions need a generator that is per thread and outlives the call, which Mojo has nowhere to put, so it lives in the C slot in `core/errors/shim` and is seeded through a raw `getentropy`. [deviations](deviations.md). |
| `math/rand` | 45 | none | Excluded | Superseded by v2 in Go itself. |
| `time` | 145 | `core.time` | Port | `Time`, `Duration`, `Month`, `Location`, monotonic readings, the whole format-layout language. [design](design.md). |
| `time/tzdata` | 0 | `core.time.tzdata` | Port | The IANA database, embedded. Zero exported symbols in Go; the package is its side effect. |

## Text

| Go package | Symbols | `core` package | Verdict | Note |
| --- | --- | --- | --- | --- |
| `fmt` | 43 | `core.fmt` | Adapt | Format strings are `comptime` parameters and verbs are typechecked at compile time. The compile time path is `sprintf`, `printf`, `fprintf` and `appendf`, with every verb, flag, width and precision Go has, argument indexes and `*` widths. A mismatch is named on the compiler's output at the call and then prints Go's exact marker. The runtime path is `vsprintf` and its siblings, for a format string nobody knew until the program ran, and all 326 of the ported rows of Go's own `fmtTests` pass byte for byte down both paths. The `Print` and `Sprint` families are here with Go's spacing rule. `%v` of a type this package never heard of has three answers rather than Go's one, because there is no reflection: `Writable` first, then the `Fields` trait, then a complaint and Go's marker. Still to come: `errorf`. `%T` and `%p` are waived. [design](design.md), [deviations](deviations.md). |
| `regexp` | 49 | `core.regexp` | Port | RE2 semantics: linear time, no backtracking, no catastrophic blowup. |
| `regexp/syntax` | 113 | `core.regexp.syntax` | Port | Parser, simplifier, compiler. Parse tree in an arena. |
| `text/scanner` | 41 | `core.text.scanner` | Port | |
| `text/tabwriter` | 12 | `core.text.tabwriter` | Port | |
| `text/template` | 39 | `core.text.template` | Adapt | Go evaluates against `any` via reflection. Here a template binds to a `core.encoding.json`-shaped dynamic value, or to a generated accessor table. [design](design.md). |
| `text/template/parse` | 219 | `core.text.template.parse` | Port | Arena again. |
| `html` | 2 | `core.html` | Port | |
| `html/template` | 60 | `core.html.template` | Adapt | The contextual auto-escaper, over the adapted `text/template`. |
| `index/suffixarray` | 7 | `core.index.suffixarray` | Port | |
| `mime` | 14 | `core.mime` | Port | |
| `mime/multipart` | 37 | `core.mime.multipart` | Port | |
| `mime/quotedprintable` | 8 | `core.mime.quotedprintable` | Port | |

## Encoding

| Go package | Symbols | `core` package | Verdict | Note |
| --- | --- | --- | --- | --- |
| `encoding` | 12 | `core.encoding` | Adapt | The marshaler interfaces become traits. |
| `encoding/json` | 68 | `core.encoding.json` | Adapt | Two paths: a dynamic arena document, and generated codecs for known struct shapes. [design](design.md). |
| `encoding/xml` | 82 | `core.encoding.xml` | Adapt | Same two paths. |
| `encoding/gob` | 17 | `core.encoding.gob` | Adapt | Wire format preserved exactly; the type registry is built at compile time instead of by reflection. |
| `encoding/binary` | 33 | `core.encoding.binary` | Port | Byte orders, varints, and a `Read`/`Write` that is generated rather than reflected. |
| `encoding/csv` | 32 | `core.encoding.csv` | Port | Fallible iteration, so `Reader.records()` is `has_next`/`next`. |
| `encoding/base64` | 22 | `core.encoding.base64` | Wrap | `std.base64` exists but is smaller than Go's. Extended, not forked. |
| `encoding/base32` | 19 | `core.encoding.base32` | Port | |
| `encoding/hex` | 15 | `core.encoding.hex` | Wrap | Over `std.base64`'s b16. |
| `encoding/ascii85` | 7 | `core.encoding.ascii85` | Port | |
| `encoding/asn1` | 51 | `core.encoding.asn1` | Adapt | DER. Reflection-driven in Go; generated here. Needed by `x509`. |
| `encoding/pem` | 7 | `core.encoding.pem` | Port | |

## Hashing and cryptography

Hashes and symmetric primitives are written in Mojo: they are pure computation, they are exactly what Mojo's SIMD is for, and they are testable to the bit against published vectors. The asymmetric stack, TLS and X.509 are bound to the OpenSSL that already ships inside the Mojo distribution, which is the decision `mojo.httpx` made and the reasoning is in [design](design.md).

| Go package | Symbols | `core` package | Verdict | Note |
| --- | --- | --- | --- | --- |
| `hash` | 32 | `core.hash` | Adapt | `hash.Hash` is an interface; trait plus erased vtable. |
| `hash/adler32` | 3 | `core.hash.adler32` | Port | |
| `hash/crc32` | 12 | `core.hash.crc32` | Port | Slicing-by-8, plus the hardware instruction where the target has it. |
| `hash/crc64` | 8 | `core.hash.crc64` | Port | |
| `hash/fnv` | 6 | `core.hash.fnv` | Port | |
| `hash/maphash` | 18 | `core.hash.maphash` | Wrap | Over `std.hashlib`. |
| `crypto` | 48 | `core.crypto` | Adapt | The registry of hash functions, without reflection. |
| `crypto/subtle` | 8 | `core.crypto.subtle` | Port | Constant-time primitives. Lint-guarded: no branch on secret data. |
| `crypto/md5` `sha1` `sha256` `sha512` `sha3` | 60 | `core.crypto.*` | Port | Native Mojo, vectorized, checked against NIST vectors. |
| `crypto/hmac` `hkdf` `pbkdf2` | 6 | `core.crypto.*` | Port | |
| `crypto/aes` `des` `rc4` `cipher` | 49 | `core.crypto.*` | Port | AES via the AES-NI/NEON instructions with a constant-time software fallback. |
| `crypto/rand` | 5 | `core.crypto.rand` | Port | `getrandom` on Linux, `getentropy` on macOS. Never the userspace PRNG. |
| `crypto/ed25519` `ecdh` `ecdsa` `elliptic` `rsa` | 160 | `core.crypto.*` | Wrap | OpenSSL-backed, Go's API shape. `elliptic`'s deprecated custom-curve entry points are excluded. |
| `crypto/mlkem` `hpke` | 79 | `core.crypto.*` | Wrap | OpenSSL 3.5 and later. Degrades with a clear error when the linked OpenSSL is older. |
| `crypto/fips140` | 4 | `core.crypto.fips140` | Adapt | Reports the mode of the OpenSSL provider rather than of a Go module. |
| `crypto/tls` | 259 | `core.crypto.tls` | Wrap | OpenSSL. Presents a `core.io` stream, so everything above it is protocol-agnostic. |
| `crypto/x509` | 254 | `core.crypto.x509` | Wrap | OpenSSL for chain building and verification; Go's API shape over it. |
| `crypto/x509/pkix` | 49 | `core.crypto.x509.pkix` | Port | Pure data types over `core.encoding.asn1`. |
| `crypto/dsa` | 20 | none | Excluded | Deprecated in Go. |
| `crypto/mlkem/mlkemtest` | 2 | none | Excluded | Test helper for Go's own suite. |

## Compression, archives, images

| Go package | Symbols | `core` package | Verdict | Note |
| --- | --- | --- | --- | --- |
| `compress/flate` | 31 | `core.compress.flate` | Port | The base everything else here needs. |
| `compress/gzip` | 28 | `core.compress.gzip` | Port | |
| `compress/zlib` | 20 | `core.compress.zlib` | Port | |
| `compress/bzip2` | 3 | `core.compress.bzip2` | Port | Decompression only, as in Go. |
| `compress/lzw` | 13 | `core.compress.lzw` | Port | Needed by `image/gif`. |
| `archive/tar` | 65 | `core.archive.tar` | Port | Fallible iteration over entries. |
| `archive/zip` | 68 | `core.archive.zip` | Port | |
| `image` | 273 | `core.image` | Adapt | `image.Image` is an interface; trait plus vtable. Most of the 281 are concrete pixel-format types. |
| `image/color` | 78 | `core.image.color` | Port | |
| `image/color/palette` | 2 | `core.image.color.palette` | Port | Generated tables. |
| `image/draw` | 23 | `core.image.draw` | Port | |
| `image/png` | 20 | `core.image.png` | Port | |
| `image/jpeg` | 13 | `core.image.jpeg` | Port | |
| `image/gif` | 19 | `core.image.gif` | Port | |

## Operating system

| Go package | Symbols | `core` package | Verdict | Note |
| --- | --- | --- | --- | --- |
| `os` | 214 | `core.os` | Port | Files, directories, environment, process. Over `core.syscall`, not over `std.os`, because `std.os` is much smaller and its error model is not this one. |
| `os/exec` | 49 | `core.os.exec` | Port | `posix_spawn` where available, `fork`/`exec` otherwise. |
| `os/signal` | 6 | `core.os.signal` | Port | The self-pipe trick, delivered onto a channel from [design](design.md). |
| `os/user` | 23 | `core.os.user` | Port | |
| `path` | 9 | `core.path` | Port | Slash paths. |
| `path/filepath` | 27 | `core.path.filepath` | Port | Host paths. Two platforms, so `Separator` is always `/`; the abstraction is kept for portability rather than deleted. |
| `syscall` | (per-platform) | `core.syscall` | Adapt | Constants and layouts generated from the host headers for macOS arm64, Linux x86-64 and Linux arm64 by `tools/baseline/` and `tools/gen/syscall.py`, and the calls over descriptors, paths and `struct stat` written over them. `open` and `fcntl` go through two wrappers in `core/syscall/shim/varargs.c`, because both are variadic in C and a variadic function cannot be called portably from Mojo. Go's manifests carry 6,233 names here across eleven platforms and ours is three, which are different enough that a percentage between them would mean nothing. Left out of the totals for that reason. |
| `runtime/debug` | 37 | `core.runtime.debug` | Adapt | Stack traces, build info, GC knobs that are no-ops with a documented reason. |
| `runtime/metrics` | 23 | `core.runtime.metrics` | Adapt | Reports the `core` scheduler's metrics, not Go's. |
| `runtime/pprof` | 19 | `core.runtime.pprof` | Port | The pprof wire format is a published protobuf schema, so profiles open in the standard tooling. |
| `runtime/trace` | 21 | `core.runtime.trace` | Adapt | Same reasoning, our own event set. |
| `debug/elf` | 1,800 | `core.debug.elf` | Port | Mostly generated constant tables. |
| `debug/macho` | 367 | `core.debug.macho` | Port | |
| `debug/dwarf` | 427 | `core.debug.dwarf` | Port | |

## Concurrency

The riskiest area in the project, specified in full in [design](design.md).

| Go package | Symbols | `core` package | Verdict | Note |
| --- | --- | --- | --- | --- |
| `sync` | 46 | `core.sync` | Port | `Mutex`, `RWMutex`, `WaitGroup`, `Once`, `Pool`, `Map`, `Cond`. |
| `sync/atomic` | 94 | `core.sync.atomic` | Port | On the compiler builtins verified in [design](design.md). |
| `context` | 21 | `core.context` | Port | Cancellation, deadlines, values. Values are typed keys, not `any`. |
| none | none | `core.sync.chan` | New | Channels and `select`. Go spells these in the language; Mojo has no `go`, `chan` or `select` keyword, so they are a package. |
| none | none | `core.runtime.sched` | New | The goroutine scheduler over `pthread`. |
| `testing/synctest` | 2 | `core.testing.synctest` | Port | A fake clock and a bubble, which is how the concurrency tests stay deterministic. |

## Networking

`core.net` stops where a protocol starts. HTTP is `mojo.httpx`'s.

| Go package | Symbols | `core` package | Verdict | Note |
| --- | --- | --- | --- | --- |
| `net` | 369 | `core.net` | Adapt | TCP, UDP, Unix, IP. `net.Conn` and `net.Listener` are interfaces; trait plus vtable. Includes the resolver, with Happy Eyeballs. |
| `net/netip` | 80 | `core.net.netip` | Port | The value-typed address API. Preferred over `net.IP` in new code, as Go now advises. |
| `net/url` | 60 | `core.net.url` | Port | WHATWG-conformant, checked against the Web Platform Tests corpus. |
| `net/textproto` | 62 | `core.net.textproto` | Port | |
| `net/mail` | 20 | `core.net.mail` | Port | |
| `net/smtp` | 27 | `core.net.smtp` | Port | |
| `net/http` and 7 subpackages | 545 | none | Excluded | `mojo.httpx`. [design](design.md) covers the boundary and the migration. |
| `net/rpc`, `net/rpc/jsonrpc` | 60 | none | Excluded | Frozen in Go, and reflection to its foundations. |

## Databases

| Go package | Symbols | `core` package | Verdict | Note |
| --- | --- | --- | --- | --- |
| `database/sql` | 157 | `core.database.sql` | Adapt | The pool, transactions and statements port. `Rows.Scan(&a, &b)` is reflection over `any` destinations; here the destinations are a typed pack. [design](design.md). |
| `database/sql/driver` | 115 | `core.database.sql.driver` | Adapt | Nine interfaces, all erased vtables. `driver.Value` is a tagged union rather than `any`. |

## Logging, flags, diagnostics

| Go package | Symbols | `core` package | Verdict | Note |
| --- | --- | --- | --- | --- |
| `log` | 43 | `core.log` | Port | |
| `log/slog` | 154 | `core.log.slog` | Adapt | Structured logging. `slog.Any` needs reflection; here an attribute value is a closed union of the types a log line can hold. |
| `log/syslog` | 43 | `core.log.syslog` | Port | Mostly the priority and facility constants. The real surface is a writer and four ways to open one. |
| `flag` | 90 | `core.flag` | Port | |
| `expvar` | 39 | `core.expvar` | Port | Exposes a `core.encoding.json` document rather than an HTTP handler, since HTTP is not here. |

## Testing

`std.testing` exists and is used. `core.testing` adds what Go has and Mojo does not: subtests, table tests, benchmarks with the iteration protocol, fuzzing, golden files, and the helpers.

| Go package | Symbols | `core` package | Verdict | Note |
| --- | --- | --- | --- | --- |
| `testing` | 168 | `core.testing` | Wrap | Over `std.testing`. |
| `testing/fstest` | 15 | `core.testing.fstest` | Port | |
| `testing/iotest` | 10 | `core.testing.iotest` | Port | The half-reader and error-reader that shake out `io` bugs. |
| `testing/quick` | 21 | `core.testing.quick` | Adapt | Property testing needs generators; without reflection they come from a trait a type implements or a generated one. |
| `testing/slogtest` | 2 | `core.testing.slogtest` | Port | |
| `testing/cryptotest` | 1 | `core.testing.cryptotest` | Port | |

## Excluded, in full

Forty-one packages, 2,781 symbols. Each line is a reason, not an apology.

**Go's own language and toolchain (18).** `go/ast`, `go/build`, `go/build/constraint`, `go/constant`, `go/doc`, `go/doc/comment`, `go/format`, `go/importer`, `go/parser`, `go/printer`, `go/scanner`, `go/token`, `go/types`, `go/version` parse, typecheck and format Go source. `debug/gosym` and `debug/buildinfo` read metadata a Go linker writes. `plugin` and `runtime/cgo` are Go's linkage model. The Mojo analogue of all of this is the Mojo compiler, and it is Modular's to build. Note that `mojo doc` already emits structured JSON for Mojo source, and `tools/` uses it, so the capability these packages represent is present, just not as a `core` package.

**Go's runtime, and platforms Mojo does not build for (9).** `runtime` and `runtime/race` describe a scheduler and a race detector that are Go's; ours are `core.runtime.sched` and a ThreadSanitizer build flag. `runtime/coverage` is the Go toolchain's. `unsafe` and `structs` are language features, and Mojo's equivalents are `Pointer` and its layout controls. `embed` is a compiler directive; `tools/embed` generates a Mojo source file from a directory instead, which is the same capability with one more build step. `reflect` is discussed at length in [design](design.md) and [design](design.md) and is the reason nine packages are Adapt rather than Port. `debug/pe` and `debug/plan9obj` read object formats for Windows and Plan 9; Mojo targets neither, and both are mechanical additions the day it does.

**Deprecated by Go (6).** `io/ioutil` (moved into `io` and `os` in Go 1.16), `math/rand` (superseded by `math/rand/v2`), `crypto/dsa` (Go's own docs say do not use), `net/rpc` and `net/rpc/jsonrpc` (frozen), `crypto/mlkem/mlkemtest` (a helper for Go's tests).

**Already `mojo.httpx`'s (8).** `net/http`, `net/http/cgi`, `net/http/cookiejar`, `net/http/fcgi`, `net/http/httptest`, `net/http/httptrace`, `net/http/httputil`, `net/http/pprof`. `mojo.httpx` has a working HTTP/1.1 and HTTP/2 client with a cookie jar and a mock transport. Writing a second one here would split the ecosystem in exactly the way this project exists to prevent. The server side of `net/http` is genuinely missing from both projects; [design](design.md) argues it belongs in httpx, beside the client that shares its parser.

## How the contract is checked

Go's manifests are condensed into `tools/parity/goapi.txt` by `tools/gen/goapi.py`, which is checked in so that the tool works without Go installed, and regenerated in CI so that it cannot quietly stop matching. The Go release it was built from is in its header.

`tools/parity/` reads that index, takes the Go package each `PACKAGE.toml` names, applies the naming rules in `tools/parity/rules.py`, and compares the result against the symbols `mojo doc` reports for the package. It prints what is missing, what is extra, and what is present under a name the rules did not predict. `pixi run parity core.strings` does one package symbol by symbol, which is the list somebody porting it is owed.

`mojo doc` reports declarations, and a name a package republishes for its users is an import rather than a declaration, so the tool reads the `from ... import` lines of each package's `__init__.mojo` and counts those too, in both the one line and the parenthesised multi-line spelling, because `mojo format` rewrites the first into the second as soon as the names stop fitting on a line. That is not a nicety: `core.io` exports `EOF`, `ErrShortWrite` and `ErrNoProgress`, which are declared in `core.errors.codes` because they come out of one generated table, and they are importable exactly as Go's `io.EOF` is. Only `__init__.mojo`, because that file is the package's public surface and an import anywhere else is a private dependency.

The naming rules are three lines long. Types, constants and variables keep Go's name. Functions and methods become snake case. Members are written `Owner.member` on both sides, so a method cannot satisfy the contract by existing on the wrong type.

It runs in CI on every commit and its output is the coverage table in the README. A package is not "done" because somebody says so; it is done when `tools/parity` says it is at 100% and its tests pass.

The two escape hatches are explicit and both are files, not flags. `parity/waivers.toml` lists symbols deliberately not ported, one line each with a reason, and it is the machine-readable form of the Excluded section above for the cases too small to be a whole row. `parity/renames.toml` lists symbols whose Mojo name the rules could not derive, which is where `math.NaN` and `sync.RWMutex.RLock` live. Both are reviewed like code, both are checked for lines that no longer point at anything, and a growing waivers file is the signal that the contract is being negotiated away rather than met.
