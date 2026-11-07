module lsp::rename_test;

import lsp::core;
import lsp::analysis::rename;
import lsp::analysis::references;
import lsp;
import uri;
import std::io;
import std::encoding::json;
import std::collections::list;

// Fixture: a project with named in-memory files. Positions and expected
// edit ranges are expressed as the n-th whole-word occurrence of an
// identifier in a file, so tests stay independent of layout.

struct Fx
{
	LspProject proj;
	List{String} paths;
	List{String} srcs;
}

fn void Fx.init(&self)
{
	self.proj.init(mem);
	self.paths.init(mem);
	self.srcs.init(mem);
}

fn void Fx.free(&self)
{
	self.proj.free();
	self.paths.free();
	self.srcs.free();
}

fn String vpath(String name) => string::tformat("/virtual/%s", name);

fn void Fx.add(&self, String name, String src)
{
	self.paths.push(name);
	self.srcs.push(src);
	self.proj.workspace.process_file(vpath(name), src);
}

fn String Fx.src(&self, String name)
{
	foreach (i, p : self.paths)
	{
		if (p == name) return self.srcs[i];
	}
	unreachable("unknown file %s", name);
}

fn bool is_ident_char(char c) => c.is_alnum() || c == '_' || c == '$' || c == '@' || c == '#';

<* Return position of the n-th whole-word occurrence of `word` in `src`. *>
fn LspPosition word_pos(String src, String word, int nth)
{
	int seen = 0;
	uint line = 0;
	uint col = 0;
	for (usz i = 0; i < src.len; i++)
	{
		if (src[i..].starts_with(word)
			&& (i == 0 || !is_ident_char(src[i - 1]))
			&& (i + word.len >= src.len || !is_ident_char(src[i + word.len])))
		{
			if (seen == nth) return { .line = line, .character = col };
			seen++;
		}
		if (src[i] == '\n')
		{
			line++;
			col = 0;
		}
		else
		{
			col++;
		}
	}
	unreachable("occurrence %d of '%s' not found", nth, word);
}

fn Uri Fx.uri(&self, String name) => uri::from_file_path(tmem, vpath(name));

fn WorkspaceEdit? Fx.rename(&self, String name, String word, int nth, String new_name)
{
	LspPosition pos = word_pos(self.src(name), word, nth);
	pos.character += 1; // cursor inside the token, not on its first char
	return rename::rename(&self.proj, self.uri(name), pos, new_name);
}

fn LspRange? Fx.prepare(&self, String name, String word, int nth)
{
	LspPosition pos = word_pos(self.src(name), word, nth);
	return rename::prepare_rename(&self.proj, self.uri(name), pos);
}

fn String edit_key(String file, LspRange r) => string::tformat("%s:%d:%d-%d:%d", file, r.start.line, r.start.character, r.end.line, r.end.character);

fn String Fx.file_of(&self, String raw_uri)
{
	foreach (p : self.paths)
	{
		if (self.uri(p).to_raw_string(tmem) == raw_uri) return p;
	}
	return raw_uri;
}

<* All edits as "file:l:c-l:c" keys, asserting each replaces `old` with `new_name`. *>
fn List{String} Fx.edit_keys(&self, WorkspaceEdit e, String old, String new_name)
{
	List{String} keys;
	keys.tinit();
	foreach (dc : e.documentChanges)
	{
		String file = self.file_of(dc.textDocument.uri);
		foreach (te : dc.edits)
		{
			assert(te.newText == new_name, "edit text '%s' != '%s'", te.newText, new_name);
			String key = edit_key(file, te.range);
			assert(!keys.contains(key), "duplicate edit %s", key);
			keys.push(key);
		}
	}
	return keys;
}

<* Assert the edit set is exactly the listed occurrences of `old`. *>
fn void Fx.expect(&self, WorkspaceEdit e, String old, String new_name, String[] files, int[][] nths)
{
	List{String} got = self.edit_keys(e, old, new_name);
	List{String} want;
	want.tinit();
	foreach (fi, file : files)
	{
		foreach (n : nths[fi])
		{
			LspPosition p = word_pos(self.src(file), old, n);
			LspRange r = { .start = p, .end = { .line = p.line, .character = p.character + (uint)old.len } };
			want.push(edit_key(file, r));
		}
	}
	foreach (k : want)
	{
		assert(got.contains(k), "missing edit %s; got %s", k, got);
	}
	foreach (k : got)
	{
		assert(want.contains(k), "unexpected edit %s; want %s", k, want);
	}
}

