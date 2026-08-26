module lsp::module_scoping_test @test;

import lsp::core;
import lsp::analysis::goto_definition;
import lsp::analysis::hover;
import lsp;
import uri;
import std::io;

fn void test_multi_section_module_isolation()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = `module core_lib;
fn int public_helper() { return 1; }

module core_lib @private;
fn int private_helper() { return 2; }

module core_lib @test;
fn void run_internal_tests() {
  int a = public_helper();
  int b = private_helper();
}
`;

	proj.workspace.process_file("/virtual/multisection.c3", source);
	Uri doc_uri = uri::from_file_path(mem, "/virtual/multisection.c3");
	defer doc_uri.free();
	// Line 9: public_helper() call
	LspPosition pub_pos = {.line = 8,.character = 14 };
	LspLocation[] pub_locs = goto_definition::goto_definition(&proj, doc_uri, pub_pos)!!;
	assert(pub_locs.len > 0);
	assert(pub_locs[0].range.start.line == 1);
	// Line 10: private_helper() call
	LspPosition priv_pos = {.line = 9,.character = 14 };
	LspLocation[] priv_locs = goto_definition::goto_definition(&proj, doc_uri, priv_pos)!!;
	assert(priv_locs.len > 0);
	assert(priv_locs[0].range.start.line == 4);
}

fn void test_multiple_module_sections_no_false_redefinition_diagnostics()
{
	LspWorkspace ws;
	ws.init(mem);
	defer ws.free();

	String source_code = `module std::collections::set <Value>;
const int DEFAULT_INITIAL_CAPACITY = 16;
const int MAXIMUM_CAPACITY = 1 << 30;
int dummy @local;

module std::collections::ringbuffer <Type, CAPACITY>;
int dummy @local;

module std::collections::map <Key, Value>;
const int DEFAULT_INITIAL_CAPACITY = 16;
const int MAXIMUM_CAPACITY = 1 << 30;
int dummy @local;
`;

	ws.process_file("/virtual/multimod.c3", source_code);
	LspDiagnostic[] diags = ws.get_diagnostics("/virtual/multimod.c3");
	assert(diags.len == 0);
}
