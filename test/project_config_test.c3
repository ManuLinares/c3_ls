module lsp::project_config_test @test;

import lsp;
import lsp::core;
import lsp::core::config;
import std::io;
import uri;

macro LspProject* load_project(String json)
{
	Path root = path::temp_directory(tmem)!!.tappend("c3_ls_project_config_test")!!;
	(void)path::rmtree(root);
	(void)path::mkdir(root, recursive: true);
	file::save(root.tappend("project.json")!!, json)!!;
	LspProject* proj = alloc::new(tmem, LspProject);
	proj.init(tmem);
	config::load(proj, { .uri = (LspUri)uri::from_file_path(tmem, root).to_raw_string(tmem) }, tmem);
	(void)path::rmtree(root);
	return proj;
}

fn void project_json_keys_are_loaded()
{
	LspProject* proj = load_project(`{
		// project.json allows comments and trailing commas
		"sources": [ "src/**" ],
		"test-sources": [ "test/**" ],
		"dependencies": [ "base" ],
		"features": [ "F" ],
		"warnings": [ "no-unused" ],
		"targets": {
			"app": {
				"type": "executable",
				"sources-override": [ "app/**" ],
				"test-sources-override": [ "app_test/**" ],
				"features-override": [ "LSP_TARGET" ],
				"dependencies-override": [ "sdl" ],
				"dependency-search-paths-override": [ "vendor" ],
			},
			"tool": {
				"sources": [ "tool/**" ],
				"test-sources": [ "tool_test/**" ],
				"features": [ "T" ],
				"dependencies": [ "extra" ],
				"dependency-search-paths": [ "tool_lib" ],
			},
		},
	}`);
	ProjectConfig conf = proj.config;
	test::eq(conf.sources[0], "src/**");
	test::eq(conf.test_sources[0], "test/**");
	test::eq(conf.dependencies[0], "base");
	test::eq(conf.features[0], "F");
	test::eq(conf.dependency_search_paths.len, 1);
	test::eq(conf.dependency_search_paths[0], "lib");

	TargetConfig app = conf.targets["app"]!!;
	test::eq(app.sources_override[0], "app/**");
	test::eq(app.test_sources_override[0], "app_test/**");
	test::eq(app.features_override[0], "LSP_TARGET");
	test::eq(app.dependencies_override[0], "sdl");
	test::eq(app.dependency_search_paths_override[0], "vendor");

	TargetConfig tool = conf.targets["tool"]!!;
	test::eq(tool.sources[0], "tool/**");
	test::eq(tool.test_sources[0], "tool_test/**");
	test::eq(tool.features[0], "T");
	test::eq(tool.dependencies[0], "extra");
	test::eq(tool.dependency_search_paths[0], "tool_lib");
}

fn void explicit_dependency_search_paths_replace_the_default()
{
	LspProject* proj = load_project(`{ "dependency-search-paths": [ "libs", "more" ] }`);
	test::eq(proj.config.dependency_search_paths.len, 2);
	test::eq(proj.config.dependency_search_paths[1], "more");
}

fn void reloading_config_frees_previous_one()
{
	Path root = path::temp_directory(tmem)!!.tappend("c3_ls_project_config_reload_test")!!;
	(void)path::rmtree(root);
	(void)path::mkdir(root, recursive: true);
	defer (void)path::rmtree(root);
	file::save(root.tappend("project.json")!!, `{ "sources": [ "src/**" ], "features": [ "F" ], "targets": { "app": { "sources-override": [ "app/**" ] } } }`)!!;

	LspProject proj;
	WorkspaceFolder wf = { .uri = (LspUri)uri::from_file_path(tmem, root).to_raw_string(tmem) };
	config::load(&proj, wf, mem);
	config::load(&proj, wf, mem);
	proj.config.free(mem);
}