// ---------------------------------------------------------------------------
// Locals and parameters
// ---------------------------------------------------------------------------

fn void local_var_does_not_leak_into_other_function() @test
{
	Fx fx;
	fx.init();
	defer fx.free();
	fx.add("a.c3", `module t;
fn void a()
{
	int val = 1;
	val += 2;
	int y = val;
}
fn void b()
{
	int val = 3;
	val++;
}
`);
	WorkspaceEdit e = fx.rename("a.c3", "val", 1, "v2")!!;
	fx.expect(e, "val", "v2", { "a.c3" }, { { 0, 1, 2 } });

	e = fx.rename("a.c3", "val", 3, "v3")!!;
	fx.expect(e, "val", "v3", { "a.c3" }, { { 3, 4 } });
}

fn void parameter_rename() @test
{
	Fx fx;
	fx.init();
	defer fx.free();
	fx.add("a.c3", `module t;
fn int twice(int n)
{
	return n + n;
}
fn void other()
{
	int n = 1;
	n++;
}
`);
	WorkspaceEdit e = fx.rename("a.c3", "n", 0, "k")!!;
	fx.expect(e, "n", "k", { "a.c3" }, { { 0, 1, 2 } });
}

fn void local_shadowing_global() @test
{
	Fx fx;
	fx.init();
	defer fx.free();
	fx.add("a.c3", `module t;
int g = 0;
fn void a()
{
	int g = 1;
	g++;
}
fn void b()
{
	g++;
}
`);
	WorkspaceEdit e = fx.rename("a.c3", "g", 0, "glob")!!;
	fx.expect(e, "g", "glob", { "a.c3" }, { { 0, 3 } });

	e = fx.rename("a.c3", "g", 2, "loc")!!;
	fx.expect(e, "g", "loc", { "a.c3" }, { { 1, 2 } });
}

// ---------------------------------------------------------------------------
// Globals, functions, cross-module
// ---------------------------------------------------------------------------

fn void global_same_name_other_module_untouched() @test
{
	Fx fx;
	fx.init();
	defer fx.free();
	fx.add("a.c3", `module mod_a;
int counter;
fn void inc() { counter++; }
`);
	fx.add("b.c3", `module mod_b;
int counter;
fn void inc2() { counter++; }
`);
	WorkspaceEdit e = fx.rename("a.c3", "counter", 0, "cnt")!!;
	fx.expect(e, "counter", "cnt", { "a.c3" }, { { 0, 1 } });
}

fn void function_cross_file_with_qualified_call() @test
{
	Fx fx;
	fx.init();
	defer fx.free();
	fx.add("lib.c3", `module math_lib;
fn int compute(int x) { return x * 2; }
`);
	fx.add("other.c3", `module other_lib;
fn int compute(int x) { return x; }
fn void use() { compute(1); }
`);
	fx.add("app.c3", `module app;
import math_lib;
fn void main()
{
	int r = math_lib::compute(5);
	int s = math_lib::compute(6);
}
`);
	// From declaration.
	WorkspaceEdit e = fx.rename("lib.c3", "compute", 0, "calc")!!;
	fx.expect(e, "compute", "calc", { "lib.c3", "app.c3" }, { { 0 }, { 0, 1 } });

	// From a qualified call site.
	e = fx.rename("app.c3", "compute", 1, "calc")!!;
	fx.expect(e, "compute", "calc", { "lib.c3", "app.c3" }, { { 0 }, { 0, 1 } });

	// The unrelated function.
	e = fx.rename("other.c3", "compute", 1, "calc")!!;
	fx.expect(e, "compute", "calc", { "other.c3" }, { { 0, 1 } });
}

