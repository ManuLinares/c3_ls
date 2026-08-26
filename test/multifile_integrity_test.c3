module lsp::multifile_integrity_test @test;

import lsp::core;
import lsp::analysis::references;
import lsp::analysis::rename;
import lsp;
import uri;
import std::io;

fn void test_rename_cross_file_scope_isolation()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String file1 = "module backend;\nfn void process_job(int id) {}\n";
	String file2 = "module worker;\nimport backend;\nfn void run() {\n  backend::process_job(10);\n}\n";
	String file3 = "module unrelated;\nfn void other() {\n  int process_job = 42;\n  int x = process_job + 1;\n}\n";

	proj.workspace.process_file("/virtual/backend.c3", file1);
	proj.workspace.process_file("/virtual/worker.c3", file2);
	proj.workspace.process_file("/virtual/unrelated.c3", file3);

	Uri uri1 = uri::from_file_path(mem, "/virtual/backend.c3");
	defer uri1.free();

	LspPosition fn_pos = {.line = 1,.character = 8 };  // on `process_job` declaration
	LspLocation[] refs = references::find_references(&proj, uri1, fn_pos, {.includeDeclaration = true })!!;
	// Should find declaration in backend.c3 and call in worker.c3, but NOT the local var in unrelated.c3
	assert(refs.len == 2);
	foreach (r : refs)
	{
		assert(!r.uri.contains("unrelated.c3"));
	}

	WorkspaceEdit edit = rename::rename(&proj, uri1, fn_pos, "execute_job")!!;
	assert(edit.documentChanges.len == 2);
	foreach (doc_edit : edit.documentChanges)
	{
		assert(!doc_edit.textDocument.uri.contains("unrelated.c3"));
		assert(doc_edit.edits[0].newText == "execute_job");
	}
}

fn void test_out_of_order_module_import_diagnostics()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();
	// File A (main.c3) imports a submodule (lsp::server) defined in File B (server.c3)
	String main_code = "module lsp;\nimport lsp::server;\nfn void run() { server::start(); }\n";
	String server_code = "module lsp::server;\nfn void start() {}\n";
	// Open File A FIRST, then File B
	proj.open_file(
	{
		.uri = "file:///virtual/main.c3",
		.language_id = "c3",
		.version = 1,
		.text = main_code
	}
	);

	proj.open_file(
	{
		.uri = "file:///virtual/server.c3",
		.language_id = "c3",
		.version = 1,
		.text = server_code
	}
	);
	// Run two-phase update
	proj.update();
	// Verify that NO false "No module 'lsp::server' found" diagnostic was emitted on main.c3
	LspDiagnostic[] diags = proj.workspace.get_diagnostics("/virtual/main.c3");
	assert(diags.len == 0);
}
