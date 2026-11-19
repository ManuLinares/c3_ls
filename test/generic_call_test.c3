module lsp::generic_call_test;

import lsp, lsp::analysis::hover, lsp::analysis::definition, uri;

const String SOURCE = "module app;\nimport box;\nstruct Entry { int node; int section_id; }\nalias EntryBox = Box{Entry};\nmacro void main()\n{\n\tEntryBox b;\n\tb.push({ .node = 1, .section_id = 0 });\n\tBox{Entry}* pb = &b;\n\tpb.push({ .section_id = 2 });\n\tb.set_all({ { .node = 3 } });\n\tvar f = box::first{Entry}({ { .node = 4 } });\n\tint n = f.node;\n}\nmodule box <Type>;\nstruct Box { Type value; }\nfn void Box.push(&self, Type element) { self.value = element; }\nfn void Box.set_all(&self, Type[] elements) { self.value = elements[0]; }\nfn Type first(Type[] items) => items[0];\n";

macro String hover_at(uint line, uint character)
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();
	proj.workspace.process_file("/virtual/generic_call.c3", SOURCE);
	return hover::hover(&proj, uri::from_file_path(tmem, "/virtual/generic_call.c3"), { line, character })!!.tcopy();
}

macro void assert_field(uint line, uint character, String decl)
{
	String h = hover_at(line, character);
	assert(h.starts_with(string::tformat("```c3\n%s\n```", decl)), "%d:%d hover: %s", line, character, h);
}

fn void designators_in_generic_method_arguments() @test
{
	assert_field(7, 12, "int node");
	assert_field(7, 23, "int section_id");
	assert_field(9, 13, "int section_id");
	assert_field(10, 17, "int node");
}

fn void designators_in_generic_function_arguments() @test
{
	assert_field(11, 33, "int node");
}

fn void generic_function_callee_resolves() @test
{
	String h = hover_at(11, 15);
	assert(h.contains("fn Type first(Type[] items)"), "hover: %s", h);
}

fn void generic_function_call_has_the_instance_type() @test
{
	assert_field(12, 12, "int node");
}
