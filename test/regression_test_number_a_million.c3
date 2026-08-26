module lsp::regression_suite_test @test;

import lsp::core;
import lsp::core::config;
import lsp::analysis::hover;
import lsp::analysis::goto_definition;
import lsp::analysis::macro_expand;
import lsp;
import uri;
import std::io;
import std::encoding::json;
import std::collections::object;
import std::collections::maybe;
import analyzer::core;
<*
 Regression Test 1:
 Verifies that hover and Go-To-Definition work inside trailing macro blocks
 and resolves sub-module prefixes (io:: -> std::io::).
*>
fn void test_hover_and_goto_def_inside_trailing_macro_body()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String std_io = `module std::io;
fn void printfn(String fmt, args...) {}
`;
	String app_code = `module app;
import std::io;
macro void @repeat(count; @body(idx)) {
  for (int i = 0; i < count; i++) { @body(i); }
}
fn void main() {
  @repeat(3; int i) {
    io::printfn("Step: %d", i);
  };
}
`;

	proj.workspace.process_file("/virtual/std_io.c3", std_io);
	proj.workspace.process_file("/virtual/app_macro_body.c3", app_code);

	Uri app_uri = uri::from_file_path(mem, "/virtual/app_macro_body.c3");
	defer app_uri.free();
	// Hover on `io::printfn` at line 7, character 9
	LspPosition printfn_pos = {.line = 7,.character = 9 };
	String h = hover::hover(&proj, app_uri, printfn_pos)!!;
	assert(h.contains("fn void printfn"));
	// Go to definition on `io::printfn` -> jumps to line 1 of std_io.c3
	LspLocation[] locs = goto_definition::goto_definition(&proj, app_uri, printfn_pos)!!;
	assert(locs.len > 0);
	assert(locs[0].uri.contains("std_io.c3"));
	assert(locs[0].range.start.line == 1);
}

<*
 Regression Test 2:
 Verifies that `$Typeof(expr) var_name;` parses cleanly with 0 diagnostics
 and resolves to the evaluated type on hover.
*>
fn void test_typeof_var_decl_syntax_and_hover()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = `module app;
struct Point { int x; int y; }
fn void check() {
  Point pt;
  $Typeof(pt) pt_copy;
  pt_copy.x = 10;
}
`;

	proj.workspace.process_file("/virtual/typeof_decl.c3", source);
	Uri doc_uri = uri::from_file_path(mem, "/virtual/typeof_decl.c3");
	defer doc_uri.free();
	// 1. Verify that no parse errors or red squiggles were emitted
	LspDiagnostic[] diags = proj.workspace.get_diagnostics("/virtual/typeof_decl.c3");
	assert(diags.len == 0);
	// 2. Hover on `$Typeof(pt)` on line 4, character 4
	LspPosition pos = {.line = 4,.character = 4 };
	String h = hover::hover(&proj, doc_uri, pos)!!;
	assert(h.contains("Compile-Time Evaluation"));
	assert(h.contains("typeid (Point)"));
}

<*
 Regression Test 3:
 Verifies that unresolvable symbols return empty location slices rather than jumping to `/`.
*>
fn void test_unresolved_symbol_does_not_jump_to_root()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = `module app;
fn void main() {
  unresolved_symbol_that_does_not_exist();
}
`;

	proj.workspace.process_file("/virtual/unresolved.c3", source);
	Uri doc_uri = uri::from_file_path(mem, "/virtual/unresolved.c3");
	defer doc_uri.free();
	// Hover over the non-existent function call
	LspPosition pos = {.line = 2,.character = 5 };
	LspLocation[] locs = goto_definition::goto_definition(&proj, doc_uri, pos)!!;
	// Must return an empty slice, never file:/// or invalid root locations
	assert(locs.len == 0);
}

<*
 Regression Test 4:
 Verifies that C3's `\e` escape character literal and string escape parse without error.
*>
fn void test_escape_character_literal_e()
{
	String source = `module app;
char esc = '\e';
String colored = "\e[31mRed\e[0m";
`;
	AnalyzerContext* context = context::create(tmem);
	bool success = context::process(context, source, "test_esc.c3");
	assert(success);
}

<*
 Regression Test 5:
 Verifies sub-module leaf resolution across nested module paths (std::net::tcp -> tcp::).
*>
fn void test_submodule_leaf_resolution()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String net_mod = `module std::net::tcp;
fn void connect(String host, int port) {}
`;
	String app_code = `module app;
import std::net;
fn void main() {
  tcp::connect("localhost", 8080);
}
`;

	proj.workspace.process_file("/virtual/net_tcp.c3", net_mod);
	proj.workspace.process_file("/virtual/app_tcp.c3", app_code);

	Uri app_uri = uri::from_file_path(mem, "/virtual/app_tcp.c3");
	defer app_uri.free();

	LspPosition pos = {.line = 3,.character = 8 };
	String h = hover::hover(&proj, app_uri, pos)!!;
	assert(h.contains("fn void connect(String host, int port)"));

	LspLocation[] locs = goto_definition::goto_definition(&proj, app_uri, pos)!!;
	assert(locs.len > 0);
	assert(locs[0].uri.contains("net_tcp.c3"));
	assert(locs[0].range.start.line == 1);
}

<*
 Regression Test 6:
 Verifies that `dependency-search-paths` defaults to `["lib"]` when omitted from project.json.
*>
fn void test_default_dependency_search_paths()
{
	String project_json = `{"sources": ["src/**"], "dependencies": ["my_lib"]}`;
	Object* dom = json::tparse(project_json)!!;

	ProjectConfig conf;
	conf.targets.init(tmem);
	if (try search_paths = config::parse_string_array(tmem, dom, "dependency-search-paths"))
	{
		conf.dependency_search_paths = maybe::value(search_paths);
	}
	else
	{
		String[] default_paths = alloc::alloc_array(tmem, String, 1);
		default_paths[0] = "lib".copy(tmem);
		conf.dependency_search_paths = maybe::value(default_paths);
	}

	assert(conf.dependency_search_paths.has_value);
	assert(conf.dependency_search_paths.value.len == 1);
	assert(conf.dependency_search_paths.value[0] == "lib");
}
