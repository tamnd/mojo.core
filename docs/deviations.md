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
| `for rec := range reader` | The `core.iter.Cursor` trait, an explicit `has_next` and `next` pair, for all fallible iteration | 7, `for` drops the error |
| `iter.Seq`, `iter.Seq2`, `iter.Pull` and `iter.Pull2` | Nothing. Range over func needs a storable closure, and a `Cursor` yielding a tuple covers what `Seq2` was for | 3 |
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
| A type assertion for an optional interface | Capability bits, declared on the trait so the static path can read them too | 1 |
| `io.SectionReader.Outer` returning the underlying `ReaderAt` with the offset and size | `outer()` returns the offset and size, and the source is the public field `r`, because a method cannot hand back a borrow of a field alongside two values | 1 |
| `io.Discard`, a package level variable | `Discard()`, a type with no fields, since there are no package level variables and nothing to construct anyway | no global mutable state |
| `io.NopCloser` returning an unexported type behind `io.ReadCloser` | `NopCloser[R]`, a named generic type, because there is no erased `ReadCloser` to hide it behind | 1 |
| `io.MultiReader` flattening a multi reader given to a multi reader | No flattening. The erased value's type is gone by the time it is seen, so there is nothing to recognise. | 1 |
| `io.WriterAt` documented as safe for parallel non overlapping writes | `write_at` takes `mut self`, so the borrow checker serialises calls on one value. The destination property survives; the parallelism is not expressible without interior mutability. | 5 |
| `bufio.Peek`, `ReadSlice`, `ReadLine` and `Scanner.Bytes` returning a view into the reader's own buffer | Owned bytes, copied out, everywhere | 5, a span does not keep its owner still |
| `bufio.Writer.AvailableBuffer`, an empty slice over the writer's spare capacity to be appended to and written back | Nothing. The same reason: the slice it hands out is invalidated by the next flush and nothing here would catch the use. | 5 |
| `bufio.SplitFunc`, and the closures people write for it | The `Splitter` trait, one method, with the receiver as the captured state | 3 |
| `Scanner.Split(f)`, a setter that panics if called after the first `Scan` | The splitter is a type parameter, fixed when the scanner is built, so the mistake cannot be written down | 3 |
| `Scanner.Buffer(buf []byte, max int)`, reusing an allocation across scanners | `buffer(size, max)`, a size rather than the memory, because the scanner would own the list and the caller could not have it back | no shared ownership |
| `bufio.Reader.Reset(r io.Reader)` with any other reader | `reset` takes another `R`. A caller swapping one kind of source for another wraps an `AnyReader` and resets that. | 1 |
| `bufio.NewReaderSize` handing back the argument unchanged when it is already a big enough `*Reader` | No unwrapping, because there is nothing to type assert against, so wrapping a buffered reader gives two buffers | 1 |
| `bufio.ScanRunes` substituting U+FFFD for a byte that is not valid UTF-8 | The offending byte is the token, one per byte. A token is a range of the input, so there is nowhere for bytes that are not in the input to come from; the advance is the same, so the token stream still lines up. | 5 |
| `bufio.ReadWriter`, two embedded pointers and no methods of its own | Two named fields and twenty forwarders written out. `buffered`, `size` and `reset` are not forwarded, because each means two things. | no promotion |
| `utf8.AppendRune(p, r)` returning the grown slice, because that is what `append` does | `append_rune(mut dst, r)` grows the list in place and returns the byte count instead, since two names for the same list is exactly what ownership forbids | no shared ownership |
| `init()` | Compile time initialisers and explicit registration | no `init` |
| Struct embedding with method promotion | Composition with explicit forwarding | no promotion |
| The `embed` directive | A tool that generates a Mojo source file from a directory | a directive is not a library |

Two of these cost far more than the rest. The compile time warning means every static check in this library is a warning that our linter promotes to an error inside this repository and that you see as a warning. The fixed stack means a task is not a goroutine even if the green thread work in M9.4 succeeds.

## Where this library is stricter or better

These are deviations too, because code written against Go's semantics may not port, and they are improvements.

