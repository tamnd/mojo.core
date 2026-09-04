// Command fmtcases turns Go's fmtTests table into Mojo test code.
//
// This is the one harvest that cannot produce data. Everywhere else a Go table
// becomes a Mojo list and a loop walks it, which is what extract.go does. Here
// the format string is a compile time parameter, so there is no loop to write:
// each row has to become its own call, with its own instantiation of sprintf,
// and the output is code rather than a table.
//
// Two thirds of the table cannot come along and the reason is worth stating.
// Go's fmtTests holds `any`, so a row can be a pointer, a struct, a slice, a
// map, a channel, a Stringer, a type declared in the test file for the purpose,
// or a call. This library has no reflection and prints what it was handed, so a
// row whose value is not a literal has nothing to be ported to yet. What is
// left is every row whose value is a number, a string, a rune or a bool and
// whose text is valid UTF-8, which is 326 of the 811 and is where the verbs,
// the flags, the widths and the precisions actually live. The generated file
// carries the counts and the reasons at the top, so a Go release that changes
// the shape of the table shows up as a changed number rather than as quietly
// fewer tests.
//
// The literals are evaluated with go/constant rather than by handing them back
// to Go the way extract.go does. Copying fmt's test declarations into a program
// does not compile, because the table leans on methods declared in the same
// file and a copy that takes the types without the methods is not a package.
// go/constant is Go's own constant arithmetic, it is exact, and it is enough
// for the rows that survive the filter, so the round trip through a second
// process buys nothing here.
//
// Usage:
//
//	go run ./fmtcases -file $GOROOT/src/fmt/fmt_test.go
//
// The Mojo goes to stdout. tools/testgen/run.py is what calls this. It sits in
// a directory of its own because extract.go beside it is also a `package main`
// and two of those in one directory is not a thing Go tooling will read.
package main

import (
	"flag"
	"fmt"
	"go/ast"
	"go/constant"
	"go/parser"
	"go/token"
	"math"
	"os"
	"sort"
	"strings"
	"unicode/utf8"
)

// The Go types this harvest can carry, and what each is called in Mojo. A row
// whose value is anything else is left behind.
var mojoType = map[string]string{
	"int":     "Int",
	"int8":    "Int8",
	"int16":   "Int16",
	"int32":   "Int32",
	"int64":   "Int64",
	"uint":    "UInt",
	"uint8":   "UInt8",
	"uint16":  "UInt16",
	"uint32":  "UInt32",
	"uint64":  "UInt64",
	"byte":    "UInt8",
	"rune":    "Int32",
	"float32": "Float32",
	"float64": "Float64",
	"string":  "String",
	"bool":    "Bool",
}

// A row of Go's table, kept.
type row struct {
	format  string // the format string, as Go wrote it
	value   string // the Mojo expression for the value
	out     string // what Go prints
	comment string // the Go type, for the reader
}

// A run of rows under one of Go's own section comments.
type section struct {
	title string
	rows  []row
}

func main() {
	file := flag.String("file", "", "the fmt_test.go to read")
	flag.Parse()
	if *file == "" {
		fail("no -file given")
	}
	src, err := os.ReadFile(*file)
	if err != nil {
		fail(err.Error())
	}
	fset := token.NewFileSet()
	parsed, err := parser.ParseFile(fset, *file, src, parser.ParseComments)
	if err != nil {
		fail(err.Error())
	}
	table := find(parsed, "fmtTests")
	if table == nil {
		fail("fmtTests is not in this file, so the harvest would be silently empty")
	}
	sections, dropped := collect(fset, parsed, table)
	os.Stdout.WriteString(render(sections, dropped))
}

