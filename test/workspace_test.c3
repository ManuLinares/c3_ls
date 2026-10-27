module lsp::workspace_test @test;

import lsp;
import lsp::core;
import analyzer::core;
import std::io;
import std::collections::list;
import std::collections::maybe;
import uri;

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

fn void test_project_test_sources()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	Path cwd = path::tcwd()!!;
	Uri wf_uri = uri::from_file_path(tmem, (String)cwd);
	lsp::WorkspaceFolder wf = {
		.uri = (DocumentUri)wf_uri.to_raw_string(tmem),
		.name = "c3_ls",
	};

	lsp::core::config::load(&proj, wf, mem);

	assert(proj.config.test_sources.has_value);

	String test_file_path = string::tformat("%s/test/analyzer/statement_tests.c3", (String)cwd);

	Uri doc_uri = uri::from_file_path(tmem, test_file_path);
	proj.open_file({ .uri = (DocumentUri)doc_uri.to_raw_string(tmem), .text = "" });

	proj.update();
	assert(proj.workspace.ctx.modules.has_key("parser_tests"));
}

fn void test_project_multi_target_sources()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	proj.config.root_path = "/mock/root".copy(mem);

	// Target 1: default target (empty sources)
	TargetConfig t1 = {};
	proj.config.targets.init(mem);
	proj.config.targets["main_target"] = t1;

	// Target 2: secondary target with its own sources
	TargetConfig t2 = {};
	String[] t2_sources = alloc::alloc_array(mem, String, 1);
	t2_sources[0] = "extra_target/**".copy(mem);
	t2.sources = maybe::value(t2_sources);
	proj.config.targets["secondary_target"] = t2;

	proj.setup_source_groups();

	bool found_secondary = false;
	for (sz i = 0; i < proj.source_groups.len(); i++)
	{
		SourceGroup* g = proj.source_groups.get_ref(i);
		if (g.name == "secondary_target")
		{
			found_secondary = true;
			assert(!g.is_loaded);
			assert(g.patterns.len == 1);
			assert(g.patterns[0] == "extra_target/**");
		}
	}
	assert(found_secondary);

	assert(proj.file_matches_patterns("/mock/root/extra_target/sub/file.c3", t2_sources));
	assert(!proj.file_matches_patterns("/mock/root/other/file.c3", t2_sources));
}
