module lsp::workspace_test @test;

import lsp;
import lsp::core;
import analyzer::core;
import analyzer::sema::query;
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

	assert(proj.config.test_sources.len > 0);

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
	t2.sources = t2_sources;
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

fn void test_find_enclosing_project_root()
{
	Path cwd = path::tcwd()!!;
	String test_file = string::tformat("%s/src/server.c3", (String)cwd);

	String dir = test_file;
	if (!file::is_dir(dir))
	{
		dir = dir.path_tdirname() ?? "";
	}

	String found_root = "";
	while (dir.len > 0)
	{
		Path? base_p = path::tnew(dir);
		if (catch base_p) break;

		Path proj_json = base_p.tappend(lsp::core::config::PROJECT_CONFIG_NAME) ?? (Path)"";
		Path manifest_json = base_p.tappend(lsp::core::config::MANIFEST_CONFIG_NAME) ?? (Path)"";

		if (path::exists(proj_json) || path::exists(manifest_json))
		{
			found_root = dir.copy(tmem);
			break;
		}

		String parent = dir.path_tdirname() ?? "";
		if (parent.len == 0 || parent == dir) break;
		dir = parent;
	}

	test::eq(found_root, (String)cwd);
}

fn void test_standalone_file_initializes_stdlib()
{
	if (server::std_path.len == 0)
	{
		server::setup_stdlib_path();
	}
	defer server::set_std_path("");

	ProjectManager pm;
	pm.init(mem);
	defer pm.free();

	assert(!pm.default_project.is_initialized);

	pm.initial_process_all();
	assert(pm.default_project.is_initialized);

	LspProject* proj = pm.get_or_create_project_for_path("/virtual/standalone.c3");
	assert(proj == &pm.default_project);
	assert(proj.is_initialized);
}

fn void test_load_c3i_files_in_source_group()
{
	Path? tmp_dir = path::temp_directory(tmem);
	if (catch tmp_dir) return;

	Path test_dir = tmp_dir.tappend("c3_ls_c3i_source_test")!!;
	Path src_dir = test_dir.tappend("src")!!;
	Path bindings_dir = src_dir.tappend("bindings")!!;
	(void)path::mkdir(bindings_dir, recursive: true);
	defer (void)path::rmtree(test_dir);

	Path c3i_path = bindings_dir.tappend("miniaudio.c3i")!!;
	file::save(c3i_path, "module miniaudio;\nfn void device_init() {}\n")!!;

	Path main_path = src_dir.tappend("main.c3")!!;
	file::save(main_path, "module app;\nimport miniaudio;\nfn void main() { miniaudio::device_init(); }\n")!!;

	LspProject proj;
	proj.init(mem);
	defer proj.free();

	proj.config.root_path = ((String)test_dir).copy(mem);
	String[] srcs = alloc::alloc_array(mem, String, 1);
	srcs[0] = "src/**".copy(mem);
	proj.config.sources = srcs;

	proj.setup_source_groups();

	// Open only main.c3 (miniaudio.c3i is NOT opened)
	Uri main_uri = uri::from_file_path(tmem, (String)main_path);
	proj.open_file({ .uri = (DocumentUri)main_uri.to_raw_string(tmem), .text = "" }, from_disk: false);
	proj.update();

	// Verify miniaudio.c3i was automatically discovered and parsed
	Uri c3i_uri = uri::from_file_path(tmem, (String)c3i_path);
	assert(proj.files.has_key(c3i_uri.path));
	assert(proj.workspace.ctx.modules.has_key("miniaudio"));
	test::eq(proj.workspace.get_diagnostics((String)main_path).len, 0);
}

