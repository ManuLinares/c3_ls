module lsp::completion_wire_test;

import lsp, lsp::analysis::completion, uri;

fn void compact_drops_what_the_client_infers() @test
{
	CompletionItem item = {
		.label = "push",
		.labelDetails = { .description = "fn void push(int x)" },
		.detail = "fn void push(int x)",
		.insertText = "push",
		.insertTextFormat = PLAIN_TEXT,
		.filterText = "push",
		.sortText = "0010_push",
	};
	item.compact();
	test::eq(item.detail, "");
	test::eq(item.insertText, "");
	test::eq(item.filterText, "");
	assert(item.insertTextFormat != InsertTextFormat.PLAIN_TEXT);
	test::eq(item.labelDetails.description, "fn void push(int x)");
	test::eq(item.sortText, "0010_push");
}

fn void compact_keeps_what_differs() @test
{
	CompletionItem item = { .label = "push", .insertText = "push(${1:x})", .insertTextFormat = SNIPPET, .filterText = "@push" };
	item.compact();
	test::eq(item.insertText, "push(${1:x})");
	test::eq(item.filterText, "@push");
	assert(item.insertTextFormat == InsertTextFormat.SNIPPET);
}

fn void items_without_docs_carry_no_documentation() @test
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();
	proj.workspace.process_file("/virtual/wire.c3", "module app;\nfn void helper() {}\nfn void main()\n{\n\thel\n}\n");
	foreach (item : completion::resolve(&proj, uri::from_file_path(tmem, "/virtual/wire.c3"), { 4, 4 })!!)
	{
		if (item.label == "helper") assert(!item.documentation.kind.len && !item.documentation.value.len, "documentation: %s", item.documentation.kind);
	}
}

fn void resolve_restores_the_detail() @test
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();
	CompletionItem item = { .label = "x", .kind = KEYWORD, .labelDetails = { .description = "int" } };
	completion::resolve_item(&proj, &item);
	test::eq(item.detail, "int");
}
