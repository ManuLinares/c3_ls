module lsp::formatting_test @test;

import lsp::core;
import lsp::analysis::formatting;
import lsp;
import uri;
import std::io;

fn void test_format_function_and_braces()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String unformatted = "module app; fn int square(int x){ return x*x; }";
	Uri doc_uri = uri::from_file_path(mem, "/virtual/fmt.c3");
	defer doc_uri.free();

	proj.workspace.process_file("/virtual/fmt.c3", unformatted);

	FormattingOptions options = {
		.tab_size = 4,
		.insert_spaces = false,
		.insert_final_newline = true
	};

	TextEdit[] edits = formatting::format_document(&proj, doc_uri, options)!!;
	assert(edits.len == 1);
	String fmt_text = edits[0].newText;

	assert(fmt_text.contains("module app;\n"));
	assert(fmt_text.contains("fn int square(int x)\n{"));
	assert(fmt_text.contains("\treturn x * x;\n}"));
}

fn void test_format_generic_instantiations_stay_inline()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String unformatted = "module app; fn void main() { List{int} items; HashMap{String, List{int}} map; }";
	Uri doc_uri = uri::from_file_path(mem, "/virtual/fmt_gen.c3");
	defer doc_uri.free();

	proj.workspace.process_file("/virtual/fmt_gen.c3", unformatted);

	FormattingOptions options = {.tab_size = 2,.insert_spaces = true,.insert_final_newline = true };
	TextEdit[] edits = formatting::format_document(&proj, doc_uri, options)!!;
	assert(edits.len == 1);
	String fmt_text = edits[0].newText;

	assert(fmt_text.contains("List{int} items;"));
	assert(fmt_text.contains("HashMap{String, List{int}} map;"));
}

fn void test_format_macro_semicolon_and_for_loops()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String unformatted = "module app; fn void run(){ for(int i=0;i<10;i++){ int a=i+1; } @pool(){ int x=1; }; }";
	Uri doc_uri = uri::from_file_path(mem, "/virtual/fmt_macro.c3");
	defer doc_uri.free();

	proj.workspace.process_file("/virtual/fmt_macro.c3", unformatted);

	FormattingOptions options = {.tab_size = 4,.insert_spaces = false,.insert_final_newline = true };
	TextEdit[] edits = formatting::format_document(&proj, doc_uri, options)!!;
	assert(edits.len == 1);
	String fmt_text = edits[0].newText;

	assert(fmt_text.contains("for (int i = 0; i < 10; i++)"));
	assert(fmt_text.contains("@pool()"));
	assert(fmt_text.contains("};"));
}

fn void test_format_preserves_comments_and_doc_contracts()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String unformatted = `module app;
// Calculate square
<*
 @require x > 0
*>
fn int square(int x) => x * x;
`;
	Uri doc_uri = uri::from_file_path(mem, "/virtual/fmt_comments.c3");
	defer doc_uri.free();

	proj.workspace.process_file("/virtual/fmt_comments.c3", unformatted);

	FormattingOptions options = {.tab_size = 4,.insert_spaces = false,.insert_final_newline = true };
	TextEdit[] edits = formatting::format_document(&proj, doc_uri, options)!!;
	assert(edits.len == 1);
	String fmt_text = edits[0].newText;

	assert(fmt_text.contains("// Calculate square"));
	assert(fmt_text.contains("@require x > 0"));
	assert(fmt_text.contains("fn int square(int x) => x * x;"));
}

fn void test_format_range_selective_lines()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String unformatted = "module app;\n\nfn void a() { int x=1; }\nfn void b() { int y=2; }\n";
	Uri doc_uri = uri::from_file_path(mem, "/virtual/fmt_range.c3");
	defer doc_uri.free();

	proj.workspace.process_file("/virtual/fmt_range.c3", unformatted);

	LspRange range = {
		.start = {.line = 3,.character = 0 },
		.end = {.line = 3,.character = 25 }
	};

	FormattingOptions options = {.tab_size = 4,.insert_spaces = false,.insert_final_newline = false };
	TextEdit[] edits = formatting::format_range(&proj, doc_uri, range, options)!!;
	assert(edits.len == 1);
	assert(edits[0].range.start.line == 3);
}
