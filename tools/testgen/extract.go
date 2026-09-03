// Command extract turns Go's table driven test data into Mojo.
//
// Reading Go is go/ast's job and that is why this is a Go program rather than
// another thousand lines of regular expressions in the Python driver. But
// reading is only half of it. Go's tables are not literals, they are
// expressions: `Pi`, `NaN()`, `Float64frombits(0xFFF8000000000000)`,
// `append(ceilBaseSC, ...)`. A tool that only read the syntax would have to
// evaluate all of that itself, and an evaluator for a subset of Go is a thing
// that is subtly wrong for years.
//
// So this reads the declarations with go/ast and then hands them back to Go to
// evaluate. It copies the const, var and type declarations out of a package's
// test files into a temporary `package main`, writes a dump program
// beside them, and runs it. Go computes the values, reflection walks them, and
// the numbers that come out are the ones Go's own tests compare against,
// because Go is what produced them.
//
// Floats are written as bit patterns with the decimal beside them in a comment.
// That is not caution for its own sake: Mojo flushes a subnormal float literal
// to zero, so `4.9406564584124654e-324` in a source file is `0.0` by the time
// it is a `Float64`, and a table of expected answers is the last place that
// should be discovered. The comment is what a reviewer reads against Go's
// source; the bits are what the tests run on.
//
// Usage:
//
//	go run extract.go -package $GOROOT/src/math -tables acos,acosh,vfacosSC
//
// The Mojo goes to stdout. tools/testgen/run.py is what calls this, and it is
// where the plan lives and where the output is written.
package main

import (
	"bytes"
	"flag"
	"fmt"
	"go/ast"
	"go/parser"
	"go/printer"
	"go/token"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
)

func main() {
	dir := flag.String("package", "", "the Go package directory to read test tables from")
	list := flag.String("tables", "", "comma separated names of the tables to extract")
	flag.Parse()

	if *dir == "" || *list == "" {
		fmt.Fprintln(os.Stderr, "extract: -package and -tables are both required")
		os.Exit(2)
	}

	out, err := extract(*dir, strings.Split(*list, ","))
	if err != nil {
		fmt.Fprintf(os.Stderr, "extract: %v\n", err)
		os.Exit(1)
	}
	fmt.Print(out)
}

// extract reads one package's test files and gives back the Mojo for its tables.
func extract(dir string, tables []string) (string, error) {
	decls, imports, err := readDecls(dir)
	if err != nil {
		return "", err
	}

	declared := map[string]bool{}
	for _, name := range declaredNames(decls) {
		declared[name] = true
	}
	for _, want := range tables {
		if !declared[want] {
			return "", fmt.Errorf("%s has no test table named %s, so either the plan is stale or Go renamed it", filepath.Base(dir), want)
		}
	}

	work, err := os.MkdirTemp("", "testgen")
	if err != nil {
		return "", err
	}
	defer os.RemoveAll(work)

	if err := writeProgram(work, decls, imports, tables); err != nil {
		return "", err
	}

	cmd := exec.Command("go", "run", ".")
	cmd.Dir = work
	cmd.Stderr = os.Stderr
	cmd.Env = append(os.Environ(), "GOFLAGS=-mod=mod", "GO111MODULE=on")
	said, err := cmd.Output()
	if err != nil {
		return "", fmt.Errorf("the dump program failed, %v", err)
	}
	return string(said), nil
}

// readDecls collects the top level const, var and type declarations from a
// package's test files, and the imports they were written under.
//
// The external test files, the ones in `package foo_test`, are where the
// tables are looked for first, because they were written against the package
// from outside and they move as they are. A package like math/cmplx tests
// itself from the inside instead, and its tables are worth just as much, so
// when the external files declare nothing the in-package ones are read and the
// package under test is dot imported, which is what keeps `NaN()` in a table
// meaning what it meant in Go. A table that reaches an unexported identifier
// cannot survive that move, and the Go compiler says which one it was.
//
// Declaring nothing is the test rather than being absent, because a package
// can have an external test file that is only examples, as math/cmplx does.
//
// Every declaration is taken rather than only the requested ones. A table is
// routinely built out of another, `ceilSC` is `append(ceilBaseSC, ...)`, and
// following that would be a dependency walk this does not need to do: an
// unused package level variable is not an error in Go.
func readDecls(dir string) ([]ast.Decl, map[string]string, error) {
	paths, err := filepath.Glob(filepath.Join(dir, "*_test.go"))
	if err != nil {
		return nil, nil, err
	}
	sort.Strings(paths)

	fset := token.NewFileSet()
	files := map[bool][]*ast.File{}
	for _, path := range paths {
		file, err := parser.ParseFile(fset, path, nil, 0)
		if err != nil {
			return nil, nil, err
		}
		external := strings.HasSuffix(file.Name.Name, "_test")
		files[external] = append(files[external], file)
	}

	decls, imports := gather(files[true])
	if len(decls) == 0 {
		decls, imports = gather(files[false])
		if len(decls) == 0 {
			return nil, nil, fmt.Errorf("%s has no test files with tables in them", filepath.Base(dir))
		}
		path, err := importPath(dir)
		if err != nil {
			return nil, nil, err
		}
		imports[path] = "."
	}
	return decls, imports, nil
}