fn void constant_rename() @test
{
	Fx fx;
	fx.init();
	defer fx.free();
	fx.add("a.c3", `module t;
const int LIMIT = 10;
fn int f() { return LIMIT * 2; }
`);
	WorkspaceEdit e = fx.rename("a.c3", "LIMIT", 1, "MAX")!!;
	fx.expect(e, "LIMIT", "MAX", { "a.c3" }, { { 0, 1 } });
}

fn void macro_rename() @test
{
	Fx fx;
	fx.init();
	defer fx.free();
	fx.add("a.c3", `module t;
macro square(x) { return x * x; }
fn int f() { return square(3); }
`);
	WorkspaceEdit e = fx.rename("a.c3", "square", 1, "sq")!!;
	fx.expect(e, "square", "sq", { "a.c3" }, { { 0, 1 } });
}

fn void faultdef_rename() @test
{
	Fx fx;
	fx.init();
	defer fx.free();
	fx.add("a.c3", `module t;
faultdef NOT_READY;
fn void? f() { return NOT_READY~; }
`);
	WorkspaceEdit e = fx.rename("a.c3", "NOT_READY", 1, "BUSY")!!;
	fx.expect(e, "NOT_READY", "BUSY", { "a.c3" }, { { 0, 1 } });
}

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

fn void struct_type_cross_file() @test
{
	Fx fx;
	fx.init();
	defer fx.free();
	fx.add("shapes.c3", `module shapes;
struct Point { int x; int y; }
fn Point make(Point p)
{
	Point q = p;
	return q;
}
`);
	fx.add("user.c3", `module user;
import shapes;
fn void f()
{
	Point a = shapes::make({ 1, 2 });
	shapes::Point b = a;
}
`);
	fx.add("unrelated.c3", `module unrelated;
struct Point { float x; }
fn void g() { Point z; }
`);
	WorkspaceEdit e = fx.rename("shapes.c3", "Point", 0, "Pt")!!;
	fx.expect(e, "Point", "Pt", { "shapes.c3", "user.c3" }, { { 0, 1, 2, 3 }, { 0, 1 } });

	// From a usage site.
	e = fx.rename("user.c3", "Point", 1, "Pt")!!;
	fx.expect(e, "Point", "Pt", { "shapes.c3", "user.c3" }, { { 0, 1, 2, 3 }, { 0, 1 } });

	e = fx.rename("unrelated.c3", "Point", 1, "P2")!!;
	fx.expect(e, "Point", "P2", { "unrelated.c3" }, { { 0, 1 } });
}

fn void alias_rename() @test
{
	Fx fx;
	fx.init();
	defer fx.free();
	fx.add("a.c3", `module t;
alias Handle = int;
fn Handle f(Handle h) { return h; }
`);
	WorkspaceEdit e = fx.rename("a.c3", "Handle", 0, "Id")!!;
	fx.expect(e, "Handle", "Id", { "a.c3" }, { { 0, 1, 2 } });
}

fn void typedef_cross_file() @test
{
	Fx fx;
	fx.init();
	defer fx.free();
	fx.add("types.c3", `module types;
typedef MyHandle = int;
`);
	fx.add("consumer.c3", `module consumer;
import types;
fn void process_handle(MyHandle h)
{
	MyHandle copy = h;
}
`);
	WorkspaceEdit e = fx.rename("types.c3", "MyHandle", 0, "NativeHandle")!!;
	fx.expect(e, "MyHandle", "NativeHandle", { "types.c3", "consumer.c3" }, { { 0 }, { 0, 1 } });
}

fn void enum_type_and_values() @test
{
	Fx fx;
	fx.init();
	defer fx.free();
	fx.add("a.c3", `module t;
enum Color { RED, GREEN }
fn void f()
{
	Color c = RED;
	Color d = Color.GREEN;
	if (c == Color.RED) {}
}
`);
	WorkspaceEdit e = fx.rename("a.c3", "Color", 0, "Hue")!!;
	fx.expect(e, "Color", "Hue", { "a.c3" }, { { 0, 1, 2, 3, 4 } });

	e = fx.rename("a.c3", "RED", 0, "CRIMSON")!!;
	fx.expect(e, "RED", "CRIMSON", { "a.c3" }, { { 0, 1, 2 } });

	e = fx.rename("a.c3", "GREEN", 1, "LIME")!!;
	fx.expect(e, "GREEN", "LIME", { "a.c3" }, { { 0, 1 } });
}

