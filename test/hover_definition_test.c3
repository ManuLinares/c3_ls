module lsp::hover_definition_test @test;

import lsp, uri, std::io;

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
	LspLocation[] locs = definition::goto_definition(&proj, doc_uri, pos)!!;
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

	LspLocation[] locs = definition::goto_definition(&proj, app_uri, pos)!!;
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
	assert(gfx_hover.contains("module gfx\n"));

	LspPosition init_pos = {.line = 3,.character = 10 };
	String init_hover = hover::hover(&proj, app_uri, init_pos)!!;
	assert(init_hover.contains("fn void init_window(int w, int h, String title)"));

	LspLocation[] locs = definition::goto_definition(&proj, app_uri, init_pos)!!;
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
	LspLocation[] locs = definition::goto_definition(&proj, app_uri, pos)!!;
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

	LspLocation[] locs = definition::goto_definition(&proj, doc_uri, pos)!!;
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
	LspLocation[] locs = definition::goto_definition(&proj, doc_uri, pos)!!;
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

	LspLocation[] locs = definition::goto_definition(&proj, app_uri, pos)!!;
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
	LspLocation[] locs1 = definition::goto_definition(&proj, app_uri, page_up_pos)!!;
	assert(locs1.len > 0);
	assert(locs1[0].range.start.line == 1);

	LspPosition return_idx_pos = {.line = 8,.character = 10 };
	LspLocation[] locs2 = definition::goto_definition(&proj, app_uri, return_idx_pos)!!;
	assert(locs2.len > 0);
	assert(locs2[0].range.start.line == 7);
}

fn void test_hover_on_typedef_and_alias()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = "module my_mod; import std;\ntypedef UserId = ulong;\nalias StringList = List{String};\n";
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

fn void test_issue_3_doc_comments_on_hover_for_alias_and_typedef() @test
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = `<*
 func
 doc
 comment
*>
alias MyFunction = fn void();

<* my typedef *>
typedef Foo = int;

fn void test() {
    MyFunction func;
    Foo foo = 0;
}
`;
	Uri doc_uri = uri::from_file_path(mem, "/virtual/issue_3_doc.c3");
	defer doc_uri.free();

	proj.workspace.process_file("/virtual/issue_3_doc.c3", source);

	// 1. Hover on alias declaration (line 5, col 8)
	LspPosition alias_decl_pos = { .line = 5, .character = 8 };
	String h_alias_decl = hover::hover(&proj, doc_uri, alias_decl_pos)!!;
	assert(h_alias_decl.contains("alias MyFunction = fn void()"));
	assert(h_alias_decl.contains("func\n doc\n comment"));

	// 2. Hover on alias usage (line 11, col 6)
	LspPosition alias_use_pos = { .line = 11, .character = 6 };
	String h_alias_use = hover::hover(&proj, doc_uri, alias_use_pos)!!;
	assert(h_alias_use.contains("alias MyFunction = fn void()"));
	assert(h_alias_use.contains("func\n doc\n comment"));

	// 3. Hover on typedef declaration (line 8, col 10)
	LspPosition td_decl_pos = { .line = 8, .character = 10 };
	String h_td_decl = hover::hover(&proj, doc_uri, td_decl_pos)!!;
	assert(h_td_decl.contains("typedef Foo = int"));
	assert(h_td_decl.contains("my typedef"));

	// 4. Hover on typedef usage (line 12, col 6)
	LspPosition td_use_pos = { .line = 12, .character = 6 };
	String h_td_use = hover::hover(&proj, doc_uri, td_use_pos)!!;
	assert(h_td_use.contains("typedef Foo = int"));
	assert(h_td_use.contains("my typedef"));
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
	LspLocation[] locs = definition::goto_definition(&proj, doc_uri, pos)!!;
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
	LspLocation[] locs = definition::goto_definition(&proj, doc_uri, hover_pos)!!;
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
	LspLocation[] locs = definition::goto_definition(&proj, doc_uri, clamp_pos)!!;
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
	LspLocation[] trunc_locs = definition::goto_definition(&proj, doc_uri, trunc_pos)!!;
	assert(trunc_locs.len > 0);
	assert(trunc_locs[0].uri.contains("math.c3"));

	// 3. Hover on `custom_clamp` in `asd.custom_clamp()` (line 13, character 10)
	LspPosition clamp_pos = { .line = 13, .character = 10 };
	String clamp_hover = hover::hover(&proj, doc_uri, clamp_pos)!!;
	assert(clamp_hover.contains("double.custom_clamp"));

	// 4. Go to definition on `custom_clamp` -> jumps to line 9
	LspLocation[] clamp_locs = definition::goto_definition(&proj, doc_uri, clamp_pos)!!;
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
	LspLocation[] locs = definition::goto_definition(&proj, doc_uri, hover_pos)!!;
	assert(locs.len > 0);
	assert(locs[0].range.start.line == 9);

	// 5. Signature help inside `asd.custom_clamp(` (line 13, character 21)
	LspPosition sig_pos = { .line = 13, .character = 21 };
	SignatureHelpResult sig_res = signature_help::signature_help(&proj, doc_uri, sig_pos)!!;
	assert(sig_res.signatures.len > 0);
	assert(sig_res.signatures[0].parameters.len == 2);
	assert(sig_res.signatures[0].parameters[0].label.contains("min"));
}