// gather takes the declarations and the imports out of a set of files.
func gather(files []*ast.File) ([]ast.Decl, map[string]string) {
	var decls []ast.Decl
	imports := map[string]string{}
	for _, file := range files {
		for _, decl := range file.Decls {
			gen, ok := decl.(*ast.GenDecl)
			if ok && gen.Tok != token.IMPORT {
				decls = append(decls, gen)
			}
		}
		for _, spec := range file.Imports {
			alias := ""
			if spec.Name != nil {
				alias = spec.Name.Name
			}
			imports[strings.Trim(spec.Path.Value, `"`)] = alias
		}
	}
	return decls, imports
}

// importPath is what the package under test is called from outside it.
//
// Every package this reads is under a Go source tree, so the path after the
// src directory is the import path. Asking the go tool for it would mean
// running it inside a read only module cache to learn something the path
// already says.
func importPath(dir string) (string, error) {
	clean := filepath.ToSlash(filepath.Clean(dir))
	at := strings.LastIndex(clean, "/src/")
	if at < 0 {
		return "", fmt.Errorf("%s is not under a Go source tree, so there is no import path to give the dump program", dir)
	}
	return clean[at+len("/src/"):], nil
}

// qualifiers lists the package names the copied declarations name, so that the
// imports which are still needed can be told from the ones that went with the
// functions that were left behind. Go refuses to compile an unused import, and
// dropping one that is used is the same kind of failure the other way round.
func qualifiers(decls []ast.Decl) map[string]bool {
	used := map[string]bool{}
	for _, decl := range decls {
		ast.Inspect(decl, func(n ast.Node) bool {
			if sel, ok := n.(*ast.SelectorExpr); ok {
				if ident, ok := sel.X.(*ast.Ident); ok {
					used[ident.Name] = true
				}
			}
			return true
		})
	}
	return used
}

// declaredNames lists what a set of declarations declares.
func declaredNames(decls []ast.Decl) []string {
	var out []string
	for _, decl := range decls {
		gen, ok := decl.(*ast.GenDecl)
		if !ok {
			continue
		}
		for _, spec := range gen.Specs {
			switch s := spec.(type) {
			case *ast.ValueSpec:
				for _, name := range s.Names {
					out = append(out, name.Name)
				}
			case *ast.TypeSpec:
				out = append(out, s.Name.Name)
			}
		}
	}
	return out
}

// writeProgram lays out the temporary module the tables are evaluated in.
//
// Three files in one package. `tables.go` is Go's declarations copied over
// unchanged, `dump.go` names the tables that were asked for, and `emit.go` is
// the reflection and the Mojo writing, which is static and lives at the bottom
// of this file.
func writeProgram(work string, decls []ast.Decl, imports map[string]string, tables []string) error {
	var tablesGo bytes.Buffer
	tablesGo.WriteString("package main\n\n")
	tablesGo.WriteString(importBlock(imports, qualifiers(decls)))
	fset := token.NewFileSet()
	for _, decl := range decls {
		if err := printer.Fprint(&tablesGo, fset, decl); err != nil {
			return err
		}
		tablesGo.WriteString("\n\n")
	}

	var dumpGo bytes.Buffer
	dumpGo.WriteString("package main\n\nfunc main() {\n")
	for _, name := range tables {
		fmt.Fprintf(&dumpGo, "\temit(%q, %s)\n", name, name)
	}
	dumpGo.WriteString("\tflush()\n}\n")

	files := map[string]string{
		"go.mod":    "module testgen\n\ngo 1.25\n",
		"tables.go": tablesGo.String(),
		"dump.go":   dumpGo.String(),
		"emit.go":   emitter,
	}
	for name, text := range files {
		if err := os.WriteFile(filepath.Join(work, name), []byte(text), 0o600); err != nil {
			return err
		}
	}
	return nil
}

