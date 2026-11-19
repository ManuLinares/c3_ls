module lsp::completion_ct_keyword_test;

import lsp, lsp::analysis::completion, uri, std::collections::list;

macro CompletionItem[] items_at(String source, uint line, uint character)
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();
	proj.workspace.process_file("/virtual/ct.c3", source);
	List{CompletionItem} items;
	items.tinit();
	foreach (item : completion::resolve(&proj, uri::from_file_path(tmem, "/virtual/ct.c3"), { line, character })!!)
	{
		items.push(item);
	}
	return items.array_view();
}

fn bool has(CompletionItem[] items, String label)
{
	foreach (item : items) if (item.label == label) return true;
	return false;
}

const String BODY = "module app;\nmacro m(...)\n{\n\t$\n\t$f\n\tint a = $\n}\n";

fn void statement_keywords_in_body() @test
{
	CompletionItem[] items = items_at(BODY, 3, 2);
	assert(has(items, "$if"));
	assert(has(items, "$foreach"));
	assert(has(items, "$assert"));
	assert(has(items, "$Typeof"));
	assert(!has(items, "$include"));
}

fn void keywords_match_typed_prefix() @test
{
	CompletionItem[] items = items_at(BODY, 4, 3);
	assert(has(items, "$for"));
	assert(has(items, "$foreach"));
	assert(has(items, "$feature"));
}

fn void expression_keywords_after_assignment() @test
{
	CompletionItem[] items = items_at(BODY, 5, 10);
	assert(has(items, "$defined"));
	assert(has(items, "$vaarg"));
	assert(!has(items, "$if"));
}

fn void top_level_keywords() @test
{
	CompletionItem[] items = items_at("module app;\n$\n", 1, 1);
	assert(has(items, "$assert"));
	assert(has(items, "$include"));
	assert(has(items, "$exec"));
	assert(!has(items, "$if"));
}

fn void keyword_replaces_typed_dollar() @test
{
	foreach (item : items_at(BODY, 3, 2))
	{
		if (item.label != "$if") continue;
		assert(item.textEdit != null);
		assert(item.textEdit.range.start.character == 1);
		assert(item.textEdit.range.end.character == 2);
		assert(item.textEdit.newText.starts_with("\\$if "));
		return;
	}
	unreachable("No $if");
}

const String ARGS = "module app;\nfn void foo(int a) {}\nmacro m()\n{\n\tint $x = 1;\n\tfoo($\n\tif ($\n\t$$\n\t$\n}\n";

fn void only_expression_keywords_in_call_arguments() @test
{
	CompletionItem[] items = items_at(ARGS, 5, 6);
	assert(has(items, "$defined"));
	assert(!has(items, "$if"));
	assert(!has(items, "$assert"));
}

fn void only_expression_keywords_in_conditions() @test
{
	CompletionItem[] items = items_at(ARGS, 6, 6);
	assert(has(items, "$defined"));
	assert(!has(items, "$foreach"));
}

macro void assert_replaces_typed(CompletionItem[] items, String label, uint start, uint end)
{
	foreach (item : items)
	{
		if (item.label != label) continue;
		assert(item.textEdit != null, "%s has no text edit", label);
		assert(item.textEdit.range.start.character == start && item.textEdit.range.end.character == end, "%s replaces the wrong range", label);
		assert(item.textEdit.newText.treplace("\\$", "$").starts_with(label), "%s inserts %s", label, item.textEdit.newText);
		return;
	}
	unreachable("No %s", label);
}

fn void builtin_replaces_typed_dollars() @test
{
	assert_replaces_typed(items_at(ARGS, 7, 3), "$$max", 1, 3);
}

fn void ct_variable_replaces_typed_dollar() @test
{
	assert_replaces_typed(items_at(ARGS, 8, 2), "$x", 1, 2);
}
