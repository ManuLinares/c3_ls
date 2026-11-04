module lsp::completion_baseline_test @test;

import lsp::core;
import lsp::analysis::completion;
import lsp;
import uri;
import std::io;

<*
 Test 1: Enum completion in return statements.
 In a function returning an enum, typing `return `
 must detect the expected type and suggest enum variants at priority 0000_.
*>
fn void test_return_statement_enum_completion()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = `module app;

enum Color {
    RED,
    GREEN,
    BLUE
}

fn Color get_theme() {
    return 
}
`;

	proj.workspace.process_file("/virtual/return_enum.c3", source);
	Uri doc_uri = uri::from_file_path(mem, "/virtual/return_enum.c3");
	defer doc_uri.free();

	// Line 9, col 11: after `return `
	LspPosition pos = { .line = 9, .character = 11 };
	CompletionItem[] items = completion::resolve(&proj, doc_uri, pos)!!;

	bool found_red = false;
	bool found_green = false;
	bool found_blue = false;

	foreach (item : items)
	{
		if (item.label == "RED")
		{
			found_red = true;
			test::eq(item.sortText, "0000_RED");
		}
		if (item.label == "GREEN") found_green = true;
		if (item.label == "BLUE") found_blue = true;
	}

	assert(found_red);
	assert(found_green);
	assert(found_blue);
}

<*
 Test 2: Method completion on Optional receiver.
 Verifies that `?` is stripped from the receiver type so that methods
 defined on the base type (which flat-map in C3) are resolved.
*>
fn void test_method_completion_on_optional_receiver()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = `module app;

struct Buffer {
    int capacity;
}

fn void Buffer.reset(&self) {
    self.capacity = 0;
}

faultdef NO_BUFFER;
fn Buffer? get_buffer() => NO_BUFFER~;

fn void test() {
    Buffer? b = get_buffer();
    b.
}
`;

	proj.workspace.process_file("/virtual/opt_methods.c3", source);
	Uri doc_uri = uri::from_file_path(mem, "/virtual/opt_methods.c3");
	defer doc_uri.free();

	// Line 15, col 6: after `b.`
	LspPosition pos = { .line = 15, .character = 6 };
	CompletionItem[] items = completion::resolve(&proj, doc_uri, pos)!!;

	bool found_reset = false;
	foreach (item : items)
	{
		if (item.label == "reset")
		{
			found_reset = true;
			break;
		}
	}

	assert(found_reset);
}

<*
 Test 3: Complex base expression member access.
 Indexing `pts[0].` and cast `((Point*)raw).` must complete member fields.
*>
fn void test_complex_base_member_access()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = `module app;

struct Point {
    int x;
    int y;
}

fn void run(Point[] pts, void* raw) {
    pts[0].
    ((Point*)raw).
}
`;

	proj.workspace.process_file("/virtual/complex_base.c3", source);
	Uri doc_uri = uri::from_file_path(mem, "/virtual/complex_base.c3");
	defer doc_uri.free();

	// 1. Line 8, col 11: after `pts[0].`
	LspPosition pos1 = { .line = 8, .character = 11 };
	CompletionItem[] items1 = completion::resolve(&proj, doc_uri, pos1)!!;

	bool found_x1 = false;
	bool found_y1 = false;
	foreach (item : items1)
	{
		if (item.label == "x") found_x1 = true;
		if (item.label == "y") found_y1 = true;
	}
	assert(found_x1);
	assert(found_y1);

	// 2. Line 9, col 18: after `((Point*)raw).`
	LspPosition pos2 = { .line = 9, .character = 18 };
	CompletionItem[] items2 = completion::resolve(&proj, doc_uri, pos2)!!;

	bool found_x2 = false;
	bool found_y2 = false;
	foreach (item : items2)
	{
		if (item.label == "x") found_x2 = true;
		if (item.label == "y") found_y2 = true;
	}
	assert(found_x2);
	assert(found_y2);
}

<*
 Test 4: Documentation in resolve_item.
 Resolving built-in properties (.len, .ptr) must populate markdown documentation.
*>
fn void test_resolve_item_builtin_properties_documentation()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = `module app;
fn void run(String s) {
    s.
}
`;

	proj.workspace.process_file("/virtual/resolve_doc.c3", source);
	Uri doc_uri = uri::from_file_path(mem, "/virtual/resolve_doc.c3");
	defer doc_uri.free();

	LspPosition pos = { .line = 2, .character = 6 };
	CompletionItem[] items = completion::resolve(&proj, doc_uri, pos)!!;

	CompletionItem len_item = {};
	bool found_len = false;

	foreach (item : items)
	{
		if (item.label == "len")
		{
			len_item = item;
			found_len = true;
			break;
		}
	}

	assert(found_len);
	completion::resolve_item(&proj, &len_item);
	assert(len_item.documentation.value.len > 0);
	test::eq(len_item.documentation.kind, MarkupKind.MARKDOWN);
}

<*
 Test 5: Guard against duplicate parentheses when cursor precedes `(`.
 Completing `compute` in `comp()` must not append duplicate `()` or `($1)`.
*>
fn void test_function_completion_preserves_existing_parentheses()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = `module app;
fn void compute_val(int x) {}
fn void main() {
    comp()
}
`;

	proj.workspace.process_file("/virtual/no_dup_parens.c3", source);
	Uri doc_uri = uri::from_file_path(mem, "/virtual/no_dup_parens.c3");
	defer doc_uri.free();

	// Line 3, col 8: after `comp` in `comp()`
	LspPosition pos = { .line = 3, .character = 8 };
	CompletionItem[] items = completion::resolve(&proj, doc_uri, pos)!!;

	bool found = false;
	foreach (item : items)
	{
		if (item.label == "compute_val")
		{
			found = true;
			test::eq(item.insertText, "compute_val");
			test::eq(item.insertTextFormat, InsertTextFormat.PLAIN_TEXT);
			break;
		}
	}

	assert(found);
}

<*
 Test 6: Inferred enum variant completion in function call argument.
 Typing argument matching prefix `R` inside `set_color(R)` completes to `RED`.
*>
fn void test_enum_call_argument_completion()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = `module app;
enum Color { RED, GREEN, BLUE }
fn void set_color(Color c) {}
fn void main() {
    set_color(R);
}
`;

	proj.workspace.process_file("/virtual/enum_call_arg.c3", source);
	Uri doc_uri = uri::from_file_path(mem, "/virtual/enum_call_arg.c3");
	defer doc_uri.free();

	// Line 4, col 15: after `R` in `set_color(R);`
	LspPosition pos = { .line = 4, .character = 15 };
	CompletionItem[] items = completion::resolve(&proj, doc_uri, pos)!!;

	bool found_red = false;
	foreach (item : items)
	{
		if (item.label == "RED")
		{
			found_red = true;
			test::eq(item.sortText, "0000_RED");
			break;
		}
	}

	assert(found_red);
}