// importBlock writes the imports the copied declarations were written under.
//
// The dot import is the one that matters: `. "math"` in Go's own test file, or
// the package under test that readDecls adds when the tables live inside it, is
// what makes `Pi` and `NaN()` in a table still mean what they meant in Go. It
// is always kept. A named
// import is kept only when a copied declaration qualifies something with it,
// since Go refuses to compile an unused import and most of these came in for
// the test functions, which did not come along.
func importBlock(imports map[string]string, used map[string]bool) string {
	paths := make([]string, 0, len(imports))
	for path := range imports {
		paths = append(paths, path)
	}
	sort.Strings(paths)

	var out strings.Builder
	out.WriteString("import (\n")
	for _, path := range paths {
		alias := imports[path]
		name := alias
		if name == "" {
			name = path[strings.LastIndex(path, "/")+1:]
		}
		switch {
		case alias == ".":
			fmt.Fprintf(&out, "\t. %q\n", path)
		case !used[name]:
		case alias == "":
			fmt.Fprintf(&out, "\t%q\n", path)
		default:
			fmt.Fprintf(&out, "\t%s %q\n", alias, path)
		}
	}
	out.WriteString(")\n\n")
	return out.String()
}

// The dump program, static so that it reads as the Go it is. It writes no
// backtick of its own, because this file is a Go string and Go strings written
// with backticks cannot contain one, so `tick` is where every backtick in the
// emitted Mojo comes from.
const emitter = `package main

import (
	"fmt"
	"math"
	"os"
	"reflect"
	"sort"
	"strconv"
	"strings"
)

var tick = string(rune(96))

// A column of a table: the Mojo type, how to write a value, and how to say what
// the value is in a comment.
type column struct {
	mojo  string
	write func(reflect.Value) string
	note  func(reflect.Value) string
}

// A row shape that needed a struct of its own, and the Mojo for it.
type shape struct {
	name string
	body string
}

var shapes []shape
var declared = map[string]bool{}
var body strings.Builder
var complexUsed bool

// emit writes one table.
func emit(name string, table any) {
	v := reflect.ValueOf(table)
	if v.Kind() != reflect.Slice && v.Kind() != reflect.Array {
		fail(name, "is not a slice, and this tool writes tables")
	}

	mojo, write, note := shapeOf(name, v.Type().Elem())
	wide := scalar(v.Type().Elem()) == nil

	fmt.Fprintf(&body, "\n\ndef %s() -> List[%s]:\n", tableName(name), mojo)
	fmt.Fprintf(&body, "    \"\"\"Go's %s%s%s.\"\"\"\n", tick, name, tick)
	if v.Len() == 0 {
		fmt.Fprintf(&body, "    return List[%s]()\n", mojo)
		return
	}
	body.WriteString("    return [\n")
	for i := 0; i < v.Len(); i++ {
		// A one column row takes its comment on the end, where it reads as an
		// annotation. A wider row takes it above, because a whole row of bit
		// patterns plus a comment is past the line length and the formatter
		// would break the row across four lines to keep it.
		said := note(v.Index(i))
		if wide && said != "" {
			body.WriteString("        # " + said + "\n")
		}
		line := "        " + write(v.Index(i)) + ","
		if !wide && said != "" {
			line += "  # " + said
		}
		body.WriteString(line + "\n")
	}
	body.WriteString("    ]\n")
}

// shapeOf works out how one element of a table is written.
func shapeOf(table string, t reflect.Type) (string, func(reflect.Value) string, func(reflect.Value) string) {
	if c := scalar(t); c != nil {
		return c.mojo, c.write, c.note
	}
	return structure(table, t)
}

// scalar describes an element that is one value, or nil for anything else.
func scalar(t reflect.Type) *column {
	switch t.Kind() {
	case reflect.Float64:
		return &column{
			mojo:  "Float64",
			write: func(v reflect.Value) string { return fmt.Sprintf("_f64(0x%016X)", math.Float64bits(v.Float())) },
			note:  func(v reflect.Value) string { return decimal(v.Float(), 64) },
		}
	case reflect.Float32:
		return &column{
			mojo:  "Float32",
			write: func(v reflect.Value) string { return fmt.Sprintf("_f32(0x%08X)", math.Float32bits(float32(v.Float()))) },
			note:  func(v reflect.Value) string { return decimal(v.Float(), 32) },
		}
	case reflect.Complex128:
		// Both halves as bits, for the reason every float here is: a table of
		// expected answers is the last place to find out that a literal was
		// flushed to zero. The flag set here is what tells the preamble to
		// import the type and declare the helper, so a package with no complex
		// table in it carries neither.
		complexUsed = true
		return &column{
			mojo: "ComplexFloat64",
			write: func(v reflect.Value) string {
				c := v.Complex()
				return fmt.Sprintf("_c64(0x%016X, 0x%016X)", math.Float64bits(real(c)), math.Float64bits(imag(c)))
			},
			note: func(v reflect.Value) string {
				c := v.Complex()
				return decimal(real(c), 64) + " and " + decimal(imag(c), 64) + "i"
			},
		}
	case reflect.Int, reflect.Int8, reflect.Int16, reflect.Int32, reflect.Int64:
		return &column{
			mojo:  "Int",
			write: func(v reflect.Value) string { return strconv.FormatInt(v.Int(), 10) },
			note:  func(reflect.Value) string { return "" },
		}
	case reflect.Uint, reflect.Uint8, reflect.Uint16, reflect.Uint32, reflect.Uint64:
		return &column{
			mojo:  "UInt64",
			write: func(v reflect.Value) string { return "UInt64(" + strconv.FormatUint(v.Uint(), 10) + ")" },
			note:  func(reflect.Value) string { return "" },
		}
	case reflect.Bool:
		return &column{
			mojo: "Bool",
			write: func(v reflect.Value) string {
				if v.Bool() {
					return "True"
				}
				return "False"
			},
			note: func(reflect.Value) string { return "" },
		}
	case reflect.String:
		return &column{
			mojo:  "String",
			write: func(v reflect.Value) string { return strconv.Quote(v.String()) },
			note:  func(reflect.Value) string { return "" },
		}
	}
	return nil
}

// structure declares a struct for an element with more than one column in it,
// and gives back the name to call it by and how to write one.
//
// A named Go type keeps its name, so fi is Fi wherever it turns up and the six
// tables built on it share one struct. An array is named after what is in it,
// since [2]float64 has no name to keep and every table using one means the same
// thing by it. An anonymous struct is named after the table it appeared in,
// because that is the only name it has.
func structure(table string, t reflect.Type) (string, func(reflect.Value) string, func(reflect.Value) string) {
	var name string
	var fields []string
	var columns []*column

	switch t.Kind() {
	case reflect.Array:
		inner := scalar(t.Elem())
		if inner == nil {
			fail(table, "is an array of something that is not a single value")
		}
		sizes := []string{"Zero", "One", "Pair", "Triple", "Quad"}
		if t.Len() >= len(sizes) {
			fail(table, "has rows wider than this tool names")
		}
		name = inner.mojo + sizes[t.Len()]
		for i := 0; i < t.Len(); i++ {
			fields = append(fields, string(rune('a'+i)))
			columns = append(columns, inner)
		}
	case reflect.Struct:
		name = camel(t.Name())
		if name == "" {
			name = camel(table) + "Row"
		}
		for i := 0; i < t.NumField(); i++ {
			c := scalar(t.Field(i).Type)
			if c == nil {
				fail(table, "has a field that is not a single value")
			}
			fields = append(fields, fieldName(t.Field(i).Name))
			columns = append(columns, c)
		}
	default:
		fail(table, "holds a "+t.Kind().String()+", which this tool does not write")
	}

	if !declared[name] {
		declared[name] = true
		var out strings.Builder
		fmt.Fprintf(&out, "struct %s(Copyable, Movable):\n", name)
		fmt.Fprintf(&out, "    \"\"\"One row of Go's %s%s%s and of the tables shaped like it.\"\"\"\n\n", tick, table, tick)
		for i, f := range fields {
			fmt.Fprintf(&out, "    var %s: %s\n", f, columns[i].mojo)
		}
		out.WriteString("\n    def __init__(out self")
		for i, f := range fields {
			fmt.Fprintf(&out, ", %s: %s", f, columns[i].mojo)
		}
		out.WriteString("):\n")
		for _, f := range fields {
			fmt.Fprintf(&out, "        self.%s = %s\n", f, f)
		}
		shapes = append(shapes, shape{name: name, body: out.String()})
	}

	at := func(v reflect.Value, i int) reflect.Value {
		if v.Kind() == reflect.Struct {
			return v.Field(i)
		}
		return v.Index(i)
	}
	write := func(v reflect.Value) string {
		parts := make([]string, len(fields))
		for i := range fields {
			parts[i] = columns[i].write(at(v, i))
		}
		return name + "(" + strings.Join(parts, ", ") + ")"
	}
	note := func(v reflect.Value) string {
		parts := make([]string, 0, len(fields))
		for i := range fields {
			if said := columns[i].note(at(v, i)); said != "" {
				parts = append(parts, said)
			}
		}
		return strings.Join(parts, ", ")
	}
	return name, write, note
}

// decimal is the shortest decimal that reads back as this float, or a word for
// the values that have no decimal at all.
func decimal(x float64, bits int) string {
	switch {
	case math.IsNaN(x):
		return "not a number"
	case math.IsInf(x, 1):
		return "infinity"
	case math.IsInf(x, -1):
		return "negative infinity"
	}
	return strconv.FormatFloat(x, 'g', -1, bits)
}

// tableName is what the table is called here: Go's name in snake case, said to
// be rows because that is what every table builder under tests/ is called.
func tableName(name string) string {
	return snake(name) + "_rows"
}

// fieldName is what a Go struct field is called here.
//
// Go's special case tables are written as an in and a want, and in is a Mojo
// keyword, so a struct with a field of that name does not parse. The rename is
// spelled out rather than suffixed, because row.arg reads as what it is and
// row.in_ reads as a tool having got out of the way of a problem.
func fieldName(name string) string {
	switch snake(name) {
	case "in":
		return "arg"
	}
	return snake(name)
}

func snake(name string) string {
	var out []rune
	runes := []rune(name)
	for i, r := range runes {
		if r >= 'A' && r <= 'Z' {
			after := i > 0 && !(runes[i-1] >= 'A' && runes[i-1] <= 'Z')
			before := i+1 < len(runes) && runes[i+1] >= 'a' && runes[i+1] <= 'z'
			if i > 0 && (after || before) {
				out = append(out, '_')
			}
			r = r - 'A' + 'a'
		}
		out = append(out, r)
	}
	return string(out)
}

func camel(name string) string {
	parts := strings.Split(snake(name), "_")
	for i, p := range parts {
		if p != "" {
			parts[i] = strings.ToUpper(p[:1]) + p[1:]
		}
	}
	return strings.Join(parts, "")
}

func fail(table, why string) {
	fmt.Fprintf(os.Stderr, "extract: %s %s\n", table, why)
	os.Exit(1)
}

// flush writes the file: the preamble, then the structs the tables needed, then
// the tables themselves.
func flush() {
	sort.Slice(shapes, func(i, j int) bool { return shapes[i].name < shapes[j].name })
	fmt.Print(preamble())
	for _, s := range shapes {
		fmt.Print("\n\n" + s.body)
	}
	fmt.Print(body.String())
}

func preamble() string {
	lines := []string{
		"\"\"\"Go's test tables, as data.",
		"",
		"Every float is written as its bits with the decimal beside it in a comment.",
		"Mojo flushes a subnormal float literal to zero, so " + tick + "4.9406564584124654e-324" + tick,
		"written out in a source file is " + tick + "0.0" + tick + " by the time it is a " + tick + "Float64" + tick + ", and a",
		"table of expected answers is the last place that should be found out. The",
		"comment is what to read this against Go's source with, and it is the shortest",
		"decimal that reads back as the value, so it is not an approximation. The bits",
		"are what the tests run on.",
		"\"\"\"",
		"",
		"from std.memory import bitcast",
		"",
		"",
		"def _f64(bits: UInt64) -> Float64:",
		"    \"\"\"The float64 those bits are.\"\"\"",
		"    return bitcast[DType.float64](bits)",
		"",
		"",
		"def _f32(bits: UInt32) -> Float32:",
		"    \"\"\"The float32 those bits are.\"\"\"",
		"    return bitcast[DType.float32](bits)",
	}
	if complexUsed {
		var with []string
		for _, line := range lines {
			if line == "from std.memory import bitcast" {
				with = append(with, "from std.complex import ComplexFloat64")
			}
			with = append(with, line)
		}
		lines = append(with,
			"",
			"",
			"def _c64(re: UInt64, im: UInt64) -> ComplexFloat64:",
			"    \"\"\"The complex number those two sets of bits are.\"\"\"",
			"    return ComplexFloat64(_f64(re), _f64(im))",
		)
	}
	return strings.Join(lines, "\n") + "\n"
}
`
