module lsp::generic_binding_test;

import lsp, lsp::analysis::hover, lsp::analysis::completion, lsp::analysis::signature_help, uri;

const String SOURCE = "module app;\nimport box;\nstruct Entry { int node; }\nalias EntryBox = Box{Entry};\nalias BoxBox = Box{EntryBox};\nalias Fixed = Arr{Entry, 4};\nfn void main()\n{\n\tEntryBox b;\n\tint a1 = b.value.node;\n\tint a2 = b.get().node;\n\tint a3 = b[0].node;\n\tBoxBox bb;\n\tint a4 = bb.value.value.node;\n\tFixed fx;\n\tint a5 = fx.items[1].node;\n\tEntry[] arr = { {} };\n\tint a6 = box::first{Entry}(arr).node;\n\tforeach (e : b) { int a7 = e.node; }\n\tb.push({});\n\tint a8 = box::wrap{Entry}({}).value.node;\n}\nmodule box <Type>;\nstruct Box { Type value; }\nfn void Box.push(&self, Type element) { self.value = element; }\nfn Type Box.get(&self) => self.value;\nfn Type Box.at(&self, sz i) @operator([]) => self.value;\nfn sz Box.len(&self) @operator(len) => 1;\nfn Type first(Type[] items) => items[0];\nfn Box wrap(Type v) => { v };\nmodule box <Type, SIZE>;\nstruct Arr { Type[SIZE] items; }\n";

macro LspProject* open_source()
{
	LspProject* proj = mem::new(LspProject);
	proj.init(mem);
	proj.workspace.process_file("/virtual/generic_binding.c3", SOURCE);
	return proj;
}

macro void close(LspProject* proj)
{
	proj.free();
	mem::free(proj);
}

fn void own_generic_type_in_a_return_is_the_instance() @test
{
	LspProject* proj = open_source();
	defer close(proj);
	String h = hover::hover(proj, uri::from_file_path(tmem, "/virtual/generic_binding.c3"), { 20, 39 })!!;
	assert(h.starts_with("```c3\nint node\n```"), "hover: %s", h);
}

fn void completion_on_an_instance_lists_its_fields() @test
{
	LspProject* proj = open_source();
	defer close(proj);
	bool found;
	foreach (item : completion::resolve(proj, uri::from_file_path(tmem, "/virtual/generic_binding.c3"), { 19, 3 })!!)
	{
		if (item.label == "value") found = true;
	}
	assert(found);
}

fn void signature_help_binds_the_instance() @test
{
	LspProject* proj = open_source();
	defer close(proj);
	SignatureHelpResult res = signature_help::signature_help(proj, uri::from_file_path(tmem, "/virtual/generic_binding.c3"), { 19, 8 })!!;
	assert(res.signatures.len == 1);
	test::eq(res.signatures[0].parameters[0].label, "Entry element");
	assert(res.signatures[0].label.contains("Entry element"), "label: %s", res.signatures[0].label);
}

fn void signature_help_keeps_literals() @test
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();
	String src = "module app;\nimport box;\nstruct Entry { int node; }\nfn void main()\n{\n\tBox{Entry} b;\n\tb.label(\"hello\");\n}\nmodule box <Type>;\nstruct Box { Type value; }\nfn void Box.label(&self, String name = \"Type\", char c = 'T', Type fallback = {}) {}\n";
	proj.workspace.process_file("/virtual/literals.c3", src);
	SignatureHelpResult res = signature_help::signature_help(&proj, uri::from_file_path(tmem, "/virtual/literals.c3"), { 6, 9 })!!;
	assert(res.signatures.len == 1);
	test::eq(res.signatures[0].label, "fn void Box.label(&self, String name = \"Type\", char c = 'T', Entry fallback = {})");
}

macro String binding_hover(uint line, uint character)
{
	LspProject* proj = open_source();
	defer close(proj);
	return hover::hover(proj, uri::from_file_path(tmem, "/virtual/generic_binding.c3"), { line, character })!!.tcopy();
}

fn void hover_binds_members_of_instances() @test
{
	String h = binding_hover(9, 13);
	assert(h.starts_with("```c3\nEntry value\n```"), "field: %s", h);
	h = binding_hover(19, 4);
	assert(h.contains("fn void Box.push(&self, Entry element)"), "method: %s", h);
	h = binding_hover(11, 11);
	assert(h.contains("fn Entry Box.at(&self, sz i)"), "operator: %s", h);
}
