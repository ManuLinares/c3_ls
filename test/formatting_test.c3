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

fn void test_format_off_region_preserved()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String src = "module app;\nfn void main(){int  a=1;\n// fmt:off\nint   m[2] = { 1,0,\n 0,1 };\n// fmt:on\nint  b=2;}\n";
	Uri doc_uri = uri::from_file_path(mem, "/virtual/fmt_off.c3");
	defer doc_uri.free();
	proj.workspace.process_file("/virtual/fmt_off.c3", src);

	FormattingOptions options = {.tab_size = 4,.insert_spaces = false,.insert_final_newline = true };
	TextEdit[] edits = formatting::format_document(&proj, doc_uri, options)!!;
	String out = edits[0].newText;

	assert(out.contains("int   m[2] = { 1,0,\n 0,1 };\n"));
	assert(out.contains("int a = 1;"));
	assert(out.contains("int b = 2;"));
}

fn void test_format_off_unterminated()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String src = "module app;\n// fmt:off\nfn void  f(){  }\n";
	Uri doc_uri = uri::from_file_path(mem, "/virtual/fmt_off2.c3");
	defer doc_uri.free();
	proj.workspace.process_file("/virtual/fmt_off2.c3", src);

	FormattingOptions options = {.tab_size = 4,.insert_spaces = false,.insert_final_newline = true };
	TextEdit[] edits = formatting::format_document(&proj, doc_uri, options)!!;
	assert(edits[0].newText == src);
}

fn void test_format_range_inside_off_region()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String src = "module app;\nfn void main(){\n// fmt:off\nint   a=1;\nint   b=2;\n// fmt:on\nint  c=3;}\n";
	Uri doc_uri = uri::from_file_path(mem, "/virtual/fmt_off3.c3");
	defer doc_uri.free();
	proj.workspace.process_file("/virtual/fmt_off3.c3", src);

	FormattingOptions options = {.tab_size = 4,.insert_spaces = false,.insert_final_newline = true };
	TextEdit[] inside = formatting::format_range(&proj, doc_uri, {.start = {.line = 3,.character = 0 },.end = {.line = 4,.character = 10 }}, options)!!;
	assert(inside.len == 1);
	assert(inside[0].newText == "int   a=1;\nint   b=2;");
	assert(inside[0].range.start.line == 3 && inside[0].range.start.character == 0);
	assert(inside[0].range.end.line == 4 && inside[0].range.end.character == 10);

	TextEdit[] spanning = formatting::format_range(&proj, doc_uri, {.start = {.line = 3,.character = 0 },.end = {.line = 6,.character = 10 }}, options)!!;
	assert(spanning.len == 1);
	assert(spanning[0].newText.contains("int c = 3;"));
	assert(!spanning[0].newText.contains("int a = 1;"));
}

fn void test_format_off_exact_output()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();
	Uri doc_uri = uri::from_file_path(mem, "/virtual/fmt_exact.c3");
	defer doc_uri.free();

	String[] sources = {
		"module app;\n// fmt:off\n\n\n  int   a=1;  \n\t// fmt:on\nint  b=2;\n",
		"module app;\n// fmt:off\n  int   a=1;\n// fmt:on\nint  b=2;\n// fmt:off\n\tint   c=3;\n// fmt:on\nint  d=4;\n",
		"module app;\n// fmt:off\n\n  int   a=1;  ",
		"module app;\n// fmt:off\n\n\n",
		"module app;\n// fmt:off",
		"module app;\n// fmt:off\n// fmt:on\nint  b=2;\n"
	};
	String[] expected = {
		"module app;\n// fmt:off\n\n\n  int   a=1;  \n\t// fmt:on\nint b = 2;\n",
		"module app;\n// fmt:off\n  int   a=1;\n// fmt:on\nint b = 2;\n// fmt:off\n\tint   c=3;\n// fmt:on\nint d = 4;\n",
		sources[2], sources[3], sources[4],
		"module app;\n// fmt:off\n// fmt:on\nint b = 2;\n"
	};
	FormattingOptions options = {.tab_size = 4,.insert_spaces = false,.insert_final_newline = true };
	foreach (i, src : sources)
	{
		proj.workspace.process_file("/virtual/fmt_exact.c3", src);
		TextEdit[] edits = formatting::format_document(&proj, doc_uri, options)!!;
		assert(edits.len == 1);
		assert(edits[0].newText == expected[i]);
		proj.workspace.process_file("/virtual/fmt_exact.c3", edits[0].newText);
		TextEdit[] again = formatting::format_document(&proj, doc_uri, options)!!;
		assert(again[0].newText == expected[i]);
	}
}

fn void test_format_off_indented_range_preserves_document()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();
	Uri doc_uri = uri::from_file_path(mem, "/virtual/fmt_range_exact.c3");
	defer doc_uri.free();
	String prefix = "module app;\nfn void main(){\n// fmt:off\n  ";
	String selected = "int   a=1;\n\tint   b=2;";
	String suffix = "  \n// fmt:on\nint c=3;}\n";
	DString src;
	src.tinit();
	src.append(prefix);
	src.append(selected);
	src.append(suffix);
	proj.workspace.process_file("/virtual/fmt_range_exact.c3", src.str_view());
	FormattingOptions options = {.tab_size = 4,.insert_spaces = false,.insert_final_newline = true };
	TextEdit[] edits = formatting::format_range(&proj, doc_uri,
		{.start = {.line = 3,.character = 0 },.end = {.line = 4,.character = 11 }}, options)!!;
	assert(edits.len == 1);
	assert(edits[0].range.start.line == 3 && edits[0].range.start.character == 2);
	assert(edits[0].range.end.line == 4 && edits[0].range.end.character == 11);
	DString applied;
	applied.tinit();
	applied.append(prefix);
	applied.append(edits[0].newText);
	applied.append(suffix);
	assert(applied.str_view() == src.str_view());
}
