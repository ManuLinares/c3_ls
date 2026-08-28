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

fn void test_hover_and_signature_help_on_literal_methods() @test
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = `module app;
fn double double.trunc(double self) => self;
fn void run() {
  double asd = 3.14.trunc();
}
`;

	proj.workspace.process_file("/virtual/lit_method.c3", source);
	Uri doc_uri = uri::from_file_path(mem, "/virtual/lit_method.c3");
	defer doc_uri.free();

	// 1. Hover on `trunc` (line 3, character 21)
	LspPosition hover_pos = { .line = 3, .character = 21 };
	String h = hover::hover(&proj, doc_uri, hover_pos)!!;
	assert(h.contains("double.trunc"));

	// 2. Signature help inside `3.14.trunc(` (line 3, character 26)
	LspPosition sig_pos = { .line = 3, .character = 26 };
	SignatureHelpResult sig_res = signature_help::signature_help(&proj, doc_uri, sig_pos)!!;
	assert(sig_res.signatures.len > 0);
	assert(sig_res.signatures[0].label.contains("double.trunc"));
}

fn void test_hover_and_signature_help_on_primitive_methods() @test
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = `module app;
fn double double.custom_clamp(self, double min, double max) => self;

fn void test() {
  double asd = 3.14;
  asd.custom_clamp(1.0, 5.0);
}
`;

	proj.workspace.process_file("/virtual/prim_method_test.c3", source);
	Uri doc_uri = uri::from_file_path(mem, "/virtual/prim_method_test.c3");
	defer doc_uri.free();

	// 1. Hover on `custom_clamp` (line 5, character 8)
	LspPosition hover_pos = { .line = 5, .character = 8 };
	String h = hover::hover(&proj, doc_uri, hover_pos)!!;
	assert(h.contains("double.custom_clamp"));

	// 2. Go to definition on `custom_clamp` -> line 1
	LspLocation[] locs = goto_definition::goto_definition(&proj, doc_uri, hover_pos)!!;
	assert(locs.len > 0);
	assert(locs[0].range.start.line == 1);

	// 3. Signature help inside `asd.custom_clamp(` (line 5, character 19)
	LspPosition sig_pos = { .line = 5, .character = 19 };
	SignatureHelpResult sig_res = signature_help::signature_help(&proj, doc_uri, sig_pos)!!;
	assert(sig_res.signatures.len > 0);
	assert(sig_res.signatures[0].label.contains("double.custom_clamp"));
}

fn void test_some_reported_trunc_and_custom_clamp() @test
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String math_code = `module std::math;
fn double double.trunc(double self) => self;
macro clamp(val, min, max) => val;
`;

	String source = `module app;
import std::io;

fn double double.custom_clamp(self, double min, double max) => self;

fn void oidoidoidoid()
{
	double asd = (3.14f).trunc();
	io::printn(asd);
}

fn void test() {
    double asd = 3.14;
    asd.custom_clamp(1.0, 5.0);
}
`;

	proj.workspace.process_file("/virtual/math.c3", math_code);
	proj.workspace.process_file("/virtual/user_test.c3", source);
	Uri doc_uri = uri::from_file_path(mem, "/virtual/user_test.c3");
	defer doc_uri.free();

	// 1. Hover on `trunc` in `(3.14f).trunc()` (line 7, character 24)
	LspPosition trunc_pos = { .line = 7, .character = 24 };
	String trunc_hover = hover::hover(&proj, doc_uri, trunc_pos)!!;
	assert(trunc_hover.contains("trunc"));

	// 2. Hover on `custom_clamp` in `asd.custom_clamp(...)` (line 13, character 10)
	LspPosition clamp_pos = { .line = 13, .character = 10 };
	String clamp_hover = hover::hover(&proj, doc_uri, clamp_pos)!!;
	assert(clamp_hover.contains("double.custom_clamp"));

	// 3. Go to definition on `custom_clamp` -> line 3
	LspLocation[] locs = goto_definition::goto_definition(&proj, doc_uri, clamp_pos)!!;
	assert(locs.len > 0);
	assert(locs[0].range.start.line == 3);

	// 4. Signature help inside `asd.custom_clamp(` (line 13, character 22)
	LspPosition sig_pos = { .line = 13, .character = 22 };
	SignatureHelpResult sig_res = signature_help::signature_help(&proj, doc_uri, sig_pos)!!;
	assert(sig_res.signatures.len > 0);
	assert(sig_res.signatures[0].parameters.len == 2); // `min` and `max` (`self` omitted)
	assert(sig_res.signatures[0].parameters[0].label.contains("min"));
}