fn void interface_rename() @test
{
	Fx fx;
	fx.init();
	defer fx.free();
	fx.add("a.c3", `module t;
interface Shape { fn float area(); }
struct Sq (Shape) { float s; }
fn float Sq.area(&self) @dynamic { return self.s * self.s; }
fn void f(Shape sh) {}
`);
	WorkspaceEdit e = fx.rename("a.c3", "Shape", 0, "Figure")!!;
	fx.expect(e, "Shape", "Figure", { "a.c3" }, { { 0, 1, 2 } });
}

// ---------------------------------------------------------------------------
// Members and methods
// ---------------------------------------------------------------------------

fn void struct_field_rename() @test
{
	Fx fx;
	fx.init();
	defer fx.free();
	fx.add("a.c3", `module t;
struct Vec { int x; int y; }
fn int f(Vec v)
{
	int x = v.x;
	Vec w = { .x = 1, .y = 2 };
	return x + w.x;
}
`);
	// Field: declaration, v.x, designator, w.x.
	WorkspaceEdit e = fx.rename("a.c3", "x", 0, "px")!!;
	fx.expect(e, "x", "px", { "a.c3" }, { { 0, 2, 3, 5 } });

	// From an access site.
	e = fx.rename("a.c3", "x", 2, "px")!!;
	fx.expect(e, "x", "px", { "a.c3" }, { { 0, 2, 3, 5 } });

	// Local `x` must not pick up the field.
	e = fx.rename("a.c3", "x", 1, "lx")!!;
	fx.expect(e, "x", "lx", { "a.c3" }, { { 1, 4 } });
}

fn void struct_field_cross_file() @test
{
	Fx fx;
	fx.init();
	defer fx.free();
	fx.add("geo.c3", `module geo;
struct Size { int width; }
`);
	fx.add("use.c3", `module use;
import geo;
fn int area(Size s) { return s.width * s.width; }
`);
	WorkspaceEdit e = fx.rename("geo.c3", "width", 0, "w")!!;
	fx.expect(e, "width", "w", { "geo.c3", "use.c3" }, { { 0 }, { 0, 1 } });
}

fn void method_rename() @test
{
	Fx fx;
	fx.init();
	defer fx.free();
	fx.add("a.c3", `module t;
struct Counter { int n; }
fn void Counter.bump(&self) { self.n++; }
fn void bump() {}
fn void use()
{
	Counter c;
	c.bump();
	bump();
}
`);
	WorkspaceEdit e = fx.rename("a.c3", "bump", 2, "incr")!!;
	fx.expect(e, "bump", "incr", { "a.c3" }, { { 0, 2 } });

	e = fx.rename("a.c3", "bump", 0, "incr")!!;
	fx.expect(e, "bump", "incr", { "a.c3" }, { { 0, 2 } });

	// Plain function of the same name.
	e = fx.rename("a.c3", "bump", 1, "other")!!;
	fx.expect(e, "bump", "other", { "a.c3" }, { { 1, 3 } });

	// Type used as method receiver prefix.
	e = fx.rename("a.c3", "Counter", 0, "Tally")!!;
	fx.expect(e, "Counter", "Tally", { "a.c3" }, { { 0, 1, 2 } });
}

// ---------------------------------------------------------------------------
// prepareRename
// ---------------------------------------------------------------------------

fn void prepare_rename_ranges() @test
{
	Fx fx;
	fx.init();
	defer fx.free();
	String src = `module t;
struct Vec { int x; }
fn void Vec.grow(&self) {}
fn int f(Vec v)
{
	v.grow();
	return v.x + 42;
}
`;
	fx.add("a.c3", src);

	String[4] words = { "x", "grow", "Vec", "v" };
	foreach (w : words)
	{
		LspPosition p = word_pos(src, w, 1);
		LspRange r = fx.prepare("a.c3", w, 1)!!;
		assert(r.start.line == p.line && r.start.character == p.character, "prepare '%s' start %s", w, r.start);
		assert(r.end.line == p.line && r.end.character == p.character + w.len, "prepare '%s' end %s", w, r.end);
	}

	assert(@catch(fx.prepare("a.c3", "fn", 0)) == NOT_FOUND);
	assert(@catch(fx.prepare("a.c3", "42", 0)) == NOT_FOUND);
	assert(@catch(fx.prepare("a.c3", "return", 0)) == NOT_FOUND);
}