// find gives back the composite literal a package level var was declared with.
func find(f *ast.File, name string) *ast.CompositeLit {
	for _, decl := range f.Decls {
		gen, ok := decl.(*ast.GenDecl)
		if !ok || gen.Tok != token.VAR {
			continue
		}
		for _, spec := range gen.Specs {
			value, ok := spec.(*ast.ValueSpec)
			if !ok || len(value.Names) != 1 || value.Names[0].Name != name {
				continue
			}
			if len(value.Values) == 1 {
				if lit, ok := value.Values[0].(*ast.CompositeLit); ok {
					return lit
				}
			}
		}
	}
	return nil
}

// collect walks the table and keeps the rows that can be ported, grouped under
// the section comments Go's own table is divided by. It also gives back a count
// of why the rest were left, which the generated file states rather than hides.
func collect(fset *token.FileSet, f *ast.File, table *ast.CompositeLit) ([]section, map[string]int) {
	dropped := map[string]int{}
	var out []section
	current := section{title: "the first three"}

	for _, element := range table.Elts {
		lit, ok := element.(*ast.CompositeLit)
		if !ok || len(lit.Elts) != 3 {
			dropped["not a three element row"]++
			continue
		}
		if title, found := heading(fset, f, lit.Pos()); found {
			out = append(out, current)
			current = section{title: title}
		}
		kept, why := port(lit)
		if why != "" {
			dropped[why]++
			continue
		}
		current.rows = append(current.rows, kept)
	}
	return append(out, current), dropped
}

// heading gives the section comment immediately above a row, when there is one.
//
// Go's table is divided by comments like `// floats` and `// escaped strings`,
// which say what a run of rows is for better than anything this tool could
// invent. They become the names of the generated test functions, so a failure
// names the part of Go's table it came from.
func heading(fset *token.FileSet, f *ast.File, pos token.Pos) (string, bool) {
	line := fset.Position(pos).Line
	for _, group := range f.Comments {
		if fset.Position(group.End()).Line != line-1 {
			continue
		}
		text := strings.TrimSpace(group.Text())
		if text == "" || strings.Contains(text, "\n") {
			continue
		}
		return text, true
	}
	return "", false
}

// port turns one row into Mojo, or says why it cannot be.
func port(lit *ast.CompositeLit) (row, string) {
	format, ok := text(lit.Elts[0])
	if !ok {
		return row{}, "the format is not a literal"
	}
	want, ok := text(lit.Elts[2])
	if !ok {
		return row{}, "the expected output is not a literal"
	}

	kind, value := evaluate(lit.Elts[1])
	if kind == "" {
		return row{}, "the value is not a literal"
	}

	// A row that expects a marker is a row this library complains about while
	// the program is built, and the suite build treats a complaint of ours as
	// a failure. Those cases are asserted in tests/warnings, where the
	// complaint is expected and the marker is checked beside it.
	if strings.Contains(want, "%!") {
		return row{}, "expects an error marker"
	}
	// `%T` and `%p` need reflection and an address, and are waived in
	// docs/deviations.md rather than half implemented.
	if strings.Contains(format, "%T") || strings.Contains(format, "%p") {
		return row{}, "uses a verb this library waives"
	}
	if !utf8.ValidString(format) || !utf8.ValidString(want) {
		return row{}, "the format or the output is not valid UTF-8"
	}

	rendered, why := literal(kind, value)
	if why != "" {
		return row{}, why
	}
	return row{format: format, value: rendered, out: want, comment: kind}, ""
}

// text gives the string a literal expression is, when it is one.
func text(e ast.Expr) (string, bool) {
	lit, ok := e.(*ast.BasicLit)
	if !ok || lit.Kind != token.STRING {
		return "", false
	}
	value := constant.MakeFromLiteral(lit.Value, lit.Kind, 0)
	if value.Kind() != constant.String {
		return "", false
	}
	return constant.StringVal(value), true
}