fn void test_target_sources_lazy_loaded_on_file_open()
{
	Path? tmp_dir = path::temp_directory(tmem);
	if (catch tmp_dir) return;

	Path test_dir = tmp_dir.tappend("c3_ls_target_lazy_load_test")!!;
	Path src_common = test_dir.tappend("src")!!.tappend("common")!!;
	Path src_server = test_dir.tappend("src")!!.tappend("server")!!;
	(void)path::mkdir(src_common, recursive: true);
	(void)path::mkdir(src_server, recursive: true);
	defer (void)path::rmtree(test_dir);

	Path common_file = src_common.tappend("simulation.c3")!!;
	file::save(common_file, "module common;\nfn void tick() {}\n")!!;

	Path main_file = src_server.tappend("main.c3")!!;
	String main_src = "module server_app;\nimport common;\nfn void main() { common::tick(); }\n";
	file::save(main_file, main_src)!!;

	LspProject proj;
	proj.init(mem);
	defer proj.free();

	proj.config.root_path = ((String)test_dir).copy(mem);
	proj.config.targets.init(mem);

	TargetConfig server_target = {};
	String[] s_sources = alloc::alloc_array(mem, String, 2);
	s_sources[0] = "src/common/**".copy(mem);
	s_sources[1] = "src/server/**".copy(mem);
	server_target.sources = s_sources;
	proj.config.targets["server"] = server_target;

	proj.setup_source_groups();

	Uri main_uri = uri::from_file_path(tmem, (String)main_file);
	proj.open_file({ .uri = (DocumentUri)main_uri.to_raw_string(tmem), .text = main_src }, from_disk: false);
	proj.update();

	assert(proj.workspace.ctx.modules.has_key("common"));
	test::eq(proj.workspace.get_diagnostics((String)main_file).len, 0);
}

fn void test_mixed_slash_stem_and_parent_dir()
{
	test::eq(query::file_stem_from_path("C:/Users/mb\\project/main.c3"), "main");
	test::eq(query::file_stem_from_path("C:\\Users\\mb/test.c3"), "test");
	test::eq(query::file_stem_from_path("/root/single.c3"), "single");
	test::eq(query::file_stem_from_path("standalone.c3"), "standalone");
	test::eq(query::file_stem_from_path("\\root_file.c3"), "root_file");
}
fn void test_project_manager_frees_registered_projects()
{
	Path root = path::temp_directory(tmem)!!.tappend("c3_ls_project_manager_free_test")!!;
	(void)path::rmtree(root);
	(void)path::mkdir(root, recursive: true);
	defer (void)path::rmtree(root);
	file::save(root.tappend("project.json")!!, `{ "sources": [ "src/**" ] }`)!!;

	ProjectManager pm;
	pm.init(mem);
	pm.add_workspace_folder({ .uri = (LspUri)uri::from_file_path(tmem, root).to_raw_string(tmem) });
	assert(pm.projects.len() == 1);
	pm.free();
}

fn void test_project_manager_frees_discovered_subprojects()
{
	Path root = path::temp_directory(tmem)!!.tappend("c3_ls_project_manager_sub_test")!!;
	(void)path::rmtree(root);
	(void)path::mkdir(root.tappend("sub")!!, recursive: true);
	defer (void)path::rmtree(root);
	file::save(root.tappend("sub")!!.tappend("project.json")!!, `{ "sources": [ "src/**" ] }`)!!;

	ProjectManager pm;
	pm.init(mem);
	pm.add_workspace_folder({ .uri = (LspUri)uri::from_file_path(tmem, root).to_raw_string(tmem) });
	assert(pm.projects.len() == 1);
	pm.free();
}

fn void test_project_manager_frees_attached_projects()
{
	Path root = path::temp_directory(tmem)!!.tappend("c3_ls_project_manager_attach_test")!!;
	(void)path::rmtree(root);
	(void)path::mkdir(root, recursive: true);
	defer (void)path::rmtree(root);
	file::save(root.tappend("project.json")!!, `{ "sources": [ "src/**" ] }`)!!;

	ProjectManager pm;
	pm.init(mem);
	(void)pm.get_or_create_project_for_path((String)root.tappend("main.c3")!!);
	assert(pm.projects.len() == 1);
	pm.free();
}
