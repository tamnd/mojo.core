# Deviations

Every deliberate departure from Go, in one place, so that you can read the whole cost of the translation without assembling it from the package documentation.

This is the honest answer to the claim that nothing is missing. Every symbol in the implemented column of [packages.md](packages.md) is present. Not every one behaves identically, and the ones that do not are here. A deviation that is not on this page is a bug, so please report it.

Five categories, and the split matters. Forced is what Mojo would not let us do. Better is where Mojo let us do more than Go. Added is what Go lacks. Omitted is what we chose not to carry. Residue is the small set of aborts that survive.

## Forced by the language

Each row names the property of Mojo behind it. The numbers refer to sections of [design.md](design.md).

| Go | This library | Why |
| --- | --- | --- |
| `[]Reader` holding mixed implementations | An erased struct with a hand written vtable, plus a trait for the static path | 1, no trait objects |
| `sort.Slice` with a closure capturing the slice | A thin function pointer plus an explicit context, or a compile time projection | 3, no storable closures |
| `err.(*os.PathError)` | `os.PathError.of(e)` against a thread local record | 4, one string error type |
| `(n int, err error)` where both matter | A raise, with the count available through `errors.partial(e)` | 4 |
| An error held indefinitely as a value | Records live until the next raise on that thread, and `errors.capture` extends that | 4 |
| `errors.Is(err, io.EOF)` against a sentinel value | `errors.matches(e, io.EOF)` against a generated code, since there is no comparable error value to hold | 4 |
| `errors.Join(a, b)` keeping every error's fields | All of them over captured errors. Over live ones, every cause and every message but the fields of at most one. | 4 |
| Recursive types for JSON, regexp, templates and lists | Arenas of nodes with integer indices and generation counters | 5 |
| A usable zero value such as `var b bytes.Buffer` | An explicit constructor, everywhere | no zero value semantics |
| `for rec := range reader` | An explicit `has_next` and `next` pair for all fallible iteration | 7, `for` drops the error |
| `json.Unmarshal(data, &v)` by reflection | A dynamic document, or a codec generated at build time | 8, no reflection |
| A format verb mismatch reported at run time | Detected at compile time, reported as a warning, plus Go's exact runtime marker | 10, no static assert |
| `%v` printing arbitrary struct fields | Needs `Writable` or a generated codec, otherwise a warning and Go's marker | 8 |
| `FuncMap` mapping a name to an arbitrary function | Template functions have one fixed signature | 3 and 8 |
| `{{.User.FullName}}` calling a method | Works on the generated path only, not the dynamic document path | 8 |
| `go f(x)` capturing locals | `spawn[f](payload)`, one moved value carrying what a closure would have captured | 3 |
| A goroutine stack that grows | A fixed stack chosen at creation, with a guard page | no compiler support for stack copying |
| `defer mu.Unlock()` | `with mu.lock():`, released on every exit path including a raise | no `defer` |
| A package level `var` holding a registry, a cache or a default | A value the caller owns and passes, or storage outside Mojo for the one case that cannot | no global mutable state |
| `panic` and `recover` | `abort`, which cannot be caught. See the residue section. | no unwinding |
| `json.Marshal(v)` for a value of unknown type | Not available. Build a document, or use a type that has a codec. | 8 |
| `driver.Value` as `any` | A tagged union over the seven types Go's documentation allows | 1 |
| A type assertion for an optional interface | Capability bits on the erased vtable | 1 |
| `init()` | Compile time initialisers and explicit registration | no `init` |
| Struct embedding with method promotion | Composition with explicit forwarding | no promotion |
| The `embed` directive | A tool that generates a Mojo source file from a directory | a directive is not a library |

Two of these cost far more than the rest. The compile time warning means every static check in this library is a warning that our linter promotes to an error inside this repository and that you see as a warning. The fixed stack means a task is not a goroutine even if the green thread work in M9.4 succeeds.

## Where this library is stricter or better

These are deviations too, because code written against Go's semantics may not port, and they are improvements.

| Go | This library |
| --- | --- |
| A buffer's byte slice is invalidated by the next write, which is a documented hazard | The origin is tracked, so using it afterwards is a compile error |
| A string builder copied after use panics through a runtime check | Not copyable, so the mistake does not compile |
| A mutex copied by value is caught by a separate analysis tool | Not copyable, so it does not compile |
| A removed list element is a dangling pointer the documentation asks you not to use | An index and a generation counter, so a stale handle raises |
| `rows.Scan(&a, &b)` checks the column count at run time | `rows.scan[Int, String]()` checks it at compile time |
| `context.WithValue` stores `any` and reading it back is an unchecked assertion | `ctx.value[RequestID]()` returns an optional, and a mismatch does not compile |
| An unclosed row set or transaction leaks a connection until a finalizer runs | Not copyable, returns the connection in the destructor, and the transaction is a `with` block |
| `sync.Pool` is emptied by the garbage collector and documented as a cache | Deterministic. It holds what it is given, with an optional cap. |
| Interned values are freed when the collector proves them unreachable | Reference counted, so they are freed when the last handle goes |
| A file is closed by a finalizer if you forget | Closed by the destructor, a close error is reported rather than lost, and the linter warns on a written file dropped without an explicit close |
| Struct tags are unchecked strings that fail silently when misspelled | Validated against a grammar by the generator, and a bad one fails the build |
| The regexp engines are trusted to agree | Every pattern in the corpus runs through all applicable engines and the results have to be identical |

Five of those are the same observation. Go documents a hazard and Mojo's type system removes it.

## Additions Go does not have

Nothing here is present because it seemed nice. Each one is either forced by an absence in Mojo or a response to a failure that keeps happening in Go's ecosystem.

