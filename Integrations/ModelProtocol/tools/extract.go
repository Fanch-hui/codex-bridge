//go:build ignore

package main

import (
	"fmt"
	"go/ast"
	"go/format"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

type decl struct {
	name, file string
	node       ast.Node
}

func main() {
	if len(os.Args) < 3 {
		panic("usage: extract.go <upstream package> <root declarations...>")
	}
	root := os.Args[1]
	pkg := os.Getenv("PACKAGE")
	if pkg == "" {
		pkg = "gateway"
	}
	fs := token.NewFileSet()
	names := map[string][]*decl{}
	methods := map[string][]*decl{}
	globalObjs := map[*ast.Object]bool{}
	parsed := map[string]*ast.File{}
	files, _ := filepath.Glob(filepath.Join(root, "*.go"))
	for _, file := range files {
		base := filepath.Base(file)
		if strings.HasSuffix(base, "_test.go") {
			continue
		}
		n, err := parser.ParseFile(fs, file, nil, 0)
		if err != nil {
			panic(err)
		}
		if n.Name.Name != pkg {
			continue
		}
		if pkg == "gateway" && base == "ir.go" {
			for _, d := range n.Decls {
				g, ok := d.(*ast.GenDecl)
				if !ok {
					continue
				}
				for _, s := range g.Specs {
					t, ok := s.(*ast.TypeSpec)
					if !ok || t.Name.Name != "Request" {
						continue
					}
					st := t.Type.(*ast.StructType)
					fields := st.Fields.List[:0]
					for _, f := range st.Fields.List {
						if len(f.Names) == 1 && (f.Names[0].Name == "branch" || f.Names[0].Name == "runTold") {
							continue
						}
						fields = append(fields, f)
					}
					st.Fields.List = fields
				}
			}
		}
		if pkg == "gateway" && base == "gemini_sigstore.go" {
			for _, d := range n.Decls {
				g, ok := d.(*ast.GenDecl)
				if !ok {
					continue
				}
				for _, spec := range g.Specs {
					v, ok := spec.(*ast.ValueSpec)
					if !ok || len(v.Names) != 1 || v.Names[0].Name != "sigDir" {
						continue
					}
					v.Type = &ast.FuncType{Params: &ast.FieldList{}, Results: &ast.FieldList{List: []*ast.Field{{Type: ast.NewIdent("string")}}}}
					v.Values = nil
				}
			}
		}
		if pkg == "provider" {
			replacements := map[string]string{
				"CommandCodeGoHint": "this plan's key requires a compatible provider plugin and cannot be used as a standard API-key provider",
				"HarnessOnlyHint":   "this model is only available to supported agent applications; the model without :free may be available",
			}
			for _, d := range n.Decls {
				g, ok := d.(*ast.GenDecl)
				if !ok {
					continue
				}
				for _, spec := range g.Specs {
					v, ok := spec.(*ast.ValueSpec)
					if !ok || len(v.Names) != 1 || len(v.Values) != 1 {
						continue
					}
					if replacement, ok := replacements[v.Names[0].Name]; ok {
						v.Values[0] = &ast.BasicLit{Kind: token.STRING, Value: strconv.Quote(replacement)}
					}
				}
			}
		}
		parsed[base] = n
		for _, d := range n.Decls {
			switch x := d.(type) {
			case *ast.FuncDecl:
				if x.Name.Obj != nil {
					globalObjs[x.Name.Obj] = true
				}
				item := &decl{x.Name.Name, base, x}
				if x.Recv == nil {
					names[item.name] = append(names[item.name], item)
				} else {
					receiver := ""
					switch r := x.Recv.List[0].Type.(type) {
					case *ast.StarExpr:
						if id, ok := r.X.(*ast.Ident); ok {
							receiver = id.Name
						}
					case *ast.Ident:
						receiver = r.Name
					}
					methods[receiver] = append(methods[receiver], item)
				}
			case *ast.GenDecl:
				if x.Tok == token.IMPORT {
					continue
				}
				item := &decl{"", base, x}
				for _, spec := range x.Specs {
					switch v := spec.(type) {
					case *ast.TypeSpec:
						names[v.Name.Name] = append(names[v.Name.Name], item)
						if v.Name.Obj != nil {
							globalObjs[v.Name.Obj] = true
						}
					case *ast.ValueSpec:
						for _, id := range v.Names {
							names[id.Name] = append(names[id.Name], item)
							if id.Obj != nil {
								globalObjs[id.Obj] = true
							}
						}
					}
				}
			}
		}
	}
	seen := map[*decl]bool{}
	selectors := map[string]bool{}
	for _, s := range strings.Split(os.Getenv("SELECTORS"), ",") {
		if s != "" {
			selectors[s] = true
		}
	}
	usedTypes := map[string]bool{}
	q := []*decl{}
	add := func(d *decl) {
		if !seen[d] {
			seen[d] = true
			q = append(q, d)
		}
	}
	for _, root := range os.Args[2:] {
		if len(names[root]) == 0 {
			panic("missing upstream declaration: " + root)
		}
		for _, d := range names[root] {
			add(d)
		}
	}
	for len(q) > 0 {
		d := q[0]
		q = q[1:]
		skip := map[*ast.Ident]bool{}
		ast.Inspect(d.node, func(node ast.Node) bool {
			switch n := node.(type) {
			case *ast.SelectorExpr:
				skip[n.Sel] = true
				if !selectors[n.Sel.Name] {
					selectors[n.Sel.Name] = true
					for typ := range usedTypes {
						for _, method := range methods[typ] {
							if method.name == n.Sel.Name {
								add(method)
							}
						}
					}
				}
			case *ast.Field:
				for _, id := range n.Names {
					skip[id] = true
				}
			case *ast.KeyValueExpr:
				if id, ok := n.Key.(*ast.Ident); ok {
					skip[id] = true
				}
			}
			return true
		})
		ast.Inspect(d.node, func(node ast.Node) bool {
			id, ok := node.(*ast.Ident)
			if !ok {
				return true
			}
			if skip[id] || (id.Obj != nil && !globalObjs[id.Obj]) {
				return true
			}
			for _, ref := range names[id.Name] {
				add(ref)
			}
			if len(methods[id.Name]) > 0 {
				usedTypes[id.Name] = true
				for _, method := range methods[id.Name] {
					if selectors[method.name] {
						add(method)
					}
				}
			}
			return true
		})
	}
	counts := map[string]int{}
	for d := range seen {
		counts[d.file]++
	}
	files = nil
	for file := range counts {
		files = append(files, file)
	}
	sort.Strings(files)
	fmt.Printf("%s: %d files, %d declarations\n", pkg, len(files), len(seen))
	if output := os.Getenv("SLICEDIR"); output != "" {
		if err := os.MkdirAll(output, 0755); err != nil {
			panic(err)
		}
		for _, file := range files {
			original := parsed[file]
			selected := []ast.Decl{}
			imported := map[string]bool{}
			for _, node := range original.Decls {
				var found *decl
				for d := range seen {
					if d.file == file && d.node == node {
						found = d
						break
					}
				}
				if found == nil {
					continue
				}
				selected = append(selected, node)
				ast.Inspect(node, func(n ast.Node) bool {
					if sel, ok := n.(*ast.SelectorExpr); ok {
						if id, ok := sel.X.(*ast.Ident); ok {
							imported[id.Name] = true
						}
					}
					return true
				})
			}
			specs := []ast.Spec{}
			for _, i := range original.Imports {
				path, _ := strconv.Unquote(i.Path.Value)
				name := filepath.Base(path)
				if i.Name != nil {
					name = i.Name.Name
				}
				if imported[name] || name == "_" || name == "." {
					if strings.HasPrefix(path, "github.com/yetone/magpie/internal/") {
						i.Path.Value = strconv.Quote(strings.Replace(path, "github.com/yetone/magpie/internal/", "codexbridge/modelprotocol/internal/", 1))
					}
					specs = append(specs, i)
				}
			}
			if len(specs) > 0 {
				selected = append([]ast.Decl{&ast.GenDecl{Tok: token.IMPORT, Specs: specs, Lparen: 1}}, selected...)
			}
			result := &ast.File{Name: ast.NewIdent(pkg), Decls: selected}
			out, err := os.Create(filepath.Join(output, file))
			if err != nil {
				panic(err)
			}
			if err = format.Node(out, fs, result); err != nil {
				panic(err)
			}
			out.Close()
		}
	}
}
