module lsp::references_rename_test @test;

import lsp::core;
import lsp::analysis::references;
import lsp::analysis::rename;
import lsp;
import uri;
import std::io;

fn void test_find_references_multiple_occurrences()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = "module ref_test;\nint counter = 0;\nfn void inc() {\n  counter += 1;\n  int x = counter + 2;\n}\n";
	Uri doc_uri = uri::from_file_path(mem, "/virtual/refs.c3");
	defer doc_uri.free();

	proj.workspace.process_file("/virtual/refs.c3", source);

	LspPosition pos = {.line = 1,.character = 6 };  // on `counter` definition
	LspLocation[] locs = references::find_references(&proj, doc_uri, pos, {.includeDeclaration = true })!!;
	assert(locs.len >= 3);
}

fn void test_find_references_exclude_declaration()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = "module ref_test;\nint counter = 0;\nfn void inc() {\n  counter += 1;\n}\n";
	Uri doc_uri = uri::from_file_path(mem, "/virtual/refs_nodecl.c3");
	defer doc_uri.free();

	proj.workspace.process_file("/virtual/refs_nodecl.c3", source);

	LspPosition pos = {.line = 1,.character = 6 };
	LspLocation[] locs = references::find_references(&proj, doc_uri, pos, {.includeDeclaration = false })!!;
	assert(locs.len == 1);
	assert(locs[0].range.start.line == 3);
}

fn void test_find_references_struct_across_types()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = "module ref_test;\nstruct Point { int x; int y; }\nfn Point make_point(Point p) {\n  Point local_p = p;\n  return local_p;\n}\n";
	Uri doc_uri = uri::from_file_path(mem, "/virtual/struct_refs.c3");
	defer doc_uri.free();

	proj.workspace.process_file("/virtual/struct_refs.c3", source);

	LspPosition pos = {.line = 1,.character = 8 };
	LspLocation[] locs = references::find_references(&proj, doc_uri, pos, {.includeDeclaration = true })!!;
	assert(locs.len >= 4);
}

fn void test_rename_function_cross_file()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String file1 = "module math_lib;\nfn int compute_val(int x) { return x * 2; }\n";
	String file2 = "module main_app;\nimport math_lib;\nfn void main() {\n  int r = compute_val(5);\n}\n";

	proj.workspace.process_file("/virtual/lib.c3", file1);
	proj.workspace.process_file("/virtual/app.c3", file2);

	Uri doc_uri1 = uri::from_file_path(mem, "/virtual/lib.c3");
	defer doc_uri1.free();

	LspPosition pos = {.line = 1,.character = 8 };  // on `compute_val`
	WorkspaceEdit edit = rename::rename(&proj, doc_uri1, pos, "calculate_val")!!;
	assert(edit.documentChanges.len >= 2);

	bool found_lib_edit = false;
	bool found_app_edit = false;
	foreach (change : edit.documentChanges)
	{
		if (change.textDocument.uri.contains("lib.c3"))
		{
			found_lib_edit = true;
			assert(change.edits[0].newText == "calculate_val");
		}
		if (change.textDocument.uri.contains("app.c3"))
		{
			found_app_edit = true;
			assert(change.edits[0].newText == "calculate_val");
		}
	}
	assert(found_lib_edit);
	assert(found_app_edit);
}

fn void test_rename_typedef_cross_file()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String file1 = "module types;\ntypedef MyHandle = int;\n";
	String file2 = "module consumer;\nimport types;\nfn void process_handle(MyHandle h) {\n  MyHandle copy = h;\n}\n";

	proj.workspace.process_file("/virtual/types.c3", file1);
	proj.workspace.process_file("/virtual/consumer.c3", file2);

	Uri doc_uri = uri::from_file_path(mem, "/virtual/types.c3");
	defer doc_uri.free();

	LspPosition pos = {.line = 1,.character = 9 };  // on `MyHandle`
	WorkspaceEdit edit = rename::rename(&proj, doc_uri, pos, "NativeHandle")!!;
	assert(edit.documentChanges.len >= 2);

	foreach (change : edit.documentChanges)
	{
		foreach (e : change.edits)
		{
			assert(e.newText == "NativeHandle");
		}
	}
}

fn void test_prepare_rename_invalid_target_fails()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = "module test;\nfn void main() {\n  // empty comment\n}\n";
	Uri doc_uri = uri::from_file_path(mem, "/virtual/invalid_rename.c3");
	defer doc_uri.free();

	proj.workspace.process_file("/virtual/invalid_rename.c3", source);

	LspPosition pos = {.line = 2,.character = 5 };
	LspRange? range = rename::prepare_rename(&proj, doc_uri, pos);
	assert(@catch(range) == NOT_FOUND);
}