| Addition | Why |
| --- | --- |
| `core.unicode.norm`, the four normalisation forms | In Go's extended text repository rather than its standard library. A library that cannot tell you two spellings of the same string are equal is unfinished. |
| `core.sync.chan` as a package | Go spells channels in the language. Mojo has no channel, select or go keyword. |
| `core.runtime.sched` as a package | Go's scheduler is its runtime. Ours is a library. |
| `errors.capture` and `ErrorValue` | Go's errors are values with the lifetime of whoever holds them. Ours need an explicit capture to outlive the raise, to be stored, or to cross a thread. |
| `errors.partial` | Recovers the count from Go's count and error pair, which a raise would otherwise drop. |
| `errors.wrap` | Go spells wrapping as a `%w` verb inside `fmt.Errorf`, which needs a runtime format string. This is the operation on its own. |
| `errors.causes` | Go exposes the multiple cause case only as an `Unwrap() []error` method on a type it does not export, so a joined error's causes cannot be reached from outside. |
| `fmt.vprintf` and a runtime argument list | Go's `Printf` takes a runtime format string without noticing. Ours needs a second, slower entry point for that. |
| Archive extraction helpers that reject traversal by default | Go ships the dangerous primitive without a safe convenience, which is why the same path traversal bug has been found in hundreds of programs. |
| Pixel count limits on every image decoder | A decompression bomb is a 200 byte PNG. Go has a config call and no limit. |
| Scanning a row directly into a struct | Third party Go libraries exist to provide this over reflection. The generator already exists here. |
| A reference SQL driver, shipped rather than test only | We ship no real driver, so without this the package is untestable, and a driver author needs an example to write against. |
| A marker trait for values that may cross a thread boundary, enforced by the linter | Mojo has no send or sync marker. Go has neither and ships a race detector. We ship both. |
| Full memory ordering parameters on atomics | Go offers only sequential consistency. The library itself needs acquire and release. Sequential consistency stays the default. |
| A context on every blocking network operation | Go takes one only when dialling. |
| Separate sender and receiver handles for a channel | Dropping the last sender closes the channel, which removes the most common channel bug in Go. |
| Header, part count and body size limits on by default | Go added most of these after they turned out to be denial of service vectors. Starting with them is free. |

## Omissions

Things a Go programmer will look for and not find. This is separate from the 41 packages left out entirely, which are listed with a reason each in [packages.md](packages.md).

| Missing | Instead |
| --- | --- |
| `strings.Title` | Deprecated in Go itself. Use the case mapping with a Unicode aware word breaker. |
| A single `len` for a string | `count_bytes`, `count_runes` and `count_graphemes`. Mojo makes `len(s)` a compile error and it is right to. |
| `maps.Keys` returning an iterator | `keys()` returning a list, and `keys_into(out)`. Go's iterators are closures. |
| Go's iterator function types generally | Traits for iterable and fallible iterable. |
| Backreferences and lookaround in regexp | Linear time matching, as in Go. Not a deviation from Go, listed because it is the first thing people ask. |
| Encrypted zip entries | Not supported, matching Go. The old scheme is broken and the new one is not interoperably standardised. |
| Zstandard, Brotli and LZ4 | Not in Go's standard library. Candidates for a separate repository. |
| WebP, AVIF, TIFF and BMP | Same reason. |
| Arithmetic coded JPEG | Not supported, matching Go. |
| TLS 1.0 and 1.1 | Cannot be enabled. Go removed them and there is no reason to reintroduce them in a library written now. |
| Custom elliptic curve arithmetic | Deprecated in Go, and the route to invalid curve attacks. |
| Leap seconds | Matching Go and POSIX. A positive leap second repeats a second. |
| Anything Windows specific | Windows is not a Mojo target, so Go packages whose reason to exist is Windows portability lose it. |
| Placeholder rewriting between SQL dialects | Matching Go. A question mark stays a question mark. |
| Compile time compiled regular expressions | Deferred past 1.0 behind a benchmark gate. The API is shaped so it can be added later without changing anything else. |

## The abort residue

The rule is that nothing in this library aborts for a condition the caller could have checked. Go aborts on an out of range index, on a write to a nil map, and on compiling a bad pattern with `MustCompile`. Here indexing raises, nil maps do not exist, and the rest raises.

Eleven functions keep the abort. All eleven are `must_` prefixed, where aborting is precisely what the caller asked for by choosing that name over the fallible sibling:

`regexp.must_compile`, `regexp.must_compile_posix`, `template.must`, `html.template.must`, `netip.must_parse_addr`, `netip.must_parse_addr_port`, `netip.must_parse_prefix`, `time.must_load_location`, `big.Int.must_set_string`, `url.must_parse` and `sql.must_register`.

Plus `core.panic(message)` itself, which writes a message and a stack trace and then aborts.

This matters more here than it does in Go, because a Mojo program cannot catch an abort. Each one of these is a program somebody cannot make robust. So every one has a fallible sibling with the same behaviour and a raise, the documentation page for each names it, and the linter warns on a `must_` call whose argument is not a literal. A `must_` on a literal is a constant the programmer has asserted. A `must_` on a variable is a crash waiting for the right input.

## How this page stays true

A deviations list maintained by good intentions is a deviations list that is wrong within a month, so there are three mechanisms.

The waivers file is the machine readable form of the omissions section, one line per symbol with a reason, and it is diffed in review. A growing waivers file is the signal that the contract is being negotiated away rather than met.

Every package's documentation page has a mandatory section on how it differs from Go's package of the same name, and the documentation tool fails a page that omits it. The entries there and here come from the same source, so they cannot disagree.

And the language probes pin the facts behind the first table. When a Mojo release changes one, a probe fails and names the row. Two of those rows could plausibly disappear within the life of this project, which is why the deviations are written as consequences of numbered properties rather than as decisions somebody made.
