module lsp::operator_overload_test;

import lsp, lsp::analysis::hover, lsp::analysis::definition, uri;

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
	check(24, 12, { 7, 6 }, "lt");
	check(25, 3, { 8 }, "add_self");
	check(26, 3, { 5 }, "sub");
	check(27, 10, { 9 }, "at");
	check(28, 2, { 10 }, "set");
	check(29, 8, { 11 }, "len");
}