fn void prepare_rename_on_comment_fails() @test
{
	Fx fx;
	fx.init();
	defer fx.free();
	fx.add("a.c3", `module t;
fn void main()
{
	// empty comment
}
`);
	assert(@catch(fx.prepare("a.c3", "empty", 0)) == NOT_FOUND);
}

// ---------------------------------------------------------------------------
// Protocol shape
// ---------------------------------------------------------------------------

fn void rename_empty_name_fails() @test
{
	Fx fx;
	fx.init();
	defer fx.free();
	fx.add("a.c3", `module t;
int g;
`);
	assert(@catch(fx.rename("a.c3", "g", 0, "")));
}

fn void rename_edit_has_null_version() @test
{
	Fx fx;
	fx.init();
	defer fx.free();
	fx.add("a.c3", `module t;
int g;
fn void f() { g++; }
`);
	WorkspaceEdit e = fx.rename("a.c3", "g", 0, "h")!!;
	String js = json::marshal(tmem, e, NONE);
	// A numeric version makes clients reject the edit when it does not
	// match the open document; the server does not track versions.
	assert(js.contains(`"version":null`), "%s", js);
}

// ---------------------------------------------------------------------------
// Edge cases
// ---------------------------------------------------------------------------

fn void prepare_rename_rejects_primitive_and_module() @test
{
	Fx fx;
	fx.init();
	defer fx.free();
	fx.add("lib.c3", `module math_lib;
fn int compute(int x) { return x; }
`);
	fx.add("app.c3", `module app;
import math_lib;
fn void main() { int r = math_lib::compute(1); }
`);
	assert(@catch(fx.prepare("app.c3", "int", 0)) == NOT_FOUND);
	assert(@catch(fx.prepare("app.c3", "math_lib", 1)) == NOT_FOUND);
}

fn void qualified_name_cursor_at_first_char() @test
{
	Fx fx;
	fx.init();
	defer fx.free();
	String app = `module app;
import math_lib;
fn void main() { int r = math_lib::compute(1); }
`;
	fx.add("lib.c3", `module math_lib;
fn int compute(int x) { return x; }
`);
	fx.add("app.c3", app);
	LspPosition p = word_pos(app, "compute", 0);
	LspRange r = rename::prepare_rename(&fx.proj, fx.uri("app.c3"), p)!!;
	assert(r.start.character == p.character && r.end.character == p.character + 7);
	WorkspaceEdit e = rename::rename(&fx.proj, fx.uri("app.c3"), p, "calc")!!;
	fx.expect(e, "compute", "calc", { "lib.c3", "app.c3" }, { { 0 }, { 0 } });
}

fn void faultdef_multiple() @test
{
	Fx fx;
	fx.init();
	defer fx.free();
	fx.add("a.c3", `module t;
faultdef BAD_A, BAD_B;
fn void? f(int i)
{
	if (i) return BAD_A~;
	return BAD_B~;
}
`);
	WorkspaceEdit e = fx.rename("a.c3", "BAD_B", 0, "WORSE")!!;
	fx.expect(e, "BAD_B", "WORSE", { "a.c3" }, { { 0, 1 } });
	e = fx.rename("a.c3", "BAD_A", 1, "WORST")!!;
	fx.expect(e, "BAD_A", "WORST", { "a.c3" }, { { 0, 1 } });
}

