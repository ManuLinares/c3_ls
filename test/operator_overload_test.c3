module lsp::operator_overload_test;

import lsp, lsp::analysis::hover, lsp::analysis::definition, uri, analyzer::core, analyzer::sema::query;

const String SOURCE = "module app;\nstruct Vec { int x; }\nfn Vec Vec.add(self, Vec o) @operator(+) => { self.x + o.x };\nfn Vec Vec.add_int(self, int i) @operator_s(+) => { self.x + i };\nfn Vec Vec.neg(self) @operator(-) => { -self.x };\nfn Vec Vec.sub(self, Vec o) @operator(-) => { self.x - o.x };\nfn bool Vec.eq(self, Vec o) @operator(==) => self.x == o.x;\nfn bool Vec.lt(self, Vec o) @operator(<) => self.x < o.x;\nfn void Vec.add_self(&self, Vec o) @operator(+=) { self.x += o.x; }\nfn int Vec.at(&self, sz i) @operator([]) => self.x;\nfn void Vec.set(&self, sz i, int v) @operator([]=) { self.x = v; }\nfn sz Vec.len(&self) @operator(len) => 1;\nfn void main()\n{\n\tVec a;\n\tVec b;\n\tVec c = a + b;\n\tVec d = a + 1;\n\tVec e = 1 + a;\n\tVec f = -a;\n\tVec g = a - b;\n\tbool h = a == b;\n\tbool i2 = a != b;\n\tbool j = a > b;\n\tbool k = a <= b;\n\ta += b;\n\ta -= b;\n\tint m = a[0];\n\ta[0] = 2;\n\tsz n = lengthof(a);\n}\n";

<*
 F12 on the operator at `line`:`character` goes to the methods on `lines`, and hover shows `name`.
*>
macro void check(uint line, uint character, uint[] lines, String name)
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();
	proj.workspace.process_file("/virtual/ops.c3", SOURCE);
	Uri u = uri::from_file_path(tmem, "/virtual/ops.c3");
	LspLocation[] locs = definition::goto_definition(&proj, u, { line, character })!!;
	assert(locs.len == lines.len, "%d:%d: %d definitions", line, character, locs.len);
	foreach (i, l : locs) assert(l.range.start.line == lines[i], "%d:%d: definition %d on line %d", line, character, i, l.range.start.line);
	String h = hover::hover(&proj, u, { line, character })!!;
	assert(h.contains(string::tformat("Vec.%s(", name)), "%d:%d hover: %s", line, character, h);
}

fn void operators_go_to_their_overloads() @test
{
	check(16, 11, { 2 }, "add");
	check(17, 11, { 3 }, "add_int");
	check(18, 11, { 3 }, "add_int");
	check(19, 9, { 4 }, "neg");
	check(20, 11, { 5 }, "sub");
	check(21, 12, { 6 }, "eq");
	check(22, 13, { 6 }, "eq");
	check(23, 12, { 7 }, "lt");
	check(24, 12, { 7 }, "lt");
	check(25, 3, { 8 }, "add_self");
	check(26, 3, { 5 }, "sub");
	check(27, 10, { 9 }, "at");
	check(28, 2, { 10 }, "set");
	check(29, 8, { 11 }, "len");
}

fn void the_better_match_wins_as_in_c3c() @test
{
	// The left overload takes any type, the right one an `int` that `Num` converts to: c3c calls the right one.
	String source = "module m;\ntypedef Num = inline int;\nstruct Box { int v; }\nmacro Num Num.add(self, o) @operator(+) => self;\nfn Box Box.radd(self, int o) @operator_r(+) => self;\nfn void main()\n{\n\tNum a;\n\tBox b;\n\tvar c @safeinfer = a + b;\n}\n";
	LspProject proj;
	proj.init(mem);
	defer proj.free();
	proj.workspace.process_file("/virtual/rank.c3", source);
	LspLocation[] locs = definition::goto_definition(&proj, uri::from_file_path(tmem, "/virtual/rank.c3"), { 9, 22 })!!;
	assert(locs.len == 1 && locs[0].range.start.line == 4, "%d definitions", locs.len);
}

fn void typedefs_do_not_take_their_base_overloads() @test
{
	// c3c: "Cannot do the addition 'Pt2' + 'Pt2'" and "Indexing a value of type 'Pt2' is not possible".
	String source = "module m;\nstruct Pt { int x; }\nfn Pt Pt.add(self, Pt o) @operator(+) => { self.x + o.x };\nfn int Pt.at(&self, sz i) @operator([]) => 1;\ntypedef Pt2 = inline Pt;\nalias Pt3 = Pt;\ntypedef Arr = int[4];\nfn void main()\n{\n\tPt2 a;\n\tPt3 b;\n\tPt3 c = b + b;\n}\n";
	LspProject proj;
	proj.init(mem);
	defer proj.free();
	proj.workspace.process_file("/virtual/td.c3", source);
	SourceFile* sf = proj.workspace.get_source_file_by_path("/virtual/td.c3");
	AnalyzerContext* ctx = proj.workspace.ctx;
	assert(!query::operator_method(ctx, sf, "Pt2", OV_PLUS, other: "Pt2").method);
	assert(query::operator_method(ctx, sf, "Pt3", OV_PLUS, other: "Pt3").method);
	test::eq(query::element_type(ctx, sf, "Pt2"), "");
	test::eq(query::element_type(ctx, sf, "Pt3"), "int");
	test::eq(query::element_type(ctx, sf, "Arr"), "int");
}
