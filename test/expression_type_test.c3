module lsp::expression_type_test;

import lsp, uri;

const String SOURCE = `
module app::ops;
typedef Clock = ulong;
typedef NanoDuration = long;
struct Vec2
{
	float x;
	float y;
}
struct Bag
{
	Vec2[] items;
}
fn long NanoDuration.to_ms(self) => (long)self / 1_000_000;
fn NanoDuration Clock.diff(self, Clock other) @operator(-) => (NanoDuration)((ulong)self - (ulong)other);
fn Clock Clock.sub(self, NanoDuration d) @operator(-) => (Clock)((ulong)self - (ulong)d);
fn Vec2 Vec2.add(self, Vec2 o) @operator(+) => { self.x + o.x, self.y + o.y };
fn Vec2 Vec2.scale(self, float f) @operator_s(*) => { self.x * f, self.y * f };
fn Vec2 Bag.get(&self, sz i) @operator([]) => self.items[i];
fn sz Bag.len(&self) @operator(len) => self.items.len;
fn int int.twice(self) => self * 2;
fn long long.dbl(self) => self * 2;
const sz FIRST = 0;
fn void main()
{
	Clock now;
	Clock due;
	long ms = (due - now).to_ms();
	Clock earlier = (now - (NanoDuration)5).sub((NanoDuration)1);
	Clock later = (now + 1).sub((NanoDuration)1);
	Vec2 v;
	float fx = (v + v).x + (2.0f * v).y;
	Bag bag;
	foreach (item : bag)
	{
		float z = item.x + bag[0].y;
	}
	char c;
	short s;
	uint u;
	long l;
	int a = (c + s).twice() + (int)(u + l).dbl();
	Vec2* vp = &v;
	float px = (*vp).x + vp[0].x + (&v).y;
	Vec2[] vs;
	float sx = vs[0].x + vs[1..2][0].x;
	bool ok;
	sz n;
	float tx = vs[ok ? 0 : 1].x + vs[n ?: 1].x + vs[app::ops::FIRST].x;
	sz sl = vs[ok ? 0 : 1 .. 2].len;
	float tail = vs[^1].y + vs[^2..].len;
	foreach (int k, Vec2 copy : vs) fx = copy.x + k;
	foreach (&ref : vs)
	{
		float q = (*ref).y;
	}
}
`;

fn LspPosition at(String needle, sz offset = 0)
{
	sz index = SOURCE.index_of(needle)!!;
	String before = SOURCE[:index];
	sz line_start = (before.rindex_of_char('\n') ?? -1) + 1;
	return { .line = (uint)before.count("\n"), .character = (uint)(index - line_start + offset) };
}

macro @with_project(; @body(LspProject* proj, Uri u))
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();
	proj.workspace.process_file("/virtual/ops.c3", SOURCE);
	@body(&proj, uri::from_file_path(tmem, "/virtual/ops.c3"));
}

fn String hover_at(LspProject* proj, Uri u, String needle, sz offset = 0) => hover::hover(proj, u, at(needle, offset)) ?? "";

fn void operator_overloads_type_binary_expressions() @test
{
	@with_project(; LspProject* proj, Uri u)
	{
		assert(hover_at(proj, u, "to_ms();").contains("fn long NanoDuration.to_ms(self)"));
		assert(hover_at(proj, u, "sub((NanoDuration)1);\n\tClock later").contains("fn Clock Clock.sub("));
		assert(hover_at(proj, u, "x + (2.0f").contains("float x"));
		assert(hover_at(proj, u, "y;\n\tBag").contains("float y"));
	};
}

fn void numeric_operands_are_promoted() @test
{
	@with_project(; LspProject* proj, Uri u)
	{
		assert(hover_at(proj, u, "twice() +").contains("fn int int.twice(self)"));
		assert(hover_at(proj, u, "dbl()").contains("fn long long.dbl(self)"));
		assert(hover_at(proj, u, "sub((NanoDuration)1);\n\tVec2").contains("fn Clock Clock.sub("));
	};
}

fn void indexing_and_foreach_use_element_type() @test
{
	@with_project(; LspProject* proj, Uri u)
	{
		assert(hover_at(proj, u, "x + bag[0]").contains("float x"));
		assert(hover_at(proj, u, "y;\n\t}").contains("float y"));
		assert(hover_at(proj, u, "x + vs[1").contains("float x"));
		assert(hover_at(proj, u, "x;\n\tbool ok").contains("float x"));
	};
}

fn void pointer_operators_keep_pointee_type() @test
{
	@with_project(; LspProject* proj, Uri u)
	{
		assert(hover_at(proj, u, "x + vp[0]").contains("float x"));
		assert(hover_at(proj, u, "x + (&v)").contains("float x"));
		assert(hover_at(proj, u, "y;\n\tVec2[]").contains("float y"));
	};
}