| Go | This library |
| --- | --- |
| `Read` may return bytes and an error together, and every caller is told to handle the count before the error | A read that moved bytes returns them and does not raise, so `EOF` always arrives with a count of zero |
| A string builder copied after use panics through a runtime check | Not copyable, so the mistake does not compile |
| A mutex copied by value is caught by a separate analysis tool | Not copyable, so it does not compile |
| `io.MultiReader` returns a zero length read when a source in the middle is empty | The loop moves to the next source instead, so a caller never sees a zero without an error |
| `io.TeeReader` reads and writes, and a caller that ignored the error loses the bytes it already took | A write failure comes out of the read, because the bytes are already gone from the source by then |
| `io.WriteString` type asserts to `io.StringWriter` to avoid the copy that `[]byte(s)` makes | `String.as_bytes` is a borrow, so there is no copy to avoid and no assertion to make |
| A removed list element is a dangling pointer the documentation asks you not to use | An index and a generation counter, so a stale handle raises |
| `rows.Scan(&a, &b)` checks the column count at run time | `rows.scan[Int, String]()` checks it at compile time |
| `context.WithValue` stores `any` and reading it back is an unchecked assertion | `ctx.value[RequestID]()` returns an optional, and a mismatch does not compile |
| An unclosed row set or transaction leaks a connection until a finalizer runs | Not copyable, returns the connection in the destructor, and the transaction is a `with` block |
| `sync.Pool` is emptied by the garbage collector and documented as a cache | Deterministic. It holds what it is given, with an optional cap. |
| Interned values are freed when the collector proves them unreachable | Reference counted, so they are freed when the last handle goes |
| A file is closed by a finalizer if you forget | Closed by the destructor, a close error is reported rather than lost, and the linter warns on a written file dropped without an explicit close |
| Struct tags are unchecked strings that fail silently when misspelled | Validated against a grammar by the generator, and a bad one fails the build |
| The regexp engines are trusted to agree | Every pattern in the corpus runs through all applicable engines and the results have to be identical |
| `for s.Scan() {}` ends early and silently on a read failure, and `s.Err()` after the loop is what you were supposed to remember | A failure comes out of `has_next` as a raise. There is no `Err`, so there is nothing to forget. |
| `bufio.ReadSlice` on a full buffer returns the buffered bytes alongside `ErrBufferFull`, and a caller that handled the error first has dropped them | The bytes stay buffered. `read_bytes` on the same reader still returns the whole thing, so the recovery is one call rather than a merge. |
| `Scanner.Text` and `ReadString` on bytes that are not valid UTF-8 hand back a string containing them, because a Go string is bytes | Both raise. `Scanner.bytes` and `read_bytes` are the versions that never refuse, and they are what a caller reading unknown encodings wants anyway. |
| A split function returning a token that is not inside the data it was given cannot be checked, because the token is a slice and is inside by construction | The token is a pair of indices the split function chose, so the range is bounds checked and an off by one raises rather than handing out neighbouring bytes |
| `ErrFinalToken`, an error value that is not a failure and means stop after this token | `Split.last` and `Split.stop_here`, which are data. The error channel only ever carries failures. |
| `bufio` panics in three places: `Split` after scanning, `Buffer` after scanning, and a split function returning tokens without advancing | All three raise. The last one is `ErrNoProgress` after the same hundred empty tokens Go counts. |
| `utf8.ValidString` is the check you run before trusting a `string`, since a Go `string` is arbitrary bytes | A `String` is validated when it is built, so this answers `True` unless somebody went through the `unsafe_` constructor. The function stays precisely so that assertion has somewhere to be audited. |

Four of those are the same observation. Go documents a hazard and Mojo's type system removes it.

## Additions Go does not have

Nothing here is present because it seemed nice. Each one is either forced by an absence in Mojo or a response to a failure that keeps happening in Go's ecosystem.

| Addition | Why |
| --- | --- |
| `core.unicode.norm`, the four normalisation forms | In Go's extended text repository rather than its standard library. A library that cannot tell you two spellings of the same string are equal is unfinished. |
| `core.sync.chan` as a package | Go spells channels in the language. Mojo has no channel, select or go keyword. |
| `core.runtime.sched` as a package | Go's scheduler is its runtime. Ours is a library. |
| `core.runtime.box` as a package | Go's interface value is a type pointer and a data pointer allocated by its runtime. Mojo has no interface value at all, so the box is a library type and the vtable is written by hand. |
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
| `io.Pipe`, `io.PipeReader` and `io.PipeWriter` | Deferred to M4. Every method blocks until the other side arrives, which needs `core.sync`. `io.ErrClosedPipe` is already numbered so the sentinel does not move when the pipe lands. |
| `io.ReadAll` returning the bytes it did read alongside a failure | The failure alone. Copy into a buffer you own if the partial result matters; `errors.partial` still says how far it got. |
| `bufio.Scanner.Err` | Nothing to call, and nothing to remember. The failure came out of `has_next` at the moment it happened. |
| `io.CopyN` taking the destination's `read_from` fast path | It does not. Go gets there by wrapping the source in a `LimitReader`, which here would mean holding a borrowed reader in a field. Write `copy(dst, limit_reader(src^, n))` when you own the source. |

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