// evaluate gives the Go type of a value expression and its constant value, or
// an empty type when the expression is not a literal this harvest can carry.
//
// The conversions matter as much as the literals. `uint8(3)` and `int64(3)` and
// a bare `3` are three different rows of Go's table printing three different
// type names inside a marker, and the conversion is the only thing that says
// which is which.
func evaluate(e ast.Expr) (string, constant.Value) {
	switch v := e.(type) {
	case *ast.BasicLit:
		value := constant.MakeFromLiteral(v.Value, v.Kind, 0)
		switch v.Kind {
		case token.INT:
			return "int", value
		case token.FLOAT:
			return "float64", value
		case token.CHAR:
			return "rune", value
		case token.STRING:
			return "string", value
		}
	case *ast.Ident:
		if v.Name == "true" || v.Name == "false" {
			return "bool", constant.MakeBool(v.Name == "true")
		}
	case *ast.UnaryExpr:
		if v.Op == token.SUB || v.Op == token.ADD {
			kind, value := evaluate(v.X)
			if kind == "" || value == nil {
				return "", nil
			}
			return kind, constant.UnaryOp(v.Op, value, 0)
		}
	case *ast.CallExpr:
		name, ok := v.Fun.(*ast.Ident)
		if !ok || len(v.Args) != 1 {
			return "", nil
		}
		if _, known := mojoType[name.Name]; !known {
			return "", nil
		}
		kind, value := evaluate(v.Args[0])
		if kind == "" || value == nil {
			return "", nil
		}
		return name.Name, value
	}
	return "", nil
}

// literal writes a Go constant as the Mojo that produces the same value.
func literal(kind string, value constant.Value) (string, string) {
	mojo, known := mojoType[kind]
	if !known {
		return "", "the value has a type this harvest does not carry"
	}
	switch kind {
	case "bool":
		if value.Kind() != constant.Bool {
			return "", "the value does not match its type"
		}
		if constant.BoolVal(value) {
			return "True", ""
		}
		return "False", ""
	case "string":
		// `string(0x110000)` is a row of Go's table and it is a conversion
		// from a number, not a string constant. Go turns an out of range rune
		// into the replacement character there, which is a rule about
		// conversions rather than about formatting, so the row is left behind
		// rather than reimplemented here.
		if value.Kind() != constant.String {
			return "", "the value is a conversion rather than a literal"
		}
		if !utf8.ValidString(constant.StringVal(value)) {
			return "", "the value is not valid UTF-8"
		}
		return fmt.Sprintf("String(%s)", quote(constant.StringVal(value))), ""
	case "float32", "float64":
		if value.Kind() != constant.Int && value.Kind() != constant.Float {
			return "", "the value does not match its type"
		}
		f, exact := constant.Float64Val(value)
		if math.IsInf(f, 0) && exact {
			return "", "the value does not fit a float"
		}
		// Written as bits with the decimal beside it, for the reason
		// tests/generated says at the top of every harvested file: Mojo
		// flushes a subnormal float literal to zero, and a table of expected
		// answers is the last place to find that out.
		if kind == "float32" {
			bits := math.Float32bits(float32(f))
			return fmt.Sprintf("_f32(0x%08X)", bits), ""
		}
		return fmt.Sprintf("_f64(0x%016X)", math.Float64bits(f)), ""
	}
	if value.Kind() != constant.Int {
		return "", "the value does not match its type"
	}
	if strings.HasPrefix(kind, "u") || kind == "byte" {
		n, ok := constant.Uint64Val(value)
		if !ok {
			return "", "the value does not fit its type"
		}
		return fmt.Sprintf("%s(%d)", mojo, n), ""
	}
	n, ok := constant.Int64Val(value)
	if !ok {
		return "", "the value does not fit its type"
	}
	return fmt.Sprintf("%s(%d)", mojo, n), ""
}

