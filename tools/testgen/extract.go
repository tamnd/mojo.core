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
//
// Every top level declaration in the test files is copied, not only the ones
// asked for, because a table is routinely built out of another one. A few
// cannot come along: math/rand/v2's test files open the package up through
// export_test.go and declare `var rn, kn, wn, fn =
// GetNormalDistributionParameters()`, which is a function that exists only
// inside the package under test. `-skip` names those, and the plan is where
// the list lives so that leaving a declaration behind is a change somebody
// looked at.
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
	drop := flag.String("skip", "", "comma separated names of declarations to leave behind")
	flag.Parse()

	if *dir == "" || *list == "" {
		fmt.Fprintln(os.Stderr, "extract: -package and -tables are both required")
		os.Exit(2)
	}

	out, err := extract(*dir, strings.Split(*list, ","), split(*drop))
	if err != nil {
		fmt.Fprintf(os.Stderr, "extract: %v\n", err)
		os.Exit(1)
	}
	fmt.Print(out)
}

// split turns a comma separated flag into names, with an empty flag giving none.
func split(list string) []string {
	if strings.TrimSpace(list) == "" {
		return nil
	}
	return strings.Split(list, ",")
}

// extract reads one package's test files and gives back the Mojo for its tables.
func extract(dir string, tables, skip []string) (string, error) {
	decls, imports, err := readDecls(dir)
	if err != nil {
		return "", err
	}

	declared := map[string]bool{}
	for _, name := range declaredNames(decls) {
		declared[name] = true
	}
	// The skip list is checked before anything is dropped, so an entry that
	// Go has since renamed or deleted stops the harvest instead of silently
	// doing nothing.
	for _, gone := range skip {
		if !declared[gone] {
			return "", fmt.Errorf("%s has nothing named %s to skip, so the plan is stale", filepath.Base(dir), gone)
		}
	}
	decls = prune(decls, skip)

	declared = map[string]bool{}
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
			out = append(out, specNames(spec)...)
		}
	}
	return out
}

// specNames lists what one spec of a declaration declares.
func specNames(spec ast.Spec) []string {
	switch s := spec.(type) {
	case *ast.ValueSpec:
		var out []string
		for _, name := range s.Names {
			out = append(out, name.Name)
		}
		return out
	case *ast.TypeSpec:
		return []string{s.Name.Name}
	}
	return nil
}

// prune drops the declarations named in skip.
//
// One spec at a time rather than one declaration at a time, so that dropping
// `chacha8hash` out of a `var (...)` group would leave the rest of the group
// alone. A spec goes if any of the names it declares is named, since `var rn,
// kn, wn, fn = f()` is one spec and there is no half of it to keep.
//
// A `const (...)` group counting with iota is the case to be careful with:
// removing a spec from the middle of one renumbers everything after it. No
// plan entry does that today and the harvest would be visibly wrong if one
// did, which is the sort of wrong a diff catches.
func prune(decls []ast.Decl, skip []string) []ast.Decl {
	if len(skip) == 0 {
		return decls
	}
	gone := map[string]bool{}
	for _, name := range skip {
		gone[name] = true
	}

	var kept []ast.Decl
	for _, decl := range decls {
		gen, ok := decl.(*ast.GenDecl)
		if !ok {
			kept = append(kept, decl)
			continue
		}
		var specs []ast.Spec
		for _, spec := range gen.Specs {
			drop := false
			for _, name := range specNames(spec) {
				if gone[name] {
					drop = true
				}
			}
			if !drop {
				specs = append(specs, spec)
			}
		}
		if len(specs) == 0 {
			continue
		}
		shorter := *gen
		shorter.Specs = specs
		kept = append(kept, &shorter)
	}
	return kept
}

// predeclared is Go's own universe of names, which a copied declaration can
// use without anything having been imported for it.
var predeclared = map[string]bool{
	"any": true, "bool": true, "byte": true, "comparable": true,
	"complex64": true, "complex128": true, "error": true,
	"float32": true, "float64": true,
	"int": true, "int8": true, "int16": true, "int32": true, "int64": true,
	"rune": true, "string": true,
	"uint": true, "uint8": true, "uint16": true, "uint32": true,
	"uint64": true, "uintptr": true,
	"true": true, "false": true, "iota": true, "nil": true,
	"append": true, "cap": true, "clear": true, "close": true,
	"complex": true, "copy": true, "delete": true, "imag": true,
	"len": true, "make": true, "max": true, "min": true, "new": true,
	"panic": true, "print": true, "println": true, "real": true,
	"recover": true,
}

