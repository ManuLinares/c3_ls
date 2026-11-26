module lsp::diagnostics_lifecycle_test @test;

import lsp::core;
import lsp;
import uri;
import std::io;
import analyzer::core;

fn void test_diagnostics_clear_on_valid_change()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String broken_doc = "module test;\nfn void broken( {\n  invalid syntax !!\n";
	Uri doc_uri = uri::from_file_path(mem, "/virtual/diag_test.c3");
	defer doc_uri.free();

	proj.open_file(
	{
		.uri = (DocumentUri)doc_uri.to_raw_string(tmem),
		.language_id = "c3",
		.version = 1,
		.text = broken_doc
	}
	);
	proj.update();

	LspDiagnostic[] diags = proj.workspace.get_diagnostics("/virtual/diag_test.c3");
	assert(diags.len > 0);
	// Send valid text update
	String fixed_doc = "module test;\nfn void fixed() {}\n";
	TextDocumentContentChangeEvent[1] changes = {
		{
			.text = fixed_doc
		}
	};
	proj.change_file(
	{
		.document = {
			.uri = (DocumentUri)doc_uri.to_raw_string(tmem),
			.version = 2
		},
		.content_changes = &changes
	}
	);
	proj.update();

	LspDiagnostic[] fixed_diags = proj.workspace.get_diagnostics("/virtual/diag_test.c3");
	assert(fixed_diags.len == 0);
}

fn void test_top_level_include_and_exec_parse()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String path = "/virtual/include_exec.c3";
	proj.workspace.process_file(path, "module t;\n$include(\"other.c3\");\n$exec(\"echo\", { \"fn void x() {}\" });\nfn void main() {}\n");
	test::eq(proj.workspace.get_diagnostics(path).len, 0);

	SourceFile* sf = proj.workspace.get_source_file_by_path(path);
	int includes;
	foreach (stmt : sf.ast.statements)
	{
		if (stmt && stmt.kind == CT_INCLUDE_DECL) includes++;
	}
	test::eq(includes, 2);
}
