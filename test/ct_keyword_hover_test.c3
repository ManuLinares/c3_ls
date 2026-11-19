module lsp::ct_keyword_hover_test;

import lsp, lsp::analysis::hover, analyzer::core::constants, uri;

const String SOURCE = "module app;\nmacro m(...)\n{\n\tint c = 1;\n\tint j = $eval(\"c\");\n\tString r = $reflect(c).name;\n\tString g = $stringify(c);\n\t$if true: int a; $endif\n\tbool f = $feature(FOO);\n\treturn $vaarg[0];\n}\nfn void main() { m(1); }\n";

macro String hover_at(uint line, uint character)
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();
	proj.workspace.process_file("/virtual/ct_hover.c3", SOURCE);
	return hover::hover(&proj, uri::from_file_path(tmem, "/virtual/ct_hover.c3"), { line, character })!!.tcopy();
}

fn void every_ct_keyword_has_docs() @test
{
	foreach (kw : Keyword::values)
	{
		if (kw.name[0] == '$') assert(kw.docs.len, "%s has no docs", kw.name);
	}
}

fn void hover_shows_syntax_and_doc() @test
{
	String h = hover_at(4, 11);
	assert(h.starts_with("```c3\n$eval(name)\n```\n\n"), "hover: %s", h);
	assert(h.contains("string"), "hover: %s", h);
	h = hover_at(5, 14);
	assert(h.starts_with("```c3\n$reflect(value)\n```\n\n"), "hover: %s", h);
}

fn void hover_on_block_keyword_shows_its_shape() @test
{
	String h = hover_at(7, 2);
	assert(h.starts_with("```c3\n$if cond:\n\t...\n$endif\n```\n\n"), "hover: %s", h);
}

fn void evaluated_keyword_keeps_result_and_adds_doc() @test
{
	String h = hover_at(6, 14);
	assert(h.contains("\"c\""), "hover: %s", h);
	assert(h.ends_with(Keyword.CT_STRINGIFY.docs), "hover: %s", h);
}

fn void deprecated_feature_says_so() @test
{
	assert(hover_at(8, 12).contains("$feat"));
}

fn void vaarg_lists_its_forms() @test
{
	String h = hover_at(9, 10);
	assert(h.contains("$vaarg.len") && h.contains("...$vaarg"), "hover: %s", h);
}
