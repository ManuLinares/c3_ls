// test/signature_help_test.c3

module lsp::signature_help_test @test;

import lsp::core;
import lsp::analysis::signature_help;
import lsp;
import uri;
import std::io;

fn void test_signature_help_active_param_and_types()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = "module my_app;\nfn int draw_rect(int x, int y, int width, int height, String color) { return 0; }\nfn void main() {\n  draw_rect(10, 20, 100, 50, \"red\");\n}\n";
	Uri doc_uri = uri::from_file_path(mem, "/virtual/sig_help.c3");
	defer doc_uri.free();

	proj.workspace.process_file("/virtual/sig_help.c3", source);

	// Cursor at second argument `20` (line 3, char 18)
	LspPosition pos1 = { .line = 3, .character = 18 };
	SignatureHelpResult res1 = signature_help::signature_help(&proj, doc_uri, pos1)!!;
	assert(res1.signatures.len == 1);
	assert(res1.signatures[0].label.contains("draw_rect"));
	assert(res1.signatures[0].parameters.len == 5);
	assert(res1.signatures[0].activeParameter == 1);

	// Cursor at 5th argument `"red"` (line 3, char 32)
	LspPosition pos2 = { .line = 3, .character = 32 };
	SignatureHelpResult res2 = signature_help::signature_help(&proj, doc_uri, pos2)!!;
	assert(res2.signatures.len == 1);
	assert(res2.signatures[0].activeParameter == 4);
}

fn void test_signature_help_macro_and_method()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = "module my_app;\nstruct Canvas { int id; }\nfn void Canvas.blit(&self, int src_x, int src_y, int dest_x, int dest_y) {}\nfn void main() {\n  Canvas c;\n  c.blit(0, 0, 100, 200);\n}\n";
	Uri doc_uri = uri::from_file_path(mem, "/virtual/sig_method.c3");
	defer doc_uri.free();

	proj.workspace.process_file("/virtual/sig_method.c3", source);

	// Cursor inside `c.blit(0, 0, |)` (line 5, char 16)
	LspPosition pos = { .line = 5, .character = 16 };
	SignatureHelpResult res = signature_help::signature_help(&proj, doc_uri, pos)!!;
	assert(res.signatures.len == 1);
	assert(res.signatures[0].label.contains("Canvas.blit"));
	assert(res.signatures[0].activeParameter == 2);
}

fn void test_signature_help_nested_calls()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = "module my_app;\nfn int inner(int a, int b) { return a + b; }\nfn void outer(int x, int y) {}\nfn void main() {\n  outer(inner(1, 2), 3);\n}\n";
	Uri doc_uri = uri::from_file_path(mem, "/virtual/sig_nested.c3");
	defer doc_uri.free();

	proj.workspace.process_file("/virtual/sig_nested.c3", source);

	// 1. Inside inner call: `inner(1, |2)` (line 4, char 18) -> should resolve `inner`, activeParameter = 1
	LspPosition inner_pos = { .line = 4, .character = 18 };
	SignatureHelpResult res_inner = signature_help::signature_help(&proj, doc_uri, inner_pos)!!;
	assert(res_inner.signatures.len == 1);
	assert(res_inner.signatures[0].label.contains("inner"));
	assert(res_inner.signatures[0].activeParameter == 1);

	// 2. Outside inner call, second param of outer: `outer(..., |3)` (line 4, char 22) -> should resolve `outer`, activeParameter = 1
	LspPosition outer_pos = { .line = 4, .character = 22 };
	SignatureHelpResult res_outer = signature_help::signature_help(&proj, doc_uri, outer_pos)!!;
	assert(res_outer.signatures.len == 1);
	assert(res_outer.signatures[0].label.contains("outer"));
	assert(res_outer.signatures[0].activeParameter == 1);
}

fn void test_signature_help_string_with_commas()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = "module app;\nfn void format_log(String fmt, int code, bool flag) {}\nfn void main() {\n  format_log(\"a, b, c, d\", 404, true);\n}\n";
	Uri doc_uri = uri::from_file_path(mem, "/virtual/sig_commas.c3");
	defer doc_uri.free();

	proj.workspace.process_file("/virtual/sig_commas.c3", source);

	// Cursor at second argument `404` (line 3, char 28) despite 3 commas inside first string
	LspPosition pos = { .line = 3, .character = 28 };
	SignatureHelpResult res = signature_help::signature_help(&proj, doc_uri, pos)!!;
	assert(res.signatures.len == 1);
	assert(res.signatures[0].activeParameter == 1);
}

fn void test_signature_help_multiline_call()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = "module app;\nfn void configure(int port, String host, bool debug) {}\nfn void main() {\n  configure(\n    8080,\n    \"localhost\",\n    true\n  );\n}\n";
	Uri doc_uri = uri::from_file_path(mem, "/virtual/sig_multiline.c3");
	defer doc_uri.free();

	proj.workspace.process_file("/virtual/sig_multiline.c3", source);

	// Cursor on line 5 at `"localhost"`
	LspPosition pos = { .line = 5, .character = 6 };
	SignatureHelpResult res = signature_help::signature_help(&proj, doc_uri, pos)!!;
	assert(res.signatures.len == 1);
	assert(res.signatures[0].label.contains("configure"));
	assert(res.signatures[0].activeParameter == 1);
}