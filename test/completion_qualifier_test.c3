module lsp::completion_qualifier_test @test;

import lsp::core;
import lsp::analysis::completion;
import lsp;
import uri;

const String QUALIFIER_SOURCE = `module asd;

fn void main()
{
	somefu
	globa
	CONST_
	OOP
	plainma
	dad
	Thin
	builtin_f
	@ma
	@bm
}

fn void dada() {}

module asd::lala;

fn void somefunc() {}
int global_val;
const int CONST_VAL = 1;
faultdef OOPS;
macro void plainmac() {}
struct Thing { int x; }
fn void builtin_fn() @builtin {}
macro void @mac() {}
macro void @bmac() @builtin {}
`;

macro CompletionItem item_at(String label, uint line, uint character)
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();
	proj.workspace.process_file("/virtual/qualifier.c3", QUALIFIER_SOURCE);
	Uri doc_uri = uri::from_file_path(tmem, "/virtual/qualifier.c3");
	foreach (item : completion::resolve(&proj, doc_uri, { .line = line, .character = character })!!)
	{
		if (item.label == label) return item;
	}
	unreachable("No completion '%s' at %d:%d", label, line, character);
}

macro String insert_text_at(String label, uint line, uint character)
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();
	proj.workspace.process_file("/virtual/qualifier.c3", QUALIFIER_SOURCE);
	Uri doc_uri = uri::from_file_path(tmem, "/virtual/qualifier.c3");
	foreach (item : completion::resolve(&proj, doc_uri, { .line = line, .character = character })!!)
	{
		if (item.label == label) return item.insertText.tcopy();
	}
	unreachable("No completion '%s' at %d:%d", label, line, character);
}

fn void other_module_function_gets_module_prefix() @test
{
	test::eq(insert_text_at("somefunc", 4, 7), "lala::somefunc();");
}

fn void other_module_globals_and_faults_get_module_prefix() @test
{
	test::eq(insert_text_at("global_val", 5, 6), "lala::global_val");
	test::eq(insert_text_at("CONST_VAL", 6, 7), "lala::CONST_VAL");
	test::eq(insert_text_at("OOPS", 7, 4), "lala::OOPS");
}

fn void other_module_macro_gets_module_prefix() @test
{
	test::eq(insert_text_at("plainmac", 8, 8), "lala::plainmac();");
}

fn void same_module_function_has_no_prefix() @test
{
	test::eq(insert_text_at("dada", 9, 4), "dada();");
}

fn void types_and_builtins_have_no_prefix() @test
{
	test::eq(insert_text_at("Thing", 10, 5), "Thing");
	test::eq(insert_text_at("builtin_fn", 11, 10), "builtin_fn();");
}

fn void typed_at_macro_from_other_module_replaces_the_typed_range() @test
{
	CompletionItem item = item_at("@mac", 12, 4);
	assert(item.textEdit != null);
	test::eq(item.textEdit.newText, "lala::@mac();");
	assert(item.textEdit.range.start.line == 12, "%d", item.textEdit.range.start.line);
	assert(item.textEdit.range.start.character == 1, "%d", item.textEdit.range.start.character);
	assert(item.textEdit.range.end.character == 4, "%d", item.textEdit.range.end.character);
	test::eq(item.filterText, "@mac");
}

fn void same_module_items_have_no_text_edit() @test
{
	assert(item_at("dada", 9, 4).textEdit == null);
}

fn void builtin_macro_has_no_prefix() @test
{
	CompletionItem item = item_at("@bmac", 13, 4);
	assert(item.textEdit == null);
	test::eq(item.insertText, "bmac();");
}