fn void test_hover_on_incomplete_module_decl_crash() @test
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = "module;\n";
	proj.workspace.process_file("/virtual/broken_mod.c3", source);
	Uri doc_uri = uri::from_file_path(mem, "/virtual/broken_mod.c3");
	defer doc_uri.free();

	// Hover over `module` (line 0, col 3) -> Crashes with SIGSEGV on current code
	LspPosition pos = { .line = 0, .character = 3 };
	String h = hover::hover(&proj, doc_uri, pos) ?? "";
	assert(h.contains("module"));
}

fn void test_missing_symbol_in_scoped_module_does_not_resolve_globally() @test
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String mem_mod = `module mem_lib;
fn void free(void* ptr) {}
`;

	String sdl_mod = `module sdl3;
fn void* sdl_load_file(String path, int size) { return null; }
`;

	String app_code = `module app;
import mem_lib;
import sdl3;

fn void main() {
    void* file = sdl3::sdl_load_file("asd", 13);
    sdl3::free(file);
}
`;

	proj.workspace.process_file("/virtual/mem_lib.c3", mem_mod);
	proj.workspace.process_file("/virtual/sdl3.c3", sdl_mod);
	proj.workspace.process_file("/virtual/app_scope.c3", app_code);

	Uri app_uri = uri::from_file_path(mem, "/virtual/app_scope.c3");
	defer app_uri.free();

	// Cursor on `free` in `sdl3::free(file);` (line 6, character 11)
	LspPosition pos = { .line = 6, .character = 11 };

	// 1. Goto definition must return 0 locations (must not jump to mem_lib::free)
	LspLocation[] locs = definition::goto_definition(&proj, app_uri, pos)!!;
	test::eq(locs.len, 0);

	// 2. Hover must be empty (must not display signature of mem_lib::free)
	String h = hover::hover(&proj, app_uri, pos) ?? "";
	test::eq(h.len, 0);
}

fn void test_module_function_vs_method_definition()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String gfx_code = "module std::gfx;\nstruct GfxSurface {}\nfn void? init(String name) {}\nfn void? GfxSurface.init(&self, void* data) {}\n";
	String app_code = "module app;\nimport std::gfx;\nfn void main() {\n  gfx::init(\"test\");\n}\n";

	proj.workspace.process_file("/virtual/gfx.c3", gfx_code);
	proj.workspace.process_file("/virtual/app.c3", app_code);

	Uri app_uri = uri::from_file_path(mem, "/virtual/app.c3");
	defer app_uri.free();

	LspPosition init_pos = { .line = 3, .character = 8 };
	LspLocation[] locs = definition::goto_definition(&proj, app_uri, init_pos)!!;
	assert(locs.len > 0);
	test::eq((int)locs[0].range.start.line, 2);
}

fn void test_imported_submodule_short_name_definition()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String os_macos_code = "module std::os::macos;\nfn void dummy() {}\n";
	String gfx_macos_code = "module std::gfx::macos;\nfn void window_create_wgpu_surface() {}\n";
	String gfx_impl_code = "module std::gfx;\nimport std::os;\nimport std::gfx::macos;\nfn void test() {\n  macos::window_create_wgpu_surface();\n}\n";

	proj.workspace.process_file("/virtual/os_macos.c3", os_macos_code);
	proj.workspace.process_file("/virtual/gfx_macos.c3", gfx_macos_code);
	proj.workspace.process_file("/virtual/gfx_impl.c3", gfx_impl_code);

	Uri impl_uri = uri::from_file_path(mem, "/virtual/gfx_impl.c3");
	defer impl_uri.free();

	LspPosition pos = { .line = 4, .character = 15 };
	LspLocation[] locs = definition::goto_definition(&proj, impl_uri, pos)!!;
	assert(locs.len > 0);
	test::eq((int)locs[0].range.start.line, 1);
}

