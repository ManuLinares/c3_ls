module lsp::primitive_type_docs_test;

import lsp, uri, std::io;

const String SRC = `module t;
fn void main()
{
	uint x;
	int y = 1;
	$assert $Typeof({ 1, 2 }) == untypedlist;
}
`;

fn LspProject* load(LspProject* proj)
{
	proj.init(mem);
	proj.workspace.process_file("/virtual/types.c3", SRC);
	return proj;
}

fn CompletionItem* find_item(CompletionItem[] items, String label)
{
	foreach (&item : items)
	{
		if (item.label == label) return item;
	}
	return null;
}

fn void completion_documents_primitive_types() @test
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();
	proj.workspace.process_file("/virtual/typing.c3", "module t;\nfn void main()\n{\n\tu\n}\n");
	Uri u = uri::from_file_path(tmem, "/virtual/typing.c3");

	CompletionItem[] items = completion::resolve(&proj, u, { .line = 3, .character = 2 })!!;
	CompletionItem* uint_item = find_item(items, "uint");
	CompletionItem* list_item = find_item(items, "untypedlist");
	assert(uint_item && list_item);

	assert(uint_item.detail == "built-in type", "%s", uint_item.detail);
	assert(uint_item.documentation.value.contains("Unsigned 32-bit integer"), "%s", uint_item.documentation.value);

	assert(list_item.detail == "compile-time type", "%s", list_item.detail);
	assert(list_item.documentation.value.contains("untyped initializer list"), "%s", list_item.documentation.value);
	assert(list_item.sortText.compare_to(uint_item.sortText) > 0, "%s <= %s", list_item.sortText, uint_item.sortText);
}

fn void hover_documents_primitive_types() @test
{
	LspProject proj;
	load(&proj);
	defer proj.free();
	Uri u = uri::from_file_path(tmem, "/virtual/types.c3");

	String h = hover::hover(&proj, u, { .line = 4, .character = 2 })!!;
	assert(h.contains("Signed 32-bit integer"), "int hover: %s", h);

	h = hover::hover(&proj, u, { .line = 5, .character = 33 })!!;
	assert(h.contains("untyped initializer list"), "untypedlist hover: %s", h);
}
