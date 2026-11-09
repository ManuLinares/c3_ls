module lsp::completion_snippet_test @test;

import lsp::core;
import lsp::analysis::completion;
import lsp;
import uri;
import std::io;

const String SNIPPET_SOURCE = `module app;

macro void @pool(sz reserve = 0; @body) {}
macro void @two(int a, int b = 3; @body(x, y)) {}
macro void @later(int a = 1, int b) {}
macro void @ct($x, #e) {}
macro void @rest(int a, args...) {}
macro void @opt(int a = 1) {}
fn void log_it(String msg, int level = 0) {}
fn int twice(int x) => x * 2;

struct Map { int x; }
macro void Map.@each(map; @body(key, value)) {}

fn void run() => @po
fn void run2() @inline => @po

fn void main() {
    Map m;
    @po
    @tw
    @la
    @ct
    @re
    @op
    log_
    int r = twi
    m.@ea
}
`;

<*
 Insert text and format of completion `label` at `line`:`character` of SNIPPET_SOURCE.
*>
macro CompletionItem completion_at(String label, uint line, uint character)
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();
	proj.workspace.process_file("/virtual/snippets.c3", SNIPPET_SOURCE);
	Uri doc_uri = uri::from_file_path(tmem, "/virtual/snippets.c3");
	foreach (item : completion::resolve(&proj, doc_uri, { .line = line, .character = character })!!)
	{
		if (item.label == label) return { .label = item.label.tcopy(), .insertText = item.insertText.tcopy(), .insertTextFormat = item.insertTextFormat };
	}
	unreachable("No completion '%s' at %d:%d", label, line, character);
}

fn void trailing_body_macro_inserts_body_block() @test
{
	CompletionItem item = completion_at("@pool", 19, 7);
	test::eq(item.insertText, "pool()\n{\n\t$0\n};");
	test::eq(item.insertTextFormat, InsertTextFormat.SNIPPET);
}

fn void trailing_body_after_arrow_has_no_semicolon() @test
{
	test::eq(completion_at("@pool", 14, 20).insertText, "pool()\n{\n\t$0\n}");
	test::eq(completion_at("@pool", 15, 29).insertText, "pool()\n{\n\t$0\n}");
}

fn void required_params_become_placeholders_and_body_params_names() @test
{
	test::eq(completion_at("@two", 20, 7).insertText, "two(${1:a}; x, y)\n{\n\t$0\n};");
}

fn void required_param_after_default_is_named() @test
{
	test::eq(completion_at("@later", 21, 7).insertText, "later(b: ${1:b});");
}

fn void compile_time_param_names_are_escaped() @test
{
	test::eq(completion_at("@ct", 22, 7).insertText, `ct(${1:\$x}, ${2:#e});`);
}

fn void variadic_params_are_left_out() @test
{
	test::eq(completion_at("@rest", 23, 7).insertText, "rest(${1:a});");
}

fn void only_default_params_insert_empty_call() @test
{
	CompletionItem item = completion_at("@opt", 24, 7);
	test::eq(item.insertText, "opt();");
	test::eq(item.insertTextFormat, InsertTextFormat.PLAIN_TEXT);
}

fn void function_params_become_placeholders() @test
{
	test::eq(completion_at("log_it", 25, 8).insertText, "log_it(${1:msg});");
	test::eq(completion_at("twice", 26, 15).insertText, "twice(${1:x})");
}

fn void method_macro_body_params_are_inserted_as_names() @test
{
	test::eq(completion_at("@each", 27, 9).insertText, "each(; key, value)\n{\n\t$0\n};");
}
