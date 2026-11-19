module lsp::completion_decl_name_test;

import lsp, lsp::analysis::completion, uri, std::collections::list;

fn String[] labels_at(String source, uint line, uint character, CompletionContext context = {})
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();
	proj.workspace.process_file("/virtual/decl.c3", source);
	List{String} labels;
	labels.tinit();
	foreach (item : completion::resolve(&proj, uri::from_file_path(tmem, "/virtual/decl.c3"), { line, character }, context)!!)
	{
		labels.push(item.label.tcopy());
	}
	return labels.array_view();
}

fn bool has(String[] labels, String label)
{
	foreach (l : labels) if (l == label) return true;
	return false;
}

const CompletionContext SPACE = { .triggerKind = TRIGGER_CHARACTER, .triggerCharacter = " " };

fn void nothing_after_declared_name() @test
{
	assert(!labels_at("module app;\nconst int MYCONST \n", 1, 18).len);
	assert(!labels_at("module app;\nconst int MYCONST my\n", 1, 20).len);
	assert(!labels_at("module app;\nint global \n", 1, 11).len);
	assert(!labels_at("module app;\nfn void main()\n{\n\tint x \n}\n", 3, 7).len);
	assert(!labels_at("module app;\nfn void f(int x )\n{\n}\n", 1, 16).len);
}

fn void attributes_after_declared_name() @test
{
	assert(has(labels_at("module app;\nconst int MYCONST @\n", 1, 19), "@private"));
	assert(has(labels_at("module app;\nfn void main()\n{\n\tint x @\n}\n", 3, 8), "@noinit"));
}

fn void space_trigger_only_where_a_list_is_expected() @test
{
	String source = "module app;\nenum Color { RED, GREEN }\nfn Color pick()\n{\n\tint a; \n\treturn \n}\n";
	assert(!labels_at(source, 4, 8, SPACE).len);
	assert(has(labels_at(source, 4, 8), "pick"));
	assert(has(labels_at(source, 5, 8, SPACE), "RED"));
	assert(labels_at("module app;\nimport \n", 1, 7, SPACE).len);
}
