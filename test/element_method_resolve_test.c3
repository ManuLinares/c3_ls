module lsp::element_method_resolve_test;
import lsp, uri;

const String SOURCE = "module demo;\n\ntypedef Text = inline char[];\nfn bool char.is_x(self) => self == 'x';\nfn bool Text.has_text(self) => self.len > 0;\nalias Vec2f = float[<2>];\nfn bool float.is_big(self) => self > 100;\n\nfn void main()\n{\n\tText t = (Text)\"abc\";\n\tVec2f v = { 1, 2 };\n\tbool a = t.has_text();\n\tfloat b = v.x;\n\tt.is_x();\n\tv.is_big();\n}\n";

fn String hover_at(uint line, uint character) @local
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();
	Uri u = uri::from_file_path(mem, "/virtual/demo.c3");
	defer u.free();
	proj.workspace.process_file("/virtual/demo.c3", SOURCE);
	return hover::hover(&proj, u, { .line = line, .character = character }).tcopy() ?? "";
}

fn usz definitions_at(uint line, uint character) @local
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();
	Uri u = uri::from_file_path(mem, "/virtual/demo.c3");
	defer u.free();
	proj.workspace.process_file("/virtual/demo.c3", SOURCE);
	return (definition::goto_definition(&proj, u, { .line = line, .character = character }) ?? {}).len;
}

fn void typedef_of_slice_does_not_resolve_element_methods() @test
{
	String hover = hover_at(14, 4);
	assert(!hover.contains("char.is_x"), "%s", hover);
	test::eq(definitions_at(14, 4), (usz)0);
}

fn void vector_alias_does_not_resolve_element_methods() @test
{
	String hover = hover_at(15, 4);
	assert(!hover.contains("float.is_big"), "%s", hover);
	test::eq(definitions_at(15, 4), (usz)0);
}

fn void typedef_own_method_resolves() @test
{
	String hover = hover_at(12, 13);
	assert(hover.contains("Text.has_text"), "%s", hover);
	test::eq(definitions_at(12, 13), (usz)1);
}
