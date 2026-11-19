module lsp::builtin_signature_test;

import lsp, lsp::analysis::completion, lsp::analysis::signature_help, analyzer::core::constants, uri, std::collections::list;

macro CompletionItem item_at(String source, uint line, uint character, String label)
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();
	proj.workspace.process_file("/virtual/builtin.c3", source);
	foreach (item : completion::resolve(&proj, uri::from_file_path(tmem, "/virtual/builtin.c3"), { line, character })!!)
	{
		if (item.label == label) return item;
	}
	unreachable("No %s", label);
}

const String SOURCE = "module app;\nmacro m(...)\n{\n\t$$\n\tint a = $$max(1, 2);\n\t$\n}\n";

fn void builtin_shows_signature() @test
{
	test::eq(item_at(SOURCE, 3, 3, "$$max").detail, "$$max(a, b)");
}

fn void builtin_inserts_parameter_placeholders() @test
{
	CompletionItem item = item_at(SOURCE, 3, 3, "$$max");
	assert(item.insertTextFormat == InsertTextFormat.SNIPPET);
	test::eq(item.textEdit.newText, "\\$\\$max(${1:a}, ${2:b})");
}

fn void builtin_without_parameters_inserts_empty_call() @test
{
	test::eq(item_at(SOURCE, 3, 3, "$$trap").textEdit.newText, "$$trap()");
}

fn void variadic_builtin_inserts_only_fixed_parameters() @test
{
	test::eq(item_at(SOURCE, 3, 3, "$$sprintf").textEdit.newText, "\\$\\$sprintf(${1:fmt})");
}

fn void builtin_before_open_paren_inserts_name() @test
{
	test::eq(item_at(SOURCE, 4, 14, "$$max").textEdit.newText, "$$max");
}

fn void builtin_signature_help() @test
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();
	proj.workspace.process_file("/virtual/builtin.c3", SOURCE);
	SignatureHelpResult res = signature_help::signature_help(&proj, uri::from_file_path(tmem, "/virtual/builtin.c3"), { 4, 18 })!!;
	assert(res.signatures.len == 1);
	test::eq(res.signatures[0].label, "$$max(a, b)");
	assert(res.signatures[0].parameters.len == 2);
	test::eq(res.signatures[0].parameters[1].label, "b");
	assert(res.activeParameter == 1);
}

fn void ct_keyword_snippets() @test
{
	CompletionItem item = item_at(SOURCE, 5, 2, "$case");
	assert(item.insertTextFormat == InsertTextFormat.SNIPPET);
	test::eq(item.textEdit.newText, "\\$case ${1:value}:");
	test::eq(item_at(SOURCE, 5, 2, "$if").textEdit.newText, "\\$if ${1:cond}:\n\t$0\n\\$endif");
	test::eq(item_at(SOURCE, 5, 2, "$foreach").textEdit.newText, "\\$foreach ${1:\\$x} : ${2:list}:\n\t$0\n\\$endforeach");
}

fn void plain_ct_keywords() @test
{
	test::eq(item_at(SOURCE, 5, 2, "$vaarg").textEdit.newText, "$vaarg");
	test::eq(item_at(SOURCE, 5, 2, "$else").textEdit.newText, "$else");
	assert(item_at(SOURCE, 5, 2, "$else").insertTextFormat != InsertTextFormat.SNIPPET);
}

fn void builtin_docs_do_not_repeat_signature() @test
{
	foreach (b : constants::Builtin::values)
	{
		assert(!b.doc.starts_with(string::tformat("`$$%s(", b.name)), "%s doc repeats its signature", b.name);
	}
}
