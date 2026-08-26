module lsp::hover_definition_test @test;

import lsp::core;
import lsp::analysis::hover;
import lsp::analysis::goto_definition;
import lsp;
import uri;
import std::io;

fn void test_hover_on_function()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = "<*\n Greets a person\n*>\nfn void greet_user(int id) {}\n";
	Uri doc_uri = uri::from_file_path(mem, "/virtual/main.c3");
	defer doc_uri.free();

	proj.workspace.process_file("/virtual/main.c3", source);

	LspPosition pos = {.line = 3,.character = 10 };
	String hover_res = hover::hover(&proj, doc_uri, pos)!!;
	assert(hover_res.contains("greet_user"));
	assert(hover_res.contains("Greets a person"));
}

fn void test_goto_definition()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = "module my_mod;\nfn void target_fn() {}\nfn void caller() { target_fn(); }\n";
	Uri doc_uri = uri::from_file_path(mem, "/virtual/test_goto.c3");
	defer doc_uri.free();

	proj.workspace.process_file("/virtual/test_goto.c3", source);

	LspPosition pos = {.line = 2,.character = 22 };
	LspLocation[] locs = goto_definition::goto_definition(&proj, doc_uri, pos)!!;
	assert(locs.len > 0);
	assert(locs[0].range.start.line == 1);
}

fn void test_receiver_method_disambiguation()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String list_def = "module std::collections::list;\nstruct List <Type> { int count; }\nfn void List.tinit(&self, sz cap = 16) {}\n";
	String hash_def = "module std::crypto::parallel_hash;\nstruct ParallelHash { int x; }\nfn void ParallelHash.tinit(&self, sz block_size = 0) {}\n";
	String main_code = "module app;\nimport std::collections::list;\nimport std::crypto::parallel_hash;\nfn void main() {\n  List{String} files_to_open;\n  files_to_open.tinit(10);\n}\n";

	proj.workspace.process_file("/virtual/list.c3", list_def);
	proj.workspace.process_file("/virtual/hash.c3", hash_def);
	proj.workspace.process_file("/virtual/app.c3", main_code);

	Uri app_uri = uri::from_file_path(mem, "/virtual/app.c3");
	defer app_uri.free();

	LspPosition pos = {.line = 5,.character = 18 };
	String hover_res = hover::hover(&proj, app_uri, pos)!!;
	assert(hover_res.contains("List.tinit"));
	assert(!hover_res.contains("ParallelHash.tinit"));

	LspLocation[] locs = goto_definition::goto_definition(&proj, app_uri, pos)!!;
	assert(locs.len > 0);
	assert(locs[0].uri.contains("list.c3"));
}

fn void test_module_scoped_call_hover_and_definition()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String gfx_code = "module gfx;\nfn void init_window(int w, int h, String title) {}\nfn bool should_close() { return false; }\n";
	String main_code = "module app;\nimport gfx;\nfn void main() {\n  gfx::init_window(1024, 600, \"Editor\");\n  bool c = gfx::should_close();\n}\n";

	proj.workspace.process_file("/virtual/gfx.c3", gfx_code);
	proj.workspace.process_file("/virtual/app.c3", main_code);

	Uri app_uri = uri::from_file_path(mem, "/virtual/app.c3");
	defer app_uri.free();

	LspPosition gfx_pos = {.line = 3,.character = 4 };
	String gfx_hover = hover::hover(&proj, app_uri, gfx_pos)!!;
	assert(gfx_hover.contains("module gfx;"));

	LspPosition init_pos = {.line = 3,.character = 10 };
	String init_hover = hover::hover(&proj, app_uri, init_pos)!!;
	assert(init_hover.contains("fn void init_window(int w, int h, String title)"));

	LspLocation[] locs = goto_definition::goto_definition(&proj, app_uri, init_pos)!!;
	assert(locs.len > 0);
	assert(locs[0].uri.contains("gfx.c3"));
	assert(locs[0].range.start.line == 1);
}

fn void test_short_body_expression_goto_definition()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String gfx_code = "module gfx;\nfn bool is_key_pressed(int key) { return false; }\nfn bool is_key_repeat(int key) { return false; }\n";
	String app_code = "module app;\nimport gfx;\nfn bool key_pressed_or_repeat(int key) => gfx::is_key_pressed(key) || gfx::is_key_repeat(key);\n";

	proj.workspace.process_file("/virtual/gfx_keys.c3", gfx_code);
	proj.workspace.process_file("/virtual/app_keys.c3", app_code);

	Uri app_uri = uri::from_file_path(mem, "/virtual/app_keys.c3");
	defer app_uri.free();

	LspPosition pos = {.line = 2,.character = 50 };
	LspLocation[] locs = goto_definition::goto_definition(&proj, app_uri, pos)!!;
	assert(locs.len > 0);
	assert(locs[0].uri.contains("gfx_keys.c3"));
	assert(locs[0].range.start.line == 1);
}