fn void test_multi_module_section_imports_definition()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String mod_a_sub = "module mod_a::sub;\nfn void action() {}\n";
	String mod_b_sub = "module mod_b::sub;\nfn void action() {}\n";
	String multi_file = "module client_a;\nimport mod_a::sub;\nfn void run_a() {\n  sub::action();\n}\n\nmodule client_b;\nimport mod_b::sub;\nfn void run_b() {\n  sub::action();\n}\n";

	proj.workspace.process_file("/virtual/mod_a.c3", mod_a_sub);
	proj.workspace.process_file("/virtual/mod_b.c3", mod_b_sub);
	proj.workspace.process_file("/virtual/multi.c3", multi_file);

	Uri multi_uri = uri::from_file_path(mem, "/virtual/multi.c3");
	defer multi_uri.free();

	// Line 3: sub::action() inside module client_a -> should resolve to mod_a.c3
	LspPosition pos_a = { .line = 3, .character = 8 };
	LspLocation[] locs_a = definition::goto_definition(&proj, multi_uri, pos_a)!!;
	assert(locs_a.len > 0);
	test::eq(locs_a[0].uri, "file:///virtual/mod_a.c3");

	// Line 9: sub::action() inside module client_b -> should resolve to mod_b.c3
	LspPosition pos_b = { .line = 9, .character = 8 };
	LspLocation[] locs_b = definition::goto_definition(&proj, multi_uri, pos_b)!!;
	assert(locs_b.len > 0);
	test::eq(locs_b[0].uri, "file:///virtual/mod_b.c3");
}

fn void test_qualified_fault_definition()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String faults_code = "module mod_faults;\nfaultdef INVALID_ARG, OUT_OF_BOUNDS;\n";
	String client_code = "module client;\nimport mod_faults;\nfn void test() {\n  return mod_faults::INVALID_ARG~;\n}\n";

	proj.workspace.process_file("/virtual/faults.c3", faults_code);
	proj.workspace.process_file("/virtual/client.c3", client_code);

	Uri client_uri = uri::from_file_path(mem, "/virtual/client.c3");
	defer client_uri.free();

	// Line 3: on INVALID_ARG (char 23)
	LspPosition pos = { .line = 3, .character = 23 };
	LspLocation[] locs = definition::goto_definition(&proj, client_uri, pos)!!;
	assert(locs.len > 0);
	test::eq(locs[0].uri, "file:///virtual/faults.c3");
	test::eq((int)locs[0].range.start.line, 1);
}

fn void test_module_multiple_declarations_definition()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String file1_code = "module multi_mod;\nfn void foo() {}\n";
	String file2_code = "module multi_mod;\nfn void bar() {}\n";
	String client_code = "module client;\nimport multi_mod;\nfn void test() {\n  multi_mod::foo();\n}\n";

	proj.workspace.process_file("/virtual/file1.c3", file1_code);
	proj.workspace.process_file("/virtual/file2.c3", file2_code);
	proj.workspace.process_file("/virtual/client.c3", client_code);

	Uri client_uri = uri::from_file_path(mem, "/virtual/client.c3");
	defer client_uri.free();

	// Line 3: on multi_mod (char 4)
	LspPosition pos = { .line = 3, .character = 4 };
	LspLocation[] locs = definition::goto_definition(&proj, client_uri, pos)!!;
	test::eq(locs.len, 2);
}

fn void test_global_variable_member_definition()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source_def = "module app;\nstruct Context {\n  bool use_wayland;\n}\nContext global_ctx;\n";
	String source_use = "module app;\nfn void run() {\n  if (global_ctx.use_wayland) {}\n}\n";

	proj.workspace.process_file("/virtual/def.c3", source_def);
	proj.workspace.process_file("/virtual/use.c3", source_use);

	Uri use_uri = uri::from_file_path(mem, "/virtual/use.c3");
	defer use_uri.free();

	// Line 2: on use_wayland (char 18)
	LspPosition pos = { .line = 2, .character = 18 };
	LspLocation[] locs = definition::goto_definition(&proj, use_uri, pos)!!;
	assert(locs.len > 0);
	test::eq(locs[0].uri, "file:///virtual/def.c3");
	test::eq((int)locs[0].range.start.line, 2);
}