fn void test_another_exact_snippet_with_import_std() @test
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String math_code = `module std::math;
fn double double.trunc(double self) => self;
macro clamp(val, min, max) => val;
`;

	String user_code = `module asdasasdasdasd;
import std;

fn void oidoidoidoid()
{
	double asd = 3.14.trunc();
	io::printn(asd);
}

fn double double.custom_clamp(self, double min, double max) => math::clamp(self, min, max);

fn void test() {
    double asd = 3.14;
    asd.custom_clamp();
}
`;

	proj.workspace.process_file("/virtual/math.c3", math_code);
	proj.workspace.process_file("/virtual/user_exact.c3", user_code);

	Uri doc_uri = uri::from_file_path(mem, "/virtual/user_exact.c3");
	defer doc_uri.free();

	// 1. Hover on `trunc` in `3.14.trunc()` (line 5, character 20)
	LspPosition trunc_pos = { .line = 5, .character = 20 };
	String trunc_hover = hover::hover(&proj, doc_uri, trunc_pos)!!;
	assert(trunc_hover.contains("trunc"));

	// 2. Go to definition on `trunc` -> jumps to math.c3
	LspLocation[] trunc_locs = goto_definition::goto_definition(&proj, doc_uri, trunc_pos)!!;
	assert(trunc_locs.len > 0);
	assert(trunc_locs[0].uri.contains("math.c3"));

	// 3. Hover on `custom_clamp` in `asd.custom_clamp()` (line 13, character 10)
	LspPosition clamp_pos = { .line = 13, .character = 10 };
	String clamp_hover = hover::hover(&proj, doc_uri, clamp_pos)!!;
	assert(clamp_hover.contains("double.custom_clamp"));

	// 4. Go to definition on `custom_clamp` -> jumps to line 9
	LspLocation[] clamp_locs = goto_definition::goto_definition(&proj, doc_uri, clamp_pos)!!;
	assert(clamp_locs.len > 0);
	assert(clamp_locs[0].range.start.line == 9);

	// 5. Signature help inside `asd.custom_clamp(` (line 13, character 21)
	LspPosition sig_pos = { .line = 13, .character = 21 };
	SignatureHelpResult sig_res = signature_help::signature_help(&proj, doc_uri, sig_pos)!!;
	assert(sig_res.signatures.len > 0);
	assert(sig_res.signatures[0].parameters.len == 2);
	assert(sig_res.signatures[0].parameters[0].label.contains("min"));
}

fn void test_method_with_arbitrary_receiver_name() @test
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = `module app;
struct Point { int x; int y; }
fn void Point.offset(Point* p, int dx, int dy) {
  p.x += dx;
  p.y += dy;
}

fn void run() {
  Point pt;
  pt.offset(5, 10);
}
`;

	proj.workspace.process_file("/virtual/custom_pname.c3", source);
	Uri doc_uri = uri::from_file_path(mem, "/virtual/custom_pname.c3");
	defer doc_uri.free();

	// Line 9: `  pt.offset(5, 10);`
	LspPosition sig_pos = { .line = 9, .character = 12 };
	SignatureHelpResult sig_res = signature_help::signature_help(&proj, doc_uri, sig_pos)!!;
	assert(sig_res.signatures.len > 0);
	assert(sig_res.signatures[0].parameters.len == 2); // `dx` and `dy` (`p` is omitted)
	assert(sig_res.signatures[0].parameters[0].label.contains("dx"));
	assert(sig_res.signatures[0].parameters[1].label.contains("dy"));
}


fn void test_my_exact_vscode_file_flow() @test
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = `module asdasasdasdasd;
import std;

fn void oidoidoidoid()
{
	double asd = 3.14.trunc();
	io::printn(asd);
}

fn double double.custom_clamp(self, double min, double max) => math::clamp(self, min, max);

fn void test() {
    double asd = 3;
    asd.custom_clamp(2, 5);
}
`;

	proj.workspace.process_file("/virtual/user_exact_vscode.c3", source);
	Uri doc_uri = uri::from_file_path(mem, "/virtual/user_exact_vscode.c3");
	defer doc_uri.free();

	// 1. Completion on `asd.` (line 13, character 8)
	LspPosition comp_pos = { .line = 13, .character = 8 };
	CompletionItem[] items = completion::resolve(&proj, doc_uri, comp_pos)!!;
	CompletionItem clamp_item;
	bool found_clamp = false;
	foreach (item : items)
	{
		if (item.label == "custom_clamp")
		{
			clamp_item = item;
			found_clamp = true;
			break;
		}
	}
	assert(found_clamp);

	// 2. Completion item resolve (documentation popup)
	completion::resolve_item(&proj, &clamp_item);
	assert(clamp_item.documentation.value.contains("double.custom_clamp"));

	// 3. Hover on `custom_clamp` in `asd.custom_clamp(2, 5);` (line 13, character 12)
	LspPosition hover_pos = { .line = 13, .character = 12 };
	String h = hover::hover(&proj, doc_uri, hover_pos)!!;
	assert(h.contains("double.custom_clamp"));

	// 4. Go to definition on `custom_clamp` -> jumps to line 9
	LspLocation[] locs = goto_definition::goto_definition(&proj, doc_uri, hover_pos)!!;
	assert(locs.len > 0);
	assert(locs[0].range.start.line == 9);

	// 5. Signature help inside `asd.custom_clamp(` (line 13, character 21)
	LspPosition sig_pos = { .line = 13, .character = 21 };
	SignatureHelpResult sig_res = signature_help::signature_help(&proj, doc_uri, sig_pos)!!;
	assert(sig_res.signatures.len > 0);
	assert(sig_res.signatures[0].parameters.len == 2);
	assert(sig_res.signatures[0].parameters[0].label.contains("min"));
}