fn void designator_nested_and_compound_literal() @test
{
	Fx fx;
	fx.init();
	defer fx.free();
	fx.add("a.c3", `module t;
struct Inner { int v; }
struct Outer { Inner in; int v; }
fn Outer f()
{
	Outer a = { .in = { .v = 1 }, .v = 2 };
	Outer b = { .in.v = 3 };
	Inner c = (Inner){ .v = 4 };
	return { .v = 5 };
}
`);
	// Inner.v: decl, nested list, chained designator, compound literal.
	WorkspaceEdit e = fx.rename("a.c3", "v", 0, "val")!!;
	fx.expect(e, "v", "val", { "a.c3" }, { { 0, 2, 4, 5 } });

	// Outer.v: decl, outer list, return-statement list.
	e = fx.rename("a.c3", "v", 1, "val")!!;
	fx.expect(e, "v", "val", { "a.c3" }, { { 1, 3, 6 } });

	// Outer.in from the chained designator.
	e = fx.rename("a.c3", "in", 2, "inner")!!;
	fx.expect(e, "in", "inner", { "a.c3" }, { { 0, 1, 2 } });
}

fn void references_match_rename() @test
{
	Fx fx;
	fx.init();
	defer fx.free();
	fx.add("a.c3", `module t;
struct Rec { int f; }
fn int g(Rec r) { return r.f + r.f; }
`);
	LspPosition p = word_pos(fx.src("a.c3"), "f", 0);
	LspLocation[] with_decl = references::find_references(&fx.proj, fx.uri("a.c3"), p, { .includeDeclaration = true })!!;
	LspLocation[] without = references::find_references(&fx.proj, fx.uri("a.c3"), p, { .includeDeclaration = false })!!;
	assert(with_decl.len == 3, "%d", with_decl.len);
	assert(without.len == 2, "%d", without.len);
}

fn void designator_in_call_arguments() @test
{
	Fx fx;
	fx.init();
	defer fx.free();
	fx.add("a.c3", `module t;
struct Vec { int x; int y; }
fn int draw(int n, Vec v) { return n + v.x; }
fn int Vec.add(&self, Vec o) { return self.x + o.x; }
macro int mdraw(Vec v) { return v.x; }
fn void main()
{
	int x = 0;
	Vec a;
	draw(1, { .x = 1, .y = 2 });
	draw(n: 2, v: { .x = 3 });
	a.add({ .x = 4 });
	Vec.add(&a, { .x = 5 });
	mdraw({ .x = 6 });
	a = { .x = 7 };
	x = 8;
}
`);
	// x: 0 field, 1 v.x, 2 self.x, 3 o.x, 4 macro v.x, 5 local,
	// 6 positional arg, 7 named arg, 8 method call (receiver shifts params),
	// 9 static-style method call (no shift), 10 macro arg, 11 assignment,
	// 12 local.
	WorkspaceEdit e = fx.rename("a.c3", "x", 0, "px")!!;
	fx.expect(e, "x", "px", { "a.c3" }, { { 0, 1, 2, 3, 4, 6, 7, 8, 9, 10, 11 } });

	// From each designator site.
	int[6] sites = { 6, 7, 8, 9, 10, 11 };
	foreach (n : sites)
	{
		e = fx.rename("a.c3", "x", n, "px")!!;
		fx.expect(e, "x", "px", { "a.c3" }, { { 0, 1, 2, 3, 4, 6, 7, 8, 9, 10, 11 } });
	}

	// The local `x` excludes every designator.
	e = fx.rename("a.c3", "x", 5, "lx")!!;
	fx.expect(e, "x", "lx", { "a.c3" }, { { 5, 12 } });
}

fn void designator_in_assignment() @test
{
	Fx fx;
	fx.init();
	defer fx.free();
	fx.add("a.c3", `module t;
struct Inner { int v; }
struct Outer { Inner in; int v; }
fn void set(Outer* o)
{
	o.in = { .v = 1 };
	o.v = 2;
	*o = { .v = 3 };
}
fn void main()
{
	Outer o;
	set(&o);
}
`);
	// Inner.v: decl, `o.in = { .v }`.
	WorkspaceEdit e = fx.rename("a.c3", "v", 2, "val")!!;
	fx.expect(e, "v", "val", { "a.c3" }, { { 0, 2 } });

	// Outer.v: decl, `o.v`, `*o = { .v }`.
	e = fx.rename("a.c3", "v", 4, "val")!!;
	fx.expect(e, "v", "val", { "a.c3" }, { { 1, 3, 4 } });
}