fn void test_path_prefixed_method_hover_and_definition() @test
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = `module lala;

struct GfxSurface { int id; }

fn GfxSurface std::gfx::GfxSurface.do_something1(self) => self;
fn GfxSurface gfx::GfxSurface.do_something2(self) => self;
fn GfxSurface GfxSurface.do_something3(self) => self;

fn void main()
{
	GfxSurface mysurface;
	mysurface = mysurface.do_something1();
	mysurface = mysurface.do_something2();
	mysurface = mysurface.do_something3();
}
`;

	proj.workspace.process_file("/virtual/path_prefixed_test.c3", source);
	Uri doc_uri = uri::from_file_path(mem, "/virtual/path_prefixed_test.c3");
	defer doc_uri.free();

	LspDiagnostic[] diags = proj.workspace.get_diagnostics("/virtual/path_prefixed_test.c3");
	test::eq(diags.len, 0);

	// 1. Hover on do_something1 (line 11, col 25)
	LspPosition pos1 = { .line = 11, .character = 25 };
	String h1 = hover::hover(&proj, doc_uri, pos1)!!;
	assert(h1.contains("std::gfx::GfxSurface.do_something1"));

	// 2. Goto definition on do_something1 -> line 4
	LspLocation[] locs1 = definition::goto_definition(&proj, doc_uri, pos1)!!;
	assert(locs1.len > 0);
	test::eq((int)locs1[0].range.start.line, 4);

	// 3. Hover on do_something2 (line 12, col 25)
	LspPosition pos2 = { .line = 12, .character = 25 };
	String h2 = hover::hover(&proj, doc_uri, pos2)!!;
	assert(h2.contains("gfx::GfxSurface.do_something2"));

	// 4. Goto definition on do_something2 -> line 5
	LspLocation[] locs2 = definition::goto_definition(&proj, doc_uri, pos2)!!;
	assert(locs2.len > 0);
	test::eq((int)locs2[0].range.start.line, 5);

	// 5. Completion on `mysurface.` suggests do_something1, do_something2, do_something3
	LspPosition comp_pos = { .line = 11, .character = 23 };
	CompletionItem[] items = completion::resolve(&proj, doc_uri, comp_pos)!!;
	bool found1 = false;
	bool found2 = false;
	bool found3 = false;
	foreach (item : items)
	{
		if (item.label == "do_something1") found1 = true;
		if (item.label == "do_something2") found2 = true;
		if (item.label == "do_something3") found3 = true;
	}
	assert(found1);
	assert(found2);
	assert(found3);
}

fn void test_hover_on_builtin_len_property() @test
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = `module lala;
import std;

fn void main()
{
	io::printn("asd".len);
}
`;

	proj.workspace.process_file("/virtual/str_len_hover.c3", source);
	Uri doc_uri = uri::from_file_path(mem, "/virtual/str_len_hover.c3");
	defer doc_uri.free();

	LspPosition pos = { .line = 5, .character = 19 };
	String h = hover::hover(&proj, doc_uri, pos)!!;
	assert(h.contains("sz len"));
	assert(h.contains("Number of elements"));
}
fn void test_hover_and_definition_on_chained_declaration()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();
	proj.workspace.process_file("/virtual/chained.c3", "module t;\nfn int f()\n{\n\tint a, b;\n\tb = 1;\n\treturn b;\n}\n");
	Uri u = uri::from_file_path(tmem, "/virtual/chained.c3");

	// `int a, |b;` and `|b = 1;`.
	LspPosition[2] positions = { { 3, 8 }, { 4, 1 } };
	foreach (i, pos : positions)
	{
		String h = hover::hover(&proj, u, pos)!!;
		assert(h.contains("int b"), "hover %d: %s", i, h);
		LspLocation[] locs = definition::goto_definition(&proj, u, pos)!!;
		assert(locs.len == 1 && locs[0].range.start.line == 3 && locs[0].range.start.character == 8, "definition %d: %s", i, locs);
	}
}

fn void test_hover_on_first_argument_of_builtin()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();
	proj.workspace.process_file("/virtual/builtin_arg.c3", "module t;\nfn int g(int value) => $$popcount(value);\n");
	Uri u = uri::from_file_path(tmem, "/virtual/builtin_arg.c3");
	// `$$popcount(|value)`
	String h = hover::hover(&proj, u, { 1, 34 })!!;
	assert(h.contains("int value"), "hover: %s", h);
}

