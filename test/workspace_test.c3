module lsp::workspace_test @test;

import lsp::core;
import analyzer::core;
import std::io;
import std::collections::list;

fn void test_workspace_process_and_lookup()
{
	LspWorkspace ws;
	ws.init(mem);
	defer ws.free();

	String sample_code = "module my_test;\nfn void hello_world() {}\nstruct Point { int x; int y; }\n";
	bool ok = ws.process_file("virtual://test.c3", sample_code);
	assert(ok);

	SourceFile* sf = ws.get_source_file_by_path("virtual://test.c3");
	assert(sf != null);
	assert(sf.path == "virtual://test.c3");

	List{SymbolEntry} syms = ws.find_symbol_by_name("hello_world");
	assert(syms.len() > 0);
	assert(syms.get(0).node != null);
	assert(syms.get(0).node.kind == FN_DECL);

	List{SymbolEntry} point_syms = ws.find_symbol_by_name("Point");
	assert(point_syms.len() > 0);
	assert(point_syms.get(0).node != null);
	assert(point_syms.get(0).node.kind == STRUCT_DECL);
}

fn void test_workspace_diagnostics_collection()
{
	LspWorkspace ws;
	ws.init(mem);
	defer ws.free();
	// Invalid syntax that triggers parser/lexer error
	String invalid_code = "module bad_syntax;\nfn void foo( {\n";
	ws.process_file("virtual://bad.c3", invalid_code);

	LspDiagnostic[] diags = ws.get_diagnostics("virtual://bad.c3");
	assert(diags.len > 0);
	assert(diags[0].severity == 1);
	assert(diags[0].source == "c3-analyzer");
	assert(diags[0].message.len > 0);
}