// quote writes a string as a Mojo literal.
//
// Only the characters that have to be escaped are escaped, so that a reviewer
// reading this against Go's source sees Go's own text. The bytes above ASCII
// are written as themselves, which is why the caller checks that the string is
// valid UTF-8 first: a `\x` escape of one byte of a rune would not be.
func quote(s string) string {
	var out strings.Builder
	out.WriteByte('"')
	for _, b := range []byte(s) {
		switch {
		case b == '"':
			out.WriteString("\\\"")
		case b == '\\':
			out.WriteString("\\\\")
		case b == '\n':
			out.WriteString("\\n")
		case b == '\t':
			out.WriteString("\\t")
		case b == '\r':
			out.WriteString("\\r")
		case b < 0x20 || b == 0x7F:
			fmt.Fprintf(&out, "\\x%02x", b)
		default:
			out.WriteByte(b)
		}
	}
	out.WriteByte('"')
	return out.String()
}

// name turns one of Go's section comments into a Mojo function name.
func name(title string) string {
	var out strings.Builder
	last := '_'
	for _, r := range strings.ToLower(title) {
		switch {
		case r >= 'a' && r <= 'z', r >= '0' && r <= '9':
			out.WriteRune(r)
			last = r
		default:
			if last != '_' {
				out.WriteByte('_')
				last = '_'
			}
		}
	}
	return strings.Trim(out.String(), "_")
}

// render writes the Mojo file.
func render(sections []section, dropped map[string]int) string {
	var out strings.Builder
	kept := 0
	for _, s := range sections {
		kept += len(s.rows)
	}
	total := kept
	for _, n := range dropped {
		total += n
	}

	fmt.Fprintf(&out, `"""Go's own fmt table, one call per row.

%d of the %d rows of Go's `+tick+`fmtTests`+tick+` are here. The rest cannot be ported
yet and the counts say why:

`, kept, total)
	reasons := make([]string, 0, len(dropped))
	for why := range dropped {
		reasons = append(reasons, why)
	}
	sort.Strings(reasons)
	for _, why := range reasons {
		fmt.Fprintf(&out, "- %d %s\n", dropped[why], why)
	}
	out.WriteString(`
The rows that expect an error marker are the ones to look at twice. They are
not skipped, they are moved: a wrong format string is a complaint while the
program is built, and the suite build treats any complaint of ours as a
failure. So they live in tests/warnings/fmt_table.mojo, which is built by a
tool that expects a complaint and checks Go's marker beside it. The three of
them whose verb is %p are waived rather than moved.

Each row is its own call because the format string is a compile time
parameter. There is no loop to write here, and the compiler walks every one of
these format strings while this file is built, which is also the largest test
this library has of the compile time parser itself.

The function names and the order are Go's, taken from the section comments in
its table, so a failure names the part of Go's table it came from.
"""

from std.memory import bitcast
from std.testing import assert_equal

from core.fmt import sprintf


def _f64(bits: UInt64) -> Float64:
    """The float64 those bits are."""
    return bitcast[DType.float64](bits)


def _f32(bits: UInt32) -> Float32:
    """The float32 those bits are."""
    return bitcast[DType.float32](bits)
`)

	used := map[string]int{}
	for _, s := range sections {
		if len(s.rows) == 0 {
			continue
		}
		fn := name(s.title)
		if fn == "" {
			fn = "rows"
		}
		used[fn]++
		if used[fn] > 1 {
			fn = fmt.Sprintf("%s_%d", fn, used[fn])
		}
		fmt.Fprintf(&out, "\n\ndef test_%s() raises:\n", fn)
		fmt.Fprintf(&out, "    \"\"\"Go's `%s`, %d rows.\"\"\"\n", s.title, len(s.rows))
		for _, r := range s.rows {
			fmt.Fprintf(
				&out,
				"    assert_equal(sprintf[%s](%s), %s)\n",
				quote(r.format), r.value, quote(r.out),
			)
		}
	}
	return out.String()
}

// This file is a Go program and the Mojo it writes wants backticks in its
// docstrings, so every backtick emitted comes from here.
const tick = "`"

func fail(why string) {
	fmt.Fprintln(os.Stderr, "fmtcases: "+why)
	os.Exit(1)
}