fn void test_hover_on_ct_loop_variables_in_body()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();
	String src = "module t;\nstruct Pt { int x; int y; }\nfn int f(Pt pt)\n{\n\tint s;\n\t$for var $i = 0; $i < 2; $i++:\n\t\ts += $i;\n\t$endfor\n\t$foreach $m : Pt::members:\n\t\ts += pt.$eval($m.name);\n\t$endforeach\n\treturn s;\n}\n";
	proj.workspace.process_file("/virtual/ct_loop.c3", src);
	Uri u = uri::from_file_path(tmem, "/virtual/ct_loop.c3");
	// `s += $|i;` and `$eval($|m.name)`, declared on lines 5 and 8.
	LspPosition[2] positions = { { 6, 8 }, { 9, 17 } };
	uint[2] decl_lines = { 5, 8 };
	foreach (i, pos : positions)
	{
		LspLocation[] locs = definition::goto_definition(&proj, u, pos)!!;
		assert(locs.len == 1 && locs[0].range.start.line == decl_lines[i], "definition %d: %s", i, locs);
		assert(hover::hover(&proj, u, pos)!!.len > 0, "hover %d", i);
	}
}

fn void test_hover_on_type_of_foreach_reference_variable()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();
	proj.workspace.process_file("/virtual/foreach_ref.c3", "module t;\nstruct Entry { int v; }\nfn void f(Entry*[] table)\n{\n\tforeach (Entry** &e : table) (*e).v = 1;\n}\n");
	Uri u = uri::from_file_path(tmem, "/virtual/foreach_ref.c3");
	// `foreach (E|ntry** &e`
	String h = hover::hover(&proj, u, { 4, 11 })!!;
	assert(h.contains("struct Entry"), "hover: %s", h);
	h = hover::hover(&proj, u, { 4, 19 })!!;
	assert(h.contains("Entry** e"), "hover: %s", h);
}

fn void test_hover_shows_fault_doc_comment()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();
	String src = "module t;\nfaultdef\n\t<* The pattern ends with a backslash. *>\n\tTRAILING_BACKSLASH,\n\n\t<* Unbalanced parentheses. *>\n\tUNBALANCED;\nfn void? f(int x)\n{\n\tif (x) return TRAILING_BACKSLASH~;\n\treturn UNBALANCED~;\n}\n";
	proj.workspace.process_file("/virtual/fault_doc.c3", src);
	Uri u = uri::from_file_path(tmem, "/virtual/fault_doc.c3");
	// The declaration and its uses.
	LspPosition[3] positions = { { 3, 3 }, { 9, 17 }, { 10, 10 } };
	String[3] docs = { "ends with a backslash", "ends with a backslash", "Unbalanced parentheses" };
	foreach (i, pos : positions)
	{
		String h = hover::hover(&proj, u, pos)!!;
		assert(h.contains(docs[i]), "hover %d: %s", i, h);
	}
}

fn void test_hover_and_completion_on_compiler_builtins()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();
	String src = "module t;\nfn int f(int* p)\n{\n\tint x = $$volatile_load(p);\n\treturn x + $$LINE;\n}\n";
	proj.workspace.process_file("/virtual/builtins.c3", src);
	Uri u = uri::from_file_path(tmem, "/virtual/builtins.c3");

	// `$$vol|atile_load` and `$$LI|NE`, documented in the language docs.
	String h = hover::hover(&proj, u, { 3, 14 })!!;
	assert(h.contains("$$volatile_load") && h.contains("volatile load"), "hover: %s", h);
	h = hover::hover(&proj, u, { 4, 15 })!!;
	assert(h.contains("$$LINE") && h.contains("current source line"), "hover: %s", h);

	// `$$vol|`: builtin names, not other symbols.
	bool found;
	foreach (item : completion::resolve(&proj, u, { 3, 14 })!!)
	{
		assert(item.label.starts_with("$$"), "%s", item.label);
		if (item.label == "$$volatile_load") found = true;
	}
	assert(found);
}

fn void test_hover_on_doc_contract_tags()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();
	String src = "module t;\nfaultdef TOO_BIG;\n<*\n Scales.\n @param [&in] p : \"The value\"\n @require *p < 100 : \"Small values only\"\n @ensure return >= 0\n @return \"The scaled value\"\n @return? TOO_BIG\n @pure\n @deprecated \"Use other\"\n*>\nfn int? scale(int* p) => *p * 2;\n";
	proj.workspace.process_file("/virtual/tags.c3", src);
	Uri u = uri::from_file_path(tmem, "/virtual/tags.c3");

	// The cursor on each tag; `@return?` is not `@return`.
	uint[7] lines = { 4, 5, 6, 7, 8, 9, 10 };
	String[7] wanted = { "@param", "@require", "@ensure", "@return <", "@return?", "@pure", "@deprecated" };
	foreach (i, line : lines)
	{
		String h = hover::hover(&proj, u, { line, 3 })!!;
		assert(h.contains(wanted[i]), "%s: %s", wanted[i], h);
	}
	// Outside a doc comment `@pure` is an attribute, not a tag.
	assert(!(hover::hover(&proj, u, { 12, 3 }) ?? "").contains("@pure"));
}

