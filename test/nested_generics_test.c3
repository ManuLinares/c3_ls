// test/nested_generics_test.c3
module lsp::nested_generics_test @test;

import lsp::core;
import lsp::analysis::hover;
import lsp::analysis::goto_definition;
import lsp;
import uri;
import std::io;

fn void test_nested_generics_navigation_and_hover()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String map_lib = "module std::collections::map;\nstruct HashMap <Key, Value> { sz count; }\nfn void HashMap.set(&self, Key k, Value v) {}\n";
	String list_lib = "module std::collections::list;\nstruct List <Type> { sz len; }\nfn void List.push(&self, Type item) {}\n";
	String app_code = "module app;\nimport std::collections::map;\nimport std::collections::list;\nfn void run() {\n  HashMap{String, List{int}} registry;\n  registry.set(\"users\", {});\n}\n";

	proj.workspace.process_file("/virtual/map.c3", map_lib);
	proj.workspace.process_file("/virtual/list.c3", list_lib);
	proj.workspace.process_file("/virtual/nested.c3", app_code);

	Uri app_uri = uri::from_file_path(mem, "/virtual/nested.c3");
	defer app_uri.free();

	// 1. Hover on HashMap{String, List{int}}
	LspPosition map_pos = { .line = 4, .character = 4 };
	String h = hover::hover(&proj, app_uri, map_pos)!!;
	assert(h.contains("HashMap"));

	// 2. Goto definition on `set` method
	LspPosition set_pos = { .line = 5, .character = 12 };
	LspLocation[] locs = goto_definition::goto_definition(&proj, app_uri, set_pos)!!;
	assert(locs.len > 0);
	assert(locs[0].uri.contains("map.c3"));
}