fn void test_self_member_hover_and_definition()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = "module vec_app;\nstruct Vector2 {\n  float x;\n  float y;\n}\nfn void Vector2.scale(&self, float factor) {\n  self.x *= factor;\n}\n";

	proj.workspace.process_file("/virtual/vec.c3", source);

	Uri doc_uri = uri::from_file_path(mem, "/virtual/vec.c3");
	defer doc_uri.free();

	LspPosition pos = {.line = 6,.character = 7 };
	String h = hover::hover(&proj, doc_uri, pos)!!;
	assert(h.contains("float x"));

	LspLocation[] locs = goto_definition::goto_definition(&proj, doc_uri, pos)!!;
	assert(locs.len > 0);
	assert(locs[0].range.start.line == 2);
}

fn void test_macro_with_at_prefix_not_confused_with_unrelated_local_var()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = `module md5_test;
macro void @step(int a, int b) {}
fn void parse_match() {
  int step = 42;
}
fn void run_calc() {
  @step(1, 2);
}
`;

	proj.workspace.process_file("/virtual/md5_step.c3", source);

	Uri doc_uri = uri::from_file_path(mem, "/virtual/md5_step.c3");
	defer doc_uri.free();
	// Line 6: `  @step(1, 2);` -> cursor on `@step`
	LspPosition pos = {.line = 6,.character = 4 };
	LspLocation[] locs = goto_definition::goto_definition(&proj, doc_uri, pos)!!;
	assert(locs.len > 0);
	assert(locs[0].range.start.line == 1);  // Macro definition line, not local `int step` on line 3!
}

fn void test_syntax_error_recovery_maintains_subsequent_definitions()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String list_def = "module std::collections::list;\nstruct List <Type> { int count; }\nfn void List.tinit(&self, sz cap = 16) {}\n";
	String broken_main = "module app;\nimport std::collections::list;\nfn void main() {\n  List{String} files_to_open;asd as\n  files_to_open.tinit(10);\n}\n";

	proj.workspace.process_file("/virtual/list.c3", list_def);
	proj.workspace.process_file("/virtual/app_broken.c3", broken_main);

	Uri app_uri = uri::from_file_path(mem, "/virtual/app_broken.c3");
	defer app_uri.free();

	LspPosition pos = {.line = 4,.character = 18 };
	String hover_res = hover::hover(&proj, app_uri, pos)!!;
	assert(hover_res.contains("List.tinit"));

	LspLocation[] locs = goto_definition::goto_definition(&proj, app_uri, pos)!!;
	assert(locs.len > 0);
	assert(locs[0].uri.contains("list.c3"));
}

fn void test_goto_definition_enum_variant_and_return_expr()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String code = "module app;\nconstdef Key : int { NONE = 0, PAGE_UP = 266 }\nfn bool check_key(Key k) { return true; }\nmacro void @test_macro() {\n  if (check_key(PAGE_UP)) {}\n}\nfn int calculate() {\n  int idx = 42;\n  return idx;\n}\n";

	proj.workspace.process_file("/virtual/app_keys.c3", code);

	Uri app_uri = uri::from_file_path(mem, "/virtual/app_keys.c3");
	defer app_uri.free();

	LspPosition page_up_pos = {.line = 4,.character = 18 };
	LspLocation[] locs1 = goto_definition::goto_definition(&proj, app_uri, page_up_pos)!!;
	assert(locs1.len > 0);
	assert(locs1[0].range.start.line == 1);

	LspPosition return_idx_pos = {.line = 8,.character = 10 };
	LspLocation[] locs2 = goto_definition::goto_definition(&proj, app_uri, return_idx_pos)!!;
	assert(locs2.len > 0);
	assert(locs2[0].range.start.line == 7);
}

fn void test_hover_on_typedef_and_alias()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = "module my_mod;\ntypedef UserId = ulong;\nalias StringList = List{String};\n";
	Uri doc_uri = uri::from_file_path(mem, "/virtual/typedefs.c3");
	defer doc_uri.free();

	proj.workspace.process_file("/virtual/typedefs.c3", source);

	LspPosition user_id_pos = {.line = 1,.character = 9 };
	String hover_td = hover::hover(&proj, doc_uri, user_id_pos)!!;
	assert(hover_td.contains("typedef UserId = ulong"));

	LspPosition alias_pos = {.line = 2,.character = 7 };
	String hover_alias = hover::hover(&proj, doc_uri, alias_pos)!!;
	assert(hover_alias.contains("alias StringList ="));
}

fn void test_goto_definition_struct_member_designated_init()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = "module app;\nstruct Config {\n  int port;\n  String host;\n}\nfn void setup() {\n  Config c = { .port = 8080, .host = \"localhost\" };\n}\n";
	Uri doc_uri = uri::from_file_path(mem, "/virtual/designated_init.c3");
	defer doc_uri.free();

	proj.workspace.process_file("/virtual/designated_init.c3", source);

	LspPosition pos = {.line = 6,.character = 17 };
	LspLocation[] locs = goto_definition::goto_definition(&proj, doc_uri, pos)!!;
	assert(locs.len > 0);
	assert(locs[0].range.start.line == 2);
}