fn void test_hover_and_completion_on_target_constants()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();
	String src = "module t;\ntypedef JmpBuf = uptr[$$JMP_BUF_SIZE];\nfn int f() => $$C_INT_SIZE;\n";
	proj.workspace.process_file("/virtual/target_consts.c3", src);
	Uri u = uri::from_file_path(tmem, "/virtual/target_consts.c3");

	// `uptr[$$JMP|_BUF_SIZE]` in a type and `$$C_IN|T_SIZE` in an expression.
	String h = hover::hover(&proj, u, { 1, 26 })!!;
	assert(h.contains("$$JMP_BUF_SIZE") && h.contains("jmp_buf"), "hover: %s", h);
	h = hover::hover(&proj, u, { 2, 20 })!!;
	assert(h.contains("$$C_INT_SIZE") && h.contains("C `int`"), "hover: %s", h);

	bool found;
	foreach (item : completion::resolve(&proj, u, { 1, 26 })!!)
	{
		if (item.label == "$$JMP_BUF_SIZE") found = true;
	}
	assert(found);
}

fn void test_hover_shows_builtin_signature()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();
	proj.workspace.process_file("/virtual/builtin_sig.c3", "module t;\nfn int f(int[<4>] v) => $$reduce_max(v);\n");
	// `$$reduce|_max`
	String h = hover::hover(&proj, uri::from_file_path(tmem, "/virtual/builtin_sig.c3"), { 1, 32 })!!;
	assert(h.starts_with("```c3\n$$reduce_max(vec)\n```"), "hover: %s", h);
}

fn void test_hover_on_access_left_side_describes_the_left_side()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();
	proj.workspace.process_file("/virtual/access_left.c3", "module t;\nfn void main()\n{\n\tsz a = double::alignment;\n}\n");
	// `dou|ble::alignment`
	String h = hover::hover(&proj, uri::from_file_path(tmem, "/virtual/access_left.c3"), { 3, 10 })!!;
	assert(h.starts_with("```c3\ndouble\n```"), "hover: %s", h);
}

fn void test_designators_in_enum_associated_values()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();
	String src = "module app;\nbitstruct Flags : uint\n{\n\tbool is_a;\n}\nstruct Pair { int x; }\nenum Kind : int (String name, Flags flags, Pair p)\n{\n\tONE { \"one\", { .is_a = true }, { .x = 1 } },\n}\n";
	proj.workspace.process_file("/virtual/enum_desig.c3", src);
	Uri u = uri::from_file_path(tmem, "/virtual/enum_desig.c3");
	// `{ .is|_a = true }`
	String h = hover::hover(&proj, u, { 8, 18 })!!;
	assert(h.starts_with("```c3\nbool is_a\n```"), "hover: %s", h);
	LspLocation[] locs = definition::goto_definition(&proj, u, { 8, 18 })!!;
	assert(locs.len == 1 && locs[0].range.start.line == 3, "definition");
	// `{ .|x = 1 }`
	h = hover::hover(&proj, u, { 8, 35 })!!;
	assert(h.starts_with("```c3\nint x\n```"), "hover: %s", h);
}

macro void check_designator(LspProject* proj, Uri u, uint line, uint character, String expected)
{
	String h = hover::hover(proj, u, { line, character })!!;
	assert(h.starts_with(string::tformat("```c3\n%s\n```", expected)), "%d:%d hover: %s", line, character, h);
	assert(definition::goto_definition(proj, u, { line, character })!!.len == 1, "%d:%d no definition", line, character);
}