// needsDot says whether the copied declarations still need the dot import.
//
// A dot import has no qualifier to look for, so what says it is needed is an
// identifier the declarations use and nothing else explains: not one they
// declare themselves, not the qualifier of a selector, not a struct field
// name, not one of Go's own. math/cmplx's tables say `NaN()` and mean cmplx's
// own, so the import stays. math/rand/v2's say `float64(...)` and nothing
// else, so it goes, and Go refuses to compile a file that imports a package it
// does not use.
//
// Both ways of getting this wrong are loud. Keeping an import nothing uses is
// "imported and not used" and dropping one something needs is "undefined",
// and either stops the harvest with the name in the message.
func needsDot(decls []ast.Decl) bool {
	mine := map[string]bool{}
	for _, name := range declaredNames(decls) {
		mine[name] = true
	}

	found := false
	var look func(ast.Node) bool
	look = func(n ast.Node) bool {
		switch node := n.(type) {
		case *ast.SelectorExpr:
			// `hex.DecodeString` names a package and a member of it, and
			// neither half resolves on its own. `f(x).Field` does have
			// something to look at, so the left of it is still walked.
			if _, ok := node.X.(*ast.Ident); !ok {
				ast.Inspect(node.X, look)
			}
			return false
		case *ast.KeyValueExpr:
			// A bare name on the left of a colon is a struct field.
			if _, ok := node.Key.(*ast.Ident); !ok {
				ast.Inspect(node.Key, look)
			}
			ast.Inspect(node.Value, look)
			return false
		case *ast.Field:
			// The names of a struct's fields are the struct's, not anyone's
			// to resolve. The type beside them is another matter.
			ast.Inspect(node.Type, look)
			return false
		case *ast.Ident:
			if !mine[node.Name] && !predeclared[node.Name] {
				found = true
			}
		}
		return true
	}
	for _, decl := range decls {
		ast.Inspect(decl, look)
	}
	return found
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
	tablesGo.WriteString(importBlock(imports, qualifiers(decls), needsDot(decls)))
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
// is kept whenever anything the declarations say could have come from it, which
// `needsDot` decides. A named import is kept only when a copied declaration
// qualifies something with it, since Go refuses to compile an unused import and
// most of these came in for the test functions, which did not come along.
func importBlock(imports map[string]string, used map[string]bool, dot bool) string {
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
			if dot {
				fmt.Fprintf(&out, "\t. %q\n", path)
			}
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
	"encoding/hex"
	"fmt"
	"math"
	"os"
	"reflect"
	"sort"
	"strconv"
	"strings"
	"unicode/utf8"
	"unsafe"
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
var declared = map[string]string{}
var body strings.Builder
var floatUsed bool
var complexUsed bool
var stringUsed bool

// asText says whether the table being written now holds text rather than
// bytes. Set by emit from the values themselves and read by scalar, which is
// handed a type and never sees them.
//
// A global rather than an argument because scalar is called from six places
// and five of them have no opinion about it, and this program already keeps
// what it has emitted so far the same way.
var asText bool

// text says whether every Go string anywhere in this table is printable text,
// in which case writing it as a Mojo string literal cannot change it.
//
// The default is bytes, for the reason scalar's String case gives: a Go string
// is a byte string, Mojo reads a literal as UTF-8, and a marshalled generator
// state written as a literal comes back two bytes longer than it went in.
//
// Valid UTF-8 with every rune printable is the condition, and it is exactly
// the condition strconv.Quote needs to produce a literal with no numeric
// escape in it. What comes out is then the same bytes Go's own source file
// has, including a pattern like [a-ζ], which is text in both languages and
// hex in neither. A table with one byte outside that keeps the hex, since
// that is the table the hex was written for.
//
// Decided per table rather than per package, so a package with one binary
// table in it does not lose the readable form for all its others.
func text(v reflect.Value) bool {
	switch v.Kind() {
	case reflect.String:
		if !utf8.ValidString(v.String()) {
			return false
		}
		for _, r := range v.String() {
			if !strconv.IsPrint(r) {
				return false
			}
		}
	case reflect.Slice, reflect.Array:
		for i := 0; i < v.Len(); i++ {
			if !text(v.Index(i)) {
				return false
			}
		}
	case reflect.Struct:
		for i := 0; i < v.NumField(); i++ {
			if !text(v.Field(i)) {
				return false
			}
		}
	}
	return true
}

// emit writes one table.
func emit(name string, table any) {
	v := reflect.ValueOf(table)
	if v.Kind() != reflect.Slice && v.Kind() != reflect.Array {
		fail(name, "is not a slice, and this tool writes tables")
	}
	if v.Type().Elem().Kind() == reflect.Interface {
		mixed(name, v)
		return
	}

	asText = text(v)
	defer func() { asText = false }()
	mojo, write, note := shapeOf(name, v.Type().Elem())
	rows := make([]reflect.Value, v.Len())
	for i := range rows {
		rows[i] = v.Index(i)
	}
	list(tableName(name), fmt.Sprintf("Go's %s%s%s.", tick, name, tick), mojo, write, note, rows, wide(v.Type().Elem()))
}

// wide says whether a row's comment belongs on a line of its own rather than
// on the end of the value. A struct row is most of a line before any comment
// is added to it, and so is a byte string, whose hex is twice as long as the
// bytes it stands for.
func wide(t reflect.Type) bool {
	return scalar(t) == nil || t.Kind() == reflect.String
}

// list writes one Mojo function returning one list.
func list(fn, doc, mojo string, write, note func(reflect.Value) string, rows []reflect.Value, wide bool) {
	fmt.Fprintf(&body, "\n\ndef %s() -> List[%s]:\n", fn, mojo)
	fmt.Fprintf(&body, "    \"\"\"%s\"\"\"\n", doc)
	if len(rows) == 0 {
		fmt.Fprintf(&body, "    return List[%s]()\n", mojo)
		return
	}
	body.WriteString("    return [\n")
	for _, row := range rows {
		// A one column row takes its comment on the end, where it reads as an
		// annotation. A wider row takes it above, because a whole row of bit
		// patterns plus a comment is past the line length and the formatter
		// would break the row across four lines to keep it.
		said := note(row)
		if wide && said != "" {
			body.WriteString("        # " + said + "\n")
		}
		line := "        " + write(row) + ","
		if !wide && said != "" {
			line += "  # " + said
		}
		body.WriteString(line + "\n")
	}
	body.WriteString("    ]\n")
}

// mixed writes a table whose element type is an interface.
//
// A golden file recorded call by call is one of these: math/rand/v2's
// regressGolden is 340 entries holding a float64 here, an int64 there and a
// []int somewhere else, because the thing being pinned is what seventeen
// methods return and reflect could put all of them in one slice. Mojo has no
// such slice, so this comes out as one list per Go type, each holding that
// type's values in the order they appeared. A test walking the same calls in
// the same order reads the list its return type went into, which is the same
// pairing Go's own test makes and does not need the types written down twice.
//
// A slice among the values becomes two lists, the values of every slice run
// together and the length of each, since a list of lists is not something this
// writes and the lengths are what put them back.
func mixed(name string, v reflect.Value) {
	var order []reflect.Type
	seen := map[reflect.Type]bool{}
	groups := map[reflect.Type][]reflect.Value{}
	for i := 0; i < v.Len(); i++ {
		held := v.Index(i).Elem()
		if !held.IsValid() {
			fail(name, "has a nil in it, and a nil has no type to write it as")
		}
		t := held.Type()
		if !seen[t] {
			seen[t] = true
			order = append(order, t)
		}
		groups[t] = append(groups[t], held)
	}
	for _, t := range order {
		group(name, t, groups[t])
	}
}

// group writes the values of one Go type out of an interface table.
func group(table string, t reflect.Type, values []reflect.Value) {
	base := snake(table) + "_" + suffix(table, t)
	where := fmt.Sprintf("of Go's %s%s%s, in the order they appear", tick, table, tick)

	if c := scalar(t); c != nil {
		list(base+"_rows", fmt.Sprintf("The %s entries %s.", t, where), c.mojo, c.write, c.note, values, wide(t))
		return
	}
	if t.Kind() != reflect.Slice {
		fail(table, "holds a "+t.String()+", which this tool does not write")
	}
	c := scalar(t.Elem())
	if c == nil {
		fail(table, "holds a "+t.String()+", and only a slice of single values can be flattened")
	}

	var flat, sizes []reflect.Value
	for _, v := range values {
		for i := 0; i < v.Len(); i++ {
			flat = append(flat, v.Index(i))
		}
		sizes = append(sizes, reflect.ValueOf(v.Len()))
	}
	count := scalar(reflect.TypeOf(0))
	list(base+"_rows", fmt.Sprintf("Every %s entry %s, run together.", t, where), c.mojo, c.write, c.note, flat, wide(t.Elem()))
	list(base+"_sizes", fmt.Sprintf("How long each of those %s entries was.", t), count.mojo, count.write, count.note, sizes, false)
}

// suffix is what one Go type is called in the name of the list its values go
// into. A slice is its element and the word slice, so []int is int_slice.
func suffix(table string, t reflect.Type) string {
	if t.Kind() == reflect.Slice {
		return suffix(table, t.Elem()) + "_slice"
	}
	if t.Name() == "" {
		fail(table, "holds a "+t.String()+", which has no name to build a list name out of")
	}
	return snake(t.Name())
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
		floatUsed = true
		return &column{
			mojo:  "Float64",
			write: func(v reflect.Value) string { return fmt.Sprintf("_f64(0x%016X)", math.Float64bits(v.Float())) },
			note:  func(v reflect.Value) string { return decimal(v.Float(), 64) },
		}
	case reflect.Float32:
		floatUsed = true
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
		// A table whose strings are all printable ASCII is text, and text is
		// written as text. Go's quoting and Mojo's agree over that range, so
		// the literal in the generated file is the literal in Go's source and
		// a reviewer can read one against the other.
		if asText {
			return &column{
				mojo:  "String",
				write: func(v reflect.Value) string { return strconv.Quote(v.String()) },
				note:  func(v reflect.Value) string { return "" },
			}
		}
		// Otherwise bytes, with the Go source form beside them in a comment. A
		// Go string is a byte string and some of these tables are marshalled
		// binary, so chacha8marshalread has a "\xb6" in it that is not a code
		// point and is not meant to be. Mojo reads a literal as UTF-8, turns
		// that escape into the two bytes U+00B6 is, and the golden silently
		// grows: a sixteen byte encoding arrives as eighteen. Hex has no such
		// opinion.
		stringUsed = true
		return &column{
			mojo: "List[UInt8]",
			write: func(v reflect.Value) string {
				return "_hex(\"" + hex.EncodeToString([]byte(v.String())) + "\")"
			},
			note: func(v reflect.Value) string { return strconv.Quote(v.String()) },
		}
	}
	return nil
}

// mojoTypes is the Mojo type of every column, for comparing two declarations
// that want the same struct name.
func mojoTypes(columns []*column) []string {
	out := make([]string, len(columns))
	for i, c := range columns {
		out[i] = c.mojo
	}
	return out
}

// errType is what a field has to implement to be written as its message.
var errType = reflect.TypeOf((*error)(nil)).Elem()

// reachable gives back a value that Interface can be called on.
//
// Go's test tables are rows of unexported fields, and reflect refuses to hand
// out a value it read from one, so that a program cannot use reflection to get
// at what the package it is reading kept private. Reading a number or a string
// out of such a field is allowed, which is why every other column here works
// without this; calling a method on one is not, and an error is only useful
// through its Error method.
//
// A row comes out of a slice, so it is addressable, and this reads the same
// bytes back through an address rather than through the field. That is the
// documented way round the rule and it is sound here for the reason the rule
// exists: this program is not the package's caller, it is a code generator
// reading a table that was written to be read.
func reachable(v reflect.Value) reflect.Value {
	if !v.CanAddr() {
		return v
	}
	return reflect.NewAt(v.Type(), unsafe.Pointer(v.UnsafeAddr())).Elem()
}

// field describes one column of a row struct, which is a wider question than
// scalar answers.
//
// Two shapes turn up inside a row that never turn up as a whole row. A list,
// as in Go's jointests, whose rows are the arguments to a variadic call and
// the answer. And an error, as in matchTests, where the row says both what the
// call gives back and whether it fails at all.
//
// An error becomes its message rather than a boolean, because that is what the
// value is. A row whose error is nil gets the empty string, which no failure
// produces. Turning it into "this fails" would be this tool deciding what the
// test means, and the tests are supposed to be Go's rather than ours.
func field(t reflect.Type) *column {
	if c := scalar(t); c != nil {
		return c
	}
	if t.Kind() == reflect.Interface && t.Implements(errType) {
		return &column{
			mojo: "String",
			write: func(v reflect.Value) string {
				if v.IsNil() {
					return strconv.Quote("")
				}
				return strconv.Quote(reachable(v).Interface().(error).Error())
			},
			note: func(v reflect.Value) string { return "" },
		}
	}
	if t.Kind() == reflect.Slice {
		inner := scalar(t.Elem())
		if inner == nil {
			return nil
		}
		return &column{
			mojo: "List[" + inner.mojo + "]",
			write: func(v reflect.Value) string {
				parts := make([]string, v.Len())
				for i := range parts {
					parts[i] = inner.write(v.Index(i))
				}
				return "[" + strings.Join(parts, ", ") + "]"
			},
			note: func(v reflect.Value) string { return "" },
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
			c := field(t.Field(i).Type)
			if c == nil {
				fail(table, "has a field that is not a single value, a list of them, or an error")
			}
			fields = append(fields, fieldName(t.Field(i).Name))
			columns = append(columns, c)
		}
	default:
		fail(table, "holds a "+t.Kind().String()+", which this tool does not write")
	}

	// One struct per name, shared by every table shaped like it. Two tables
	// wanting the same name and different columns would otherwise write rows of
	// the second against the declaration of the first, which compiles when the
	// widths happen to line up.
	made := name + "(" + strings.Join(mojoTypes(columns), ", ") + ")"
	if was, seen := declared[name]; seen && was != made {
		fail(table, "wants "+made+" and an earlier table declared "+was)
	}
	if _, seen := declared[name]; !seen {
		declared[name] = made
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
		for i, f := range fields {
			// A List is not implicitly copyable, so the copy is asked for. It
			// happens once per row when the table is built and the rows are
			// what the tests read, so the alternative of taking the argument
			// by value and moving out of it would save one copy of a handful
			// of strings and cost a var on every field of every struct here.
			if strings.HasPrefix(columns[i].mojo, "List[") {
				fmt.Fprintf(&out, "        self.%s = %s.copy()\n", f, f)
				continue
			}
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
// keyword, so a struct with a field of that name does not parse. So is match,
// which is what path's own table calls the answer it expects. Each rename is
// spelled out rather than suffixed, because row.arg and row.matched read as
// what they are and row.in_ reads as a tool having got out of the way of a
// problem. Both words are the ones Go's own documentation uses for the field,
// so neither is invented here.
func fieldName(name string) string {
	switch snake(name) {
	case "in":
		return "arg"
	case "match":
		return "matched"
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
	// A package with no float and no complex number in any of its tables gets
	// neither the paragraph about floats nor the two helpers that read bits
	// back, because a file of paths carrying an explanation of subnormal
	// literals and a pair of functions nothing calls is a file that reads as if
	// it had been copied from somewhere else. The hex helpers are a separate
	// question with a separate flag, and a package can want either, both or
	// neither.
	if !floatUsed && !complexUsed {
		lines := []string{
			"\"\"\"Go's test tables, as data.",
			"",
			"Each one is what Go's own tests are read against, taken out of the Go tree by",
			"tools/testgen rather than typed, so that a row here is a row there and a table",
			"Go changes shows up as a diff.",
			"\"\"\"",
		}
		return strings.Join(append(lines, hexHelpers()...), "\n") + "\n"
	}
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
	return strings.Join(append(lines, hexHelpers()...), "\n") + "\n"
}

// hexHelpers is what reads a hex column back, or nothing at all for a package
// whose tables held no bytes.
func hexHelpers() []string {
	if !stringUsed {
		return nil
	}
	return []string{
		"",
		"",
		"def _nibble(digit: UInt8) -> UInt8:",
		"    \"\"\"The value of one lower case hex digit.\"\"\"",
		"    return digit - 0x30 if digit <= 0x39 else digit - 0x57",
		"",
		"",
		"def _hex[o: ImmOrigin](text: StringSlice[o]) -> List[UInt8]:",
		"    \"\"\"The bytes those hex digits are.",
		"",
		"    A Go string in these tables is a byte string rather than text. Writing",
		"    one as a Mojo literal would re-encode every byte above 0x7F as the two",
		"    or three UTF-8 bytes its code point is, so a sixteen byte marshalled",
		"    form would arrive as eighteen and the golden would be longer than the",
		"    thing it checks. Hex has no such opinion.",
		"    \"\"\"",
		"    var raw = text.as_bytes()",
		"    var out = List[UInt8](capacity=len(raw) // 2)",
		"    for i in range(0, len(raw), 2):",
		"        out.append(_nibble(raw[i]) << 4 | _nibble(raw[i + 1]))",
		"    return out^",
	}
}
`
