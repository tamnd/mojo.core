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

Totals: **135 implemented** (8,900 symbols, plus generated `syscall` bindings), **41 excluded** (2,795 symbols).

## Foundations

Everything else depends on these, and they are the first three milestones.

| Go package | Symbols | `core` package | Verdict | Note |
| --- | --- | --- | --- | --- |
| `errors` | 7 | `core.errors` | Adapt | Go's `error` is an interface. Mojo has one string-shaped error type, so the payload travels beside the raise. [design](design.md). |
| `io` | 104 | `core.io` | Adapt | `Reader`/`Writer` become a trait plus an erased vtable. The single most important design here. [design](design.md). |
| `io/fs` | 90 | `core.io.fs` | Adapt | Same treatment; `fs.FS` is an interface. |
| `bufio` | 78 | `core.bufio` | Port | Composes over `core.io`, which is the proof that the erasure design works. |
| `bytes` | 99 | `core.bytes` | Port | `Buffer` and `Reader` plus the search functions. |
| `strings` | 82 | `core.strings` | Port | `Builder`, `Reader`, and the same function set over text. [design](design.md). |
| `strconv` | 43 | `core.strconv` | Port | Ryū for float formatting, Eisel-Lemire for parsing. Correctly-rounded both ways. |
| `unicode` | 309 | `core.unicode` | Port | Tables generated from the Unicode database by `tools/gen/unicode.py`, checked in and re-verified in CI. |
| `unicode/utf8` | 19 | `core.unicode.utf8` | Port | Operates on `Span[UInt8]`, not `String`, because the input is often invalid. |
| `unicode/utf16` | 7 | `core.unicode.utf16` | Port | |
| `cmp` | 4 | `core.cmp` | Adapt | Go's `cmp.Ordered` is a type constraint; Mojo's is a trait, which is a better fit. |
| `sort` | 40 | `core.sort` | Wrap | Over `std.builtin.sort`. Go's `sort.Interface` becomes a comparator function pointer plus context. |
| `slices` | 40 | `core.slices` | Port | Over `Span` and `List`. |
| `maps` | 10 | `core.maps` | Port | Over `Dict`. |
| `iter` | 4 | `core.iter` | Adapt | Go's range-over-func needs closures. The fallible-iteration rule in [design](design.md) governs this whole area. |
| `unique` | 3 | `core.unique` | Port | Interning. Needs the atomics from [design](design.md). |
| `weak` | 3 | `core.weak` | Adapt | Go's weak pointers assume a tracing collector. Here it is a weak count beside the strong one in the shared box. |
| `container/heap` | 11 | `core.container.heap` | Adapt | `heap.Interface` becomes a trait for the static path. |
| `container/list` | 21 | `core.container.list` | Port | Doubly linked list over an arena, per the recursive-struct constraint. |
| `container/ring` | 10 | `core.container.ring` | Port | Same. |

## Numbers and time

| Go package | Symbols | `core` package | Verdict | Note |
| --- | --- | --- | --- | --- |
| `math` | 97 | `core.math` | Wrap | `std.math` covers most of it. `core.math` adds the missing IEEE-754 edges and Go's exact naming. |
| `math/bits` | 50 | `core.math.bits` | Wrap | Over `std.bit`. |
| `math/cmplx` | 27 | `core.math.cmplx` | Wrap | Over `std.complex`. |
| `math/big` | 166 | `core.math.big` | Port | `Int`, `Rat`, `Float`. Arbitrary precision, and the one place in `core` where Mojo's SIMD is worth reaching for on the limb loops. |
| `math/rand/v2` | 59 | `core.math.rand` | Port | PCG and ChaCha8, as Go has. Named without the `/v2` because there is no v1 to disambiguate from. |
| `math/rand` | 45 | none | Excluded | Superseded by v2 in Go itself. |
| `time` | 145 | `core.time` | Port | `Time`, `Duration`, `Month`, `Location`, monotonic readings, the whole format-layout language. [design](design.md). |
| `time/tzdata` | 0 | `core.time.tzdata` | Port | The IANA database, embedded. Zero exported symbols in Go; the package is its side effect. |

## Text