fn void test_deeply_nested_designators_in_enum_associated_values()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();
	proj.workspace.process_file("/virtual/deep_desig.c3", "module app;\nbitstruct Flags : uint\n{\n\tbool on;\n}\nstruct Leaf { Flags flags; int[2] nums; }\nstruct Mid { Leaf leaf; Leaf[2] leaves; }\nstruct Top { Mid mid; }\nenum Kind : int (String name, Top top, Mid[2] mids)\n{\n\tONE { \"one\", { .mid = { .leaf = { .flags = { .on = true } } } }, { [1] = { .leaf.flags = { .on = true } } } },\n\tTWO { \"two\", { .mid = { .leaves = { [0] = { .flags.on = true } } } }, { [0] = { .leaf = { .nums = { [1] = 3 } } }, [1] = { .leaves = { { .flags = { .on = true } }, {} } } } },\n}\n");
	Uri u = uri::from_file_path(tmem, "/virtual/deep_desig.c3");
	check_designator(&proj, u, 10, 18, "Mid mid");
	check_designator(&proj, u, 10, 27, "Leaf leaf");
	check_designator(&proj, u, 10, 37, "Flags flags");
	check_designator(&proj, u, 10, 48, "bool on");
	check_designator(&proj, u, 10, 78, "Leaf leaf");
	check_designator(&proj, u, 10, 83, "Flags flags");
	check_designator(&proj, u, 10, 94, "bool on");
	check_designator(&proj, u, 11, 18, "Mid mid");
	check_designator(&proj, u, 11, 27, "Leaf[2] leaves");
	check_designator(&proj, u, 11, 47, "Flags flags");
	check_designator(&proj, u, 11, 53, "bool on");
	check_designator(&proj, u, 11, 83, "Leaf leaf");
	check_designator(&proj, u, 11, 93, "int[2] nums");
	check_designator(&proj, u, 11, 126, "Leaf[2] leaves");
	check_designator(&proj, u, 11, 140, "Flags flags");
	check_designator(&proj, u, 11, 151, "bool on");
}

fn void test_members_of_var_locals()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();
	proj.workspace.process_file("/virtual/var_local.c3", "module app;\nstruct Entry { int node; }\nmacro void main()\n{\n\tEntry e;\n\tvar g = e;\n\tint m = g.node;\n}\n");
	// `g.no|de`
	String h = hover::hover(&proj, uri::from_file_path(tmem, "/virtual/var_local.c3"), { 6, 11 })!!;
	assert(h.starts_with("```c3\nint node\n```"), "hover: %s", h);
}

fn void test_hover_on_vector_swizzles()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();
	proj.workspace.process_file("/virtual/swizzle.c3", "module app;\nalias Point = int[<2>];\nfn void f(Point p, float[<4>] c)\n{\n\tint a = p.x;\n\tint[<2>] b = p.yx;\n\tfloat d = c.a;\n\tfloat[<3>] e = c.rgb;\n}\n");
	Uri u = uri::from_file_path(tmem, "/virtual/swizzle.c3");
	String h = hover::hover(&proj, u, { 4, 11 })!!;
	assert(h.starts_with("```c3\nint x\n```"), "x: %s", h);
	h = hover::hover(&proj, u, { 5, 17 })!!;
	assert(h.starts_with("```c3\nint[<2>] yx\n```"), "yx: %s", h);
	h = hover::hover(&proj, u, { 6, 13 })!!;
	assert(h.starts_with("```c3\nfloat a\n```"), "a: %s", h);
	h = hover::hover(&proj, u, { 7, 19 })!!;
	assert(h.starts_with("```c3\nfloat[<3>] rgb\n```"), "rgb: %s", h);
}

fn void test_hover_range_covers_builtin()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = "module b;\nfn void f()\n{\n\tint x;\n\t$$volatile_load(&x);\n}\n";
	Uri doc_uri = uri::from_file_path(mem, "/virtual/builtin_hover.c3");
	defer doc_uri.free();
	proj.workspace.process_file("/virtual/builtin_hover.c3", source);

	foreach (uint c : { 1, 2, 3, 10 })
	{
		LspRange r = hover::hover_range(&proj, doc_uri, { .line = 4, .character = c })!!;
		test::eq(r.start.line, 4u);
		test::eq(r.start.character, 1u);
		test::eq(r.end.line, 4u);
		test::eq(r.end.character, 16u);
	}
}

fn void test_hover_range_covers_vector_type_and_names()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String line = "macro bool[<*>] ulong[<*>].cmp_lt(ulong[<*>] x, ulong[<*>] y) => $$veccomplt(x, y);";
	String source = string::tformat("module v;\n%s\n", line);
	Uri doc_uri = uri::from_file_path(mem, "/virtual/vector_hover.c3");
	defer doc_uri.free();
	proj.workspace.process_file("/virtual/vector_hover.c3", source);

	foreach (uint[3] c : (uint[3][]){ { 11, 6, 15 }, { 22, 16, 26 }, { 28, 27, 33 }, { 45, 45, 46 }, { 0, 0, 5 }, { 70, 65, 76 } })
	{
		LspRange r = hover::hover_range(&proj, doc_uri, { .line = 1, .character = c[0] })!!;
		test::eq(line[r.start.character..r.end.character - 1], line[c[1]..c[2] - 1]);
	}
}

struct SuffixHoverCase
{
	uint line;
	uint character;
	String text;
	String range;
}

