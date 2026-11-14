module lsp::completion_comment_test;

import lsp, lsp::analysis::completion, uri, std::collections::list;

fn String[] labels_at(String source, uint line, uint character)
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();
	proj.workspace.process_file("/virtual/comments.c3", source);
	List{String} labels;
	labels.tinit();
	foreach (item : completion::resolve(&proj, uri::from_file_path(tmem, "/virtual/comments.c3"), { line, character })!!)
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

fn void inferred_vector_types_are_not_doc_comments() @test
{
	String source = "module app;\nstruct Point\n{\n\tint x;\n}\nmacro float total(float[<*>] v) => v[0];\nfn void main()\n{\n\tfloat[<*>] a = { 1, 2, 3 };\n\tPoint p;\n\tint y = p.x;\n\tfloat s = a.x;\n}\n";
	assert(has(labels_at(source, 10, 11), "x"));
	assert(has(labels_at(source, 11, 13), "len"));
}

fn void no_completion_inside_comments() @test
{
	String source = "module app;\nstruct Point\n{\n\tint x;\n}\n<* p. in docs *>\nfn void main()\n{\n\tPoint p;\n\t// p.\n\t/* p. */\n}\n";
	assert(!labels_at(source, 5, 5).len);
	assert(!labels_at(source, 9, 6).len);
	assert(!labels_at(source, 10, 6).len);
}
