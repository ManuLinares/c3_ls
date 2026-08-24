// test/workspace_symbols_test.c3
module lsp::workspace_symbols_test @test;

import lsp::core;
import lsp::analysis::workspace_symbols;
import lsp;
import std::io;

fn void test_workspace_symbols_query_filtering()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String file1 = "module math_lib;\nfn int calculate_fast(int a) { return a * 2; }\nfn int calculate_precise(int a) { return a * 3; }\n";
	String file2 = "module render_lib;\nstruct TextureBuffer { int width; int height; }\nfn void render_frame() {}\n";

	proj.workspace.process_file("/virtual/math.c3", file1);
	proj.workspace.process_file("/virtual/render.c3", file2);

	// 1. Query "calculate" (should match both functions in math_lib)
	SymbolInformation[] math_syms = workspace_symbols::query_workspace_symbols(&proj, "calculate")!!;
	assert(math_syms.len >= 2);
	bool found_fast = false;
	bool found_precise = false;
	foreach (s : math_syms)
	{
		if (s.name == "calculate_fast") found_fast = true;
		if (s.name == "calculate_precise") found_precise = true;
	}
	assert(found_fast);
	assert(found_precise);

	// 2. Query "Texture" (should match TextureBuffer struct and its fields)
	SymbolInformation[] tex_syms = workspace_symbols::query_workspace_symbols(&proj, "texture")!!;
	assert(tex_syms.len >= 1);
	assert(tex_syms[0].name == "TextureBuffer");
	assert(tex_syms[0].kind == STRUCT);

	// 3. Query empty string (returns all symbols)
	SymbolInformation[] all_syms = workspace_symbols::query_workspace_symbols(&proj, "")!!;
	assert(all_syms.len >= 5);
}