fn void test_hover_on_type_suffix_describes_whole_type()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String[] lines = { "\tulong[<4>] a;", "\tint[] b;", "\tchar[4] c;", "\tvoid* d;", "\tint? e;", "\tint[]? g;", "\tint*[] h;" };
	String source = string::tformat("module v;\nfn void f()\n{\n%s\n}\n", string::tjoin(lines, "\n"));
	Uri doc_uri = uri::from_file_path(mem, "/virtual/type_suffix.c3");
	defer doc_uri.free();
	proj.workspace.process_file("/virtual/type_suffix.c3", source);

	SuffixHoverCase[] cases = {
		{ 0, 6, "```c3\nulong[<4>]\n```\n\nVector of `ulong`.", "ulong[<4>]" },
		{ 0, 7, "```c3\nulong[<4>]\n```\n\nVector of `ulong`.", "ulong[<4>]" },
		{ 0, 10, "```c3\nulong[<4>]\n```\n\nVector of `ulong`.", "ulong[<4>]" },
		{ 1, 4, "```c3\nint[]\n```\n\nSlice of `int`.", "int[]" },
		{ 1, 5, "```c3\nint[]\n```\n\nSlice of `int`.", "int[]" },
		{ 2, 5, "```c3\nchar[4]\n```\n\nArray of `char`.", "char[4]" },
		{ 3, 5, "```c3\nvoid*\n```\n\nPointer to `void`.", "void*" },
		{ 4, 4, "```c3\nint?\n```\n\nOptional `int`.", "int?" },
		{ 5, 4, "```c3\nint[]\n```\n\nSlice of `int`.", "int[]?" },
		{ 5, 6, "```c3\nint[]?\n```\n\nOptional `int[]`.", "int[]?" },
		{ 6, 4, "```c3\nint*\n```\n\nPointer to `int`.", "int*" },
		{ 6, 5, "```c3\nint*[]\n```\n\nSlice of `int*`.", "int*[]" },
	};
	foreach (c : cases)
	{
		LspPosition pos = { .line = c.line + 3, .character = c.character };
		test::eq(hover::hover(&proj, doc_uri, pos)!!, c.text);
		LspRange r = hover::hover_range(&proj, doc_uri, pos)!!;
		test::eq(lines[c.line][r.start.character..r.end.character - 1], c.range);
	}
	assert(hover::hover(&proj, doc_uri, { .line = 3, .character = 2 })!!.starts_with("```c3\nulong\n```"));
	LspRange base = hover::hover_range(&proj, doc_uri, { .line = 3, .character = 2 })!!;
	test::eq(lines[0][base.start.character..base.end.character - 1], "ulong");
}

fn void test_definition_of_receiver_generic_param()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	proj.workspace.process_file("/virtual/slice2d.c3", "module std::core::array;\nstruct Slice2d <Type>\n{\n\tType* ptr;\n}\n");
	proj.workspace.process_file("/virtual/atomic.c3", "module std::atomic::types;\nstruct Atomic <Type>\n{\n\tType data;\n}\nmacro Type Atomic.load(&self)\n{\n\treturn self.data;\n}\n");
	Uri doc_uri = uri::from_file_path(mem, "/virtual/atomic.c3");
	defer doc_uri.free();

	LspLocation[] locs = definition::goto_definition(&proj, doc_uri, { .line = 5, .character = 7 })!!;
	test::eq(locs.len, 1);
	assert(locs[0].uri.ends_with("atomic.c3"), "%s", locs[0].uri);
	test::eq(locs[0].range.start.line, 1u);
	test::eq(locs[0].range.start.character, 15u);
}

fn void test_hover_on_import_attributes()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	proj.workspace.process_file("/virtual/lib.c3", "module lib;\nfn void f() {}\n");
	proj.workspace.process_file("/virtual/imp.c3", "module app;\nimport lib @norecurse @public;\n");
	Uri doc_uri = uri::from_file_path(mem, "/virtual/imp.c3");
	defer doc_uri.free();

	String norecurse = hover::hover(&proj, doc_uri, { .line = 1, .character = 13 })!!;
	assert(norecurse.contains("without recursively importing its submodules"), "%s", norecurse);
	LspRange r = hover::hover_range(&proj, doc_uri, { .line = 1, .character = 13 })!!;
	test::eq(r.start.character, 11u);
	test::eq(r.end.character, 21u);
	String public = hover::hover(&proj, doc_uri, { .line = 1, .character = 24 })!!;
	assert(public.contains("`@private`"), "%s", public);
}