| Go package | Symbols | `core` package | Verdict | Note |
| --- | --- | --- | --- | --- |
| `fmt` | 43 | `core.fmt` | Adapt | Format strings are `comptime` parameters and verbs are typechecked at compile time. [design](design.md). |
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
| `syscall` | (per-platform) | `core.syscall` | Adapt | Generated from the host headers for macOS and Linux, arm64 and x86-64, by `tools/baseline/`. Go's manifests carry 6,233 names here across eleven platforms and ours is two platforms times two architectures, which are different enough that a percentage between them would mean nothing. Left out of the totals for that reason. |
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

Forty-one packages, 2,795 symbols. Each line is a reason, not an apology.

**Go's own language and toolchain (18).** `go/ast`, `go/build`, `go/build/constraint`, `go/constant`, `go/doc`, `go/doc/comment`, `go/format`, `go/importer`, `go/parser`, `go/printer`, `go/scanner`, `go/token`, `go/types`, `go/version` parse, typecheck and format Go source. `debug/gosym` and `debug/buildinfo` read metadata a Go linker writes. `plugin` and `runtime/cgo` are Go's linkage model. The Mojo analogue of all of this is the Mojo compiler, and it is Modular's to build. Note that `mojo doc` already emits structured JSON for Mojo source, and `tools/` uses it, so the capability these packages represent is present, just not as a `core` package.

**Go's runtime, and platforms Mojo does not build for (9).** `runtime` and `runtime/race` describe a scheduler and a race detector that are Go's; ours are `core.runtime.sched` and a ThreadSanitizer build flag. `runtime/coverage` is the Go toolchain's. `unsafe` and `structs` are language features, and Mojo's equivalents are `Pointer` and its layout controls. `embed` is a compiler directive; `tools/embed` generates a Mojo source file from a directory instead, which is the same capability with one more build step. `reflect` is discussed at length in [design](design.md) and [design](design.md) and is the reason nine packages are Adapt rather than Port. `debug/pe` and `debug/plan9obj` read object formats for Windows and Plan 9; Mojo targets neither, and both are mechanical additions the day it does.

**Deprecated by Go (6).** `io/ioutil` (moved into `io` and `os` in Go 1.16), `math/rand` (superseded by `math/rand/v2`), `crypto/dsa` (Go's own docs say do not use), `net/rpc` and `net/rpc/jsonrpc` (frozen), `crypto/mlkem/mlkemtest` (a helper for Go's tests).

**Already `mojo.httpx`'s (8).** `net/http`, `net/http/cgi`, `net/http/cookiejar`, `net/http/fcgi`, `net/http/httptest`, `net/http/httptrace`, `net/http/httputil`, `net/http/pprof`. `mojo.httpx` has a working HTTP/1.1 and HTTP/2 client with a cookie jar and a mock transport. Writing a second one here would split the ecosystem in exactly the way this project exists to prevent. The server side of `net/http` is genuinely missing from both projects; [design](design.md) argues it belongs in httpx, beside the client that shares its parser.

## How the contract is checked

Go's manifests are condensed into `tools/parity/goapi.txt` by `tools/gen/goapi.py`, which is checked in so that the tool works without Go installed, and regenerated in CI so that it cannot quietly stop matching. The Go release it was built from is in its header.

`tools/parity/` reads that index, takes the Go package each `PACKAGE.toml` names, applies the naming rules in `tools/parity/rules.py`, and compares the result against the symbols `mojo doc` reports for the package. It prints what is missing, what is extra, and what is present under a name the rules did not predict. `pixi run parity core.strings` does one package symbol by symbol, which is the list somebody porting it is owed.

The naming rules are three lines long. Types, constants and variables keep Go's name. Functions and methods become snake case. Members are written `Owner.member` on both sides, so a method cannot satisfy the contract by existing on the wrong type.

It runs in CI on every commit and its output is the coverage table in the README. A package is not "done" because somebody says so; it is done when `tools/parity` says it is at 100% and its tests pass.

The two escape hatches are explicit and both are files, not flags. `parity/waivers.toml` lists symbols deliberately not ported, one line each with a reason, and it is the machine-readable form of the Excluded section above for the cases too small to be a whole row. `parity/renames.toml` lists symbols whose Mojo name the rules could not derive, which is where `math.NaN` and `sync.RWMutex.RLock` live. Both are reviewed like code, both are checked for lines that no longer point at anything, and a growing waivers file is the signal that the contract is being negotiated away rather than met.