fn bool completes(LspProject* proj, Uri u, String needle, String label)
{
	foreach (item : completion::resolve(proj, u, at(needle))!!)
	{
		if (item.label == label) return true;
	}
	return false;
}

fn void completion_tells_index_from_slice() @test
{
	@with_project(; LspProject* proj, Uri u)
	{
		assert(completes(proj, u, "x + vs[n", "x") && !completes(proj, u, "x + vs[n", "len"));
		assert(completes(proj, u, "x + vs[app", "x"));
		assert(completes(proj, u, "x;\n\tsz sl", "x"));
		assert(completes(proj, u, "len;\n\tfloat tail", "len") && !completes(proj, u, "len;\n\tfloat tail", "x"));
	};
}

fn void from_end_index_and_reference_foreach() @test
{
	@with_project(; LspProject* proj, Uri u)
	{
		assert(hover_at(proj, u, "y + vs[^2").contains("float y"));
		assert(completes(proj, u, "len;\n\tforeach", "len") && !completes(proj, u, "len;\n\tforeach", "y"));
		assert(hover_at(proj, u, "y;\n\t}\n}").contains("float y"));
	};
}

fn void completion_types_receivers_in_crlf_files() @test
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();
	String source = "module app;\r\nstruct Vec2\r\n{\r\n\tfloat x;\r\n}\r\nfn void main()\r\n{\r\n\tVec2[] vs;\r\n\tbool ok;\r\n\tfloat a = vs[ok ? 0 : 1].x;\r\n}\r\n";
	proj.workspace.process_file("/virtual/crlf.c3", source);
	Uri u = uri::from_file_path(tmem, "/virtual/crlf.c3");
	bool found;
	foreach (item : completion::resolve(&proj, u, { .line = 9, .character = 27 })!!)
	{
		if (item.label == "x") found = true;
	}
	assert(found);
}

fn void edited_out_methods_stop_resolving() @test
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();
	String with_method = "module app;\nstruct Vec2\n{\n\tfloat x;\n}\nfn float Vec2.len2(self) => self.x;\nfn void main()\n{\n\tVec2 v;\n\tfloat a = v.len2();\n}\n";
	String without = "module app;\nstruct Vec2\n{\n\tfloat x;\n}\nfn void main()\n{\n\tVec2 v;\n\tfloat a = v.len2();\n}\n";
	Uri u = uri::from_file_path(tmem, "/virtual/edit.c3");
	proj.workspace.process_file("/virtual/edit.c3", with_method);
	assert((hover::hover(&proj, u, { .line = 9, .character = 14 }) ?? "").contains("Vec2.len2"));
	proj.workspace.process_file("/virtual/edit.c3", without);
	assert(!(hover::hover(&proj, u, { .line = 8, .character = 14 }) ?? "").contains("Vec2.len2"));
}

fn void vector_methods_resolve_by_element_type() @test
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();
	String source = `module app::vec;
macro double double[<*>].total(double[<*>] x) => x[0];
macro float float[<*>].total(float[<*>] x) => x[0];

module app::shape <Num>;
import app::vec;
struct Box
{
	Num[<2>] size;
}
fn Num Box.area(self) => (Num)self.size.total();

module app;
import app::vec, app::shape;
fn void main()
{
	double[<3>] f;
	double t = f.total();
}
`;
	proj.workspace.process_file("/virtual/vec.c3", source);
	Uri u = uri::from_file_path(tmem, "/virtual/vec.c3");
	sz exact = source.index_of("total();\n}")!!;
	sz generic = source.index_of("total();\n\nmodule")!!;
	assert((hover::hover(&proj, u, { .line = (uint)source[:exact].count("\n"), .character = 14 }) ?? "").contains("double[<*>].total"));
	LspPosition at_generic = { .line = (uint)source[:generic].count("\n"), .character = 41 };
	assert((hover::hover(&proj, u, at_generic) ?? "").contains("Declared for `double[<*>]`, `float[<*>]`"));
	assert(definition::goto_definition(&proj, u, at_generic)!!.len == 2);
	assert(!(hover::hover(&proj, u, at_generic) ?? "").contains("Macro Expansion"));
}

fn void hover_shows_foreach_binding_types() @test
{
	@with_project(; LspProject* proj, Uri u)
	{
		assert(hover_at(proj, u, "item : bag").contains("Vec2 item"), "%s", hover_at(proj, u, "item : bag"));
		assert(hover_at(proj, u, "ref : vs").contains("Vec2* ref"));
		assert(hover_at(proj, u, "k, Vec2").contains("int k"));
		assert(hover_at(proj, u, "copy : vs").contains("Vec2 copy"));
	};
}
