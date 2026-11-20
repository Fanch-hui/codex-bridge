package provider

import (
	"bytes"

	"crypto/sha256"
	"encoding/hex"
	"encoding/json"

	"maps"

	"slices"

	"strings"
)

func FlatName(namespace, name string) string {
	flat := namespace + "__" + name
	if len(flat) <= 64 {
		return flat
	}
	sum := sha256.Sum256([]byte(namespace + "\x00" + name))
	return flat[:55] + "_" + hex.EncodeToString(sum[:4])
}

func ObjectRoot(ps map[string]any) bool {
	return objectRootIn(ps, ps, 0)
}

func objectRootIn(root, ps map[string]any, depth int) bool {
	_, any1 := ps["anyOf"]
	_, one := ps["oneOf"]
	_, all := ps["allOf"]
	if ps["type"] == "object" && !any1 && !one && !all {
		return false
	}
	props, _ := ps["properties"].(map[string]any)
	if props == nil {
		props = map[string]any{}
	}
	var required []any
	if r, ok := ps["required"].([]any); ok {
		required = r
	}
	list, _ := ps["allOf"].([]any)
	for _, b := range list {
		bm, _ := b.(map[string]any)
		if bm = grokRef(root, bm); bm == nil {
			continue
		}
		bp, _ := bm["properties"].(map[string]any)
		for k, v := range bp {
			if _, ok := props[k]; !ok {
				props[k] = v
			}
		}
		br, _ := bm["required"].([]any)
		required = append(required, br...)
	}
	delete(ps, "allOf")
	var branches []map[string]any
	for _, k := range []string{"anyOf", "oneOf"} {
		list, _ := ps[k].([]any)
		for _, b := range list {
			bm, _ := b.(map[string]any)
			if bm = grokRef(root, bm); bm == nil {
				continue
			}
			if nestedUnion(bm) && depth < 8 {

				bm = maps.Clone(bm)
				objectRootIn(root, bm, depth+1)
			}
			if _, has := bm["properties"]; bm["type"] != "object" && !has {
				continue
			}
			branches = append(branches, bm)
		}
		delete(ps, k)
	}

	var common []any

	from := map[string][]any{}
	var order []string
	for i, b := range branches {
		bp, _ := b["properties"].(map[string]any)
		for _, k := range slices.Sorted(maps.Keys(bp)) {
			if _, own := props[k]; own {
				continue
			}
			if _, seen := from[k]; !seen {
				order = append(order, k)
			}
			from[k] = appendDistinct(from[k], bp[k])
		}
		br, _ := b["required"].([]any)
		if i == 0 {
			common = append(common, br...)
			continue
		}
		in := map[any]bool{}
		for _, r := range br {
			in[r] = true
		}
		kept := common[:0]
		for _, r := range common {
			if in[r] {
				kept = append(kept, r)
			}
		}
		common = kept
	}
	for _, k := range order {
		if vs := from[k]; len(vs) == 1 {
			props[k] = vs[0]
		} else {
			props[k] = map[string]any{"anyOf": vs}
		}
	}
	seen := map[string]bool{}
	var merged []any
	for _, r := range append(required, common...) {
		if name, ok := r.(string); ok {
			if seen[name] {
				continue
			}
			seen[name] = true
		}
		merged = append(merged, r)
	}
	required = merged
	ps["type"] = "object"
	ps["properties"] = props
	if len(required) > 0 {
		ps["required"] = required
	} else {
		delete(ps, "required")
	}
	return true
}

func nestedUnion(b map[string]any) bool {
	for _, k := range []string{"anyOf", "oneOf", "allOf"} {
		if _, ok := b[k]; ok {
			return true
		}
	}
	return false
}

func appendDistinct(vs []any, v any) []any {
	vb, _ := json.Marshal(v)
	for _, w := range vs {
		if wb, _ := json.Marshal(w); bytes.Equal(vb, wb) {
			return vs
		}
	}
	return append(vs, v)
}

func grokRef(root, b map[string]any) map[string]any {
	ref, _ := b["$ref"].(string)
	if ref == "" {
		return b
	}
	for _, k := range []string{"$defs", "definitions"} {
		if name, ok := strings.CutPrefix(ref, "#/"+k+"/"); ok {
			defs, _ := root[k].(map[string]any)
			d, _ := defs[name].(map[string]any)
			return d
		}
	}
	return nil
}
