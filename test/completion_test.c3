module lsp::completion_test @test;

import lsp::core;
import lsp::analysis::completion;
import lsp;
import uri;
import std::io;

fn void test_keyword_and_global_completion()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = "module my_test;\nfn void my_cool_function() {}\nfn void main() {\n  my_\n}\n";
	Uri doc_uri = uri::from_file_path(mem, "/virtual/comp_test.c3");
	defer doc_uri.free();

	proj.workspace.process_file("/virtual/comp_test.c3", source);

	LspPosition pos = {.line = 3,.character = 5 };
	CompletionItem[] items = completion::resolve(&proj, doc_uri, pos)!!;

	assert(items.len > 0);
	bool found_fn = false;
	foreach (item : items)
	{
		if (item.label == "my_cool_function") found_fn = true;
	}
	assert(found_fn);
}

fn void test_member_completion()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = "module my_test;\nstruct Point { int x; int y; }\nfn void main() {\n  Point p;\n  Point.\n}\n";
	Uri doc_uri = uri::from_file_path(mem, "/virtual/comp_member.c3");
	defer doc_uri.free();

	proj.workspace.process_file("/virtual/comp_member.c3", source);

	LspPosition pos = {.line = 4,.character = 8 };
	CompletionItem[] items = completion::resolve(&proj, doc_uri, pos)!!;

	assert(items.len > 0);
	bool found_x = false;
	bool found_y = false;
	foreach (item : items)
	{
		if (item.label == "x") found_x = true;
		if (item.label == "y") found_y = true;
	}
	assert(found_x);
	assert(found_y);
}

fn void test_self_member_completion_in_method()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = "module vec_app;\nstruct Vector2 {\n  float x;\n  float y;\n}\nfn void Vector2.scale(&self, float factor) {\n  self.\n}\nfn void Vector2.translate(&this, float dx, float dy) {\n  this.\n}\n";
	Uri doc_uri = uri::from_file_path(mem, "/virtual/comp_self.c3");
	defer doc_uri.free();

	proj.workspace.process_file("/virtual/comp_self.c3", source);
	// 1. Completion on `self.`
	LspPosition pos1 = {.line = 6,.character = 7 };
	CompletionItem[] items1 = completion::resolve(&proj, doc_uri, pos1)!!;

	assert(items1.len >= 2);
	bool found_x1 = false;
	bool found_y1 = false;
	foreach (item : items1)
	{
		if (item.label == "x") found_x1 = true;
		if (item.label == "y") found_y1 = true;
	}
	assert(found_x1);
	assert(found_y1);
	// 2. Completion on `this.`
	LspPosition pos2 = {.line = 9,.character = 7 };
	CompletionItem[] items2 = completion::resolve(&proj, doc_uri, pos2)!!;

	assert(items2.len >= 2);
	bool found_x2 = false;
	bool found_y2 = false;
	foreach (item : items2)
	{
		if (item.label == "x") found_x2 = true;
		if (item.label == "y") found_y2 = true;
	}
	assert(found_x2);
	assert(found_y2);
}

fn void test_static_and_instance_reflection_separation()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = `module app;
enum Status { IDLE, ACTIVE }
fn void run() {
  Status s;
  s.
  Status::
}
`;

	Uri doc_uri = uri::from_file_path(mem, "/virtual/comp_refl.c3");
	defer doc_uri.free();

	proj.workspace.process_file("/virtual/comp_refl.c3", source);
	// 1. Dot access on instance `s.` (line 4, col 4) -> must NOT include reflection properties
	LspPosition dot_pos = {.line = 4,.character = 4 };
	CompletionItem[] dot_items = completion::resolve(&proj, doc_uri, dot_pos)!!;
	foreach (item : dot_items)
	{
		assert(item.label != "alignment" && item.label != "typeid");
	}
	// 2. Static access on `Status::` (line 5, col 10) -> must include properties with valid docs
	LspPosition static_pos = {.line = 5,.character = 10 };
	CompletionItem[] static_items = completion::resolve(&proj, doc_uri, static_pos)!!;
	bool found_size = false;
	foreach (item : static_items)
	{
		if (item.label == "size")
		{
			found_size = true;
			assert(item.documentation.kind == MARKDOWN);
			assert(item.documentation.value.len > 0);
		}
	}
	assert(found_size);
}

fn void test_import_completion_and_submodules()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String lib_io = "<*\n Standard I/O module\n*>\nmodule std::io;\nfn void print(String s) {}\n";
	String lib_math = "<*\n Math functions\n*>\nmodule std::math;\nfn double sin(double x) { return 0.0; }\n";
	String app_code = "module app;\nimport \nimport std:\nimport std::\n";

	proj.workspace.process_file("/virtual/lib_io.c3", lib_io);
	proj.workspace.process_file("/virtual/lib_math.c3", lib_math);
	proj.workspace.process_file("/virtual/app_import.c3", app_code);

	Uri app_uri = uri::from_file_path(mem, "/virtual/app_import.c3");
	defer app_uri.free();
	// 1. Completion on `import ` (line 1, col 7) -> lists modules and has doc contracts
	LspPosition pos1 = {.line = 1,.character = 7 };
	CompletionItem[] items1 = completion::resolve(&proj, app_uri, pos1)!!;
	bool found_std_io = false;
	foreach (item : items1)
	{
		if (item.label == "std::io")
		{
			found_std_io = true;
			assert(item.documentation.value.contains("Standard I/O module"));
		}
	}
	assert(found_std_io);
	// 2. Completion on `import std:` (line 2, col 11) -> suggests `:io` and `:math`
	LspPosition pos2 = {.line = 2,.character = 11 };
	CompletionItem[] items2 = completion::resolve(&proj, app_uri, pos2)!!;
	bool found_colon_io = false;
	foreach (item : items2)
	{
		if (item.label == "io")
		{
			found_colon_io = true;
			assert(item.insertText == ":io");
		}
	}
	assert(found_colon_io);
	// 3. Completion on `import std::` (line 3, col 12) -> suggests `io` and `math`
	LspPosition pos3 = {.line = 3,.character = 12 };
	CompletionItem[] items3 = completion::resolve(&proj, app_uri, pos3)!!;
	bool found_io = false;
	bool found_math = false;
	foreach (item : items3)
	{
		if (item.label == "io")
		{
			found_io = true;
			assert(item.insertText == "io");
		}
		if (item.label == "math") found_math = true;
	}
	assert(found_io);
	assert(found_math);
}

fn void test_module_visibility_and_fault_ranking()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String regex_mod = `module regex;
faultdef SYNTAX_ERROR, NO_MATCH;
fn void compile(String pat) {}
fn void internal_helper() @private {}
`;
	String app1_code = `module app1;
import regex;
fn void run() {
  fault a = regex::
}
`;
	String app2_code = `module app2;
import regex @public;
fn void run() {
  regex::
}
`;

	proj.workspace.process_file("/virtual/regex.c3", regex_mod);
	proj.workspace.process_file("/virtual/app1.c3", app1_code);
	proj.workspace.process_file("/virtual/app2.c3", app2_code);

	Uri app1_uri = uri::from_file_path(mem, "/virtual/app1.c3");
	defer app1_uri.free();
	Uri app2_uri = uri::from_file_path(mem, "/virtual/app2.c3");
	defer app2_uri.free();
	// 1. Normal import on `fault a = regex::` (line 3, col 19)
	LspPosition pos1 = {.line = 3,.character = 19 };
	CompletionItem[] items1 = completion::resolve(&proj, app1_uri, pos1)!!;

	bool found_syntax_error = false;
	bool found_private_in_app1 = false;
	foreach (item : items1)
	{
		if (item.label == "SYNTAX_ERROR")
		{
			found_syntax_error = true;
			assert(item.sortText.starts_with("0001_"));
		}
		if (item.label == "internal_helper") found_private_in_app1 = true;
	}
	assert(found_syntax_error);
	assert(!found_private_in_app1);
	// 2. `@public` import on `regex::` in app2 (line 3, col 9)
	LspPosition pos2 = {.line = 3,.character = 9 };
	CompletionItem[] items2 = completion::resolve(&proj, app2_uri, pos2)!!;
	bool found_private_in_app2 = false;
	foreach (item : items2)
	{
		if (item.label == "internal_helper") found_private_in_app2 = true;
	}
	assert(found_private_in_app2);
}

fn void test_enum_and_variant_doc_comments()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = `<* Event actions documentation *>
enum SdlEventAction
{
	<* Add events to the back of the queue. *>
	ADDEVENT,
	PEEKEVENT,
}

fn void test_fn() {
	SdlEventAction a;
	a.
}
`;

	proj.workspace.process_file("/virtual/enum_docs.c3", source);
	Uri doc_uri = uri::from_file_path(mem, "/virtual/enum_docs.c3");
	defer doc_uri.free();
	// 1. Completion on `a.` (line 10, char 3)
	LspPosition pos = {.line = 10,.character = 3 };
	CompletionItem[] items = completion::resolve(&proj, doc_uri, pos)!!;

	CompletionItem addevent_item;
	bool found_addevent = false;
	foreach (item : items)
	{
		if (item.label == "ADDEVENT")
		{
			addevent_item = item;
			found_addevent = true;
			break;
		}
	}
	assert(found_addevent);
	// 2. Resolve ADDEVENT item documentation
	completion::resolve_item(&proj, &addevent_item);
	assert(addevent_item.documentation.value.contains("Add events to the back of the queue."));
	// 3. Hover on `enum SdlEventAction` (line 1, col 6)
	LspPosition enum_pos = {.line = 1,.character = 6 };
	String h = hover::hover(&proj, doc_uri, enum_pos)!!;
	assert(h.contains("Event actions documentation"));
}

fn void test_multiline_copyright_comment_completion_suppression()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = `module std::math::nolibc @feat(NO_LIBC, C3_MATH);

/* origin: FreeBSD /usr/src/lib/msun/src/k_cosf.c */
/*
 * Conversion to float by Ian Lance Taylor, Cygnus Support, ian@cygnus.com.
 * Debugged and optimized by Bruce D. Evans.
 */
/*
 * ====================================================
 * Copyright (C) 1993 by Sun Microsystems, Inc. All rights reserved.
 *
 * Developed at SunPro, a Sun Microsystems, Inc. business.
 * Permission to use, copy, modify, and distribute this
 * software is freely granted, provided that this notice
 * is preserved.
 * ====================================================
 */
/* |cos(x) - c(x)| < 2**-34.1 (~[-5.37e-11, 5.295e-11]). */

const double C0 @private = -0x1ffffffd0c5e81.0p-54;
`;

	proj.workspace.process_file("/virtual/math_comment.c3", source);
	Uri doc_uri = uri::from_file_path(mem, "/virtual/math_comment.c3");
	defer doc_uri.free();
	// Line 14: ` * Permission to use, copy, modify, and distribute this` (char 55)
	LspPosition pos = {.line = 14,.character = 55 };
	CompletionItem[] items = completion::resolve(&proj, doc_uri, pos)!!;

	assert(items.len == 0);
}

fn void test_scoped_module_completion_resolve_disambiguation() @test
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String m1_code = "module m1;\nfn void log() {}\n";
	String m2_code = "module m2;\nfn void log() {}\n";
	String m3_code = "module m3;\nfn void log() {}\n";
	String m4_code = "module m4;\nfn void log() {}\n";
	String m5_code = "module m5;\nfn void log() {}\n";
	String sdl_mod = "module sdl3;\nfn void log(char* fmt, ...) {}\n";
	String app_code = "module app;\nimport sdl3;\nfn void main() {\n  sdl3::log\n}\n";

	proj.workspace.process_file("/virtual/m1.c3", m1_code);
	proj.workspace.process_file("/virtual/m2.c3", m2_code);
	proj.workspace.process_file("/virtual/m3.c3", m3_code);
	proj.workspace.process_file("/virtual/m4.c3", m4_code);
	proj.workspace.process_file("/virtual/m5.c3", m5_code);
	proj.workspace.process_file("/virtual/sdl3.c3", sdl_mod);
	proj.workspace.process_file("/virtual/app.c3", app_code);

	Uri app_uri = uri::from_file_path(mem, "/virtual/app.c3");
	defer app_uri.free();

	LspPosition pos = { .line = 3, .character = 11 };
	CompletionItem[] items = completion::resolve(&proj, app_uri, pos)!!;

	CompletionItem log_item;
	bool found_log = false;
	foreach (item : items)
	{
		if (item.label == "log")
		{
			log_item = item;
			found_log = true;
			break;
		}
	}
	assert(found_log);
	assert(log_item.detail == "fn via sdl3");

	completion::resolve_item(&proj, &log_item);
	assert(log_item.documentation.value.contains("char* fmt"));
}

fn void test_primitive_type_method_completion() @test
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = `module app;
fn float float.do_something(&self) => 25.7;
fn bool char.is_special(self) => self == '!';

fn void test_float() {
  float lala;
  lala.
}

fn void test_char() {
  char c = 'a';
  c.
}
`;

	proj.workspace.process_file("/virtual/prim_methods.c3", source);
	Uri doc_uri = uri::from_file_path(mem, "/virtual/prim_methods.c3");
	defer doc_uri.free();

	// 1. Completion on `lala.` (line 6, character 7)
	LspPosition float_pos = { .line = 6, .character = 7 };
	CompletionItem[] float_items = completion::resolve(&proj, doc_uri, float_pos)!!;
	bool found_do_something = false;
	foreach (item : float_items)
	{
		if (item.label == "do_something") found_do_something = true;
	}
	assert(found_do_something);

	// 2. Completion on `c.` (line 11, character 4)
	LspPosition char_pos = { .line = 11, .character = 4 };
	CompletionItem[] char_items = completion::resolve(&proj, doc_uri, char_pos)!!;
	bool found_is_special = false;
	foreach (item : char_items)
	{
		if (item.label == "is_special") found_is_special = true;
	}
	assert(found_is_special);
}

fn void test_vector_type_method_completion() @test
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = `module app;
fn float float[<3>].custom_norm(self) => 1.0f;

fn void test() {
  float[<3>] vec;
  vec.
}
`;

	proj.workspace.process_file("/virtual/vec_methods.c3", source);
	Uri doc_uri = uri::from_file_path(mem, "/virtual/vec_methods.c3");
	defer doc_uri.free();

	LspPosition pos = { .line = 5, .character = 6 };
	CompletionItem[] items = completion::resolve(&proj, doc_uri, pos)!!;

	bool found_swizzle = false;
	bool found_custom_norm = false;
	foreach (item : items)
	{
		if (item.label == "xyz") found_swizzle = true;
		if (item.label == "custom_norm") found_custom_norm = true;
	}
	assert(found_swizzle);
	assert(found_custom_norm);
}

fn void test_literal_dot_completion() @test
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = `module app;
fn bool String.custom_check(String self) => true;

fn void test() {
  "hello world".
}
`;

	proj.workspace.process_file("/virtual/str_lit.c3", source);
	Uri doc_uri = uri::from_file_path(mem, "/virtual/str_lit.c3");
	defer doc_uri.free();

	LspPosition pos = { .line = 4, .character = 16 };
	CompletionItem[] items = completion::resolve(&proj, doc_uri, pos)!!;

	bool found_custom_check = false;
	foreach (item : items)
	{
		if (item.label == "custom_check") found_custom_check = true;
	}
	assert(found_custom_check);
}

fn void test_string_literal_with_interior_dots_completion() @test
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = `module app;
fn bool String.custom_validator(String self) => true;

fn void test() {
  "asd.".
  "file.name.with.many.dots.tar.gz".
}
`;

	proj.workspace.process_file("/virtual/str_dots.c3", source);
	Uri doc_uri = uri::from_file_path(mem, "/virtual/str_dots.c3");
	defer doc_uri.free();

	// 1. Completion on `"asd.".` (line 4, character 9)
	LspPosition pos1 = { .line = 4, .character = 9 };
	CompletionItem[] items1 = completion::resolve(&proj, doc_uri, pos1)!!;
	bool found1 = false;
	foreach (item : items1)
	{
		if (item.label == "custom_validator") found1 = true;
	}
	assert(found1);

	// 2. Completion on `"file.name.with.many.dots.tar.gz".` (line 5, character 36)
	LspPosition pos2 = { .line = 5, .character = 36 };
	CompletionItem[] items2 = completion::resolve(&proj, doc_uri, pos2)!!;
	bool found2 = false;
	foreach (item : items2)
	{
		if (item.label == "custom_validator") found2 = true;
	}
	assert(found2);
}

fn void test_pointer_and_numeric_literal_dot_completion() @test
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = `module app;
struct Point { int x; int y; }
fn void Point.reset(&self) { self.x = 0; self.y = 0; }
fn double double.custom_double_func(self) => self * 2.0;

fn void test_ptr() {
  Point pt;
  Point* p = &pt;
  p.
}

fn void test_num() {
  (3.14).
}
`;

	proj.workspace.process_file("/virtual/ptr_and_num.c3", source);
	Uri doc_uri = uri::from_file_path(mem, "/virtual/ptr_and_num.c3");
	defer doc_uri.free();

	// 1. Completion on pointer `p.` (line 8, character 4)
	LspPosition ptr_pos = { .line = 8, .character = 4 };
	CompletionItem[] ptr_items = completion::resolve(&proj, doc_uri, ptr_pos)!!;
	bool found_x = false;
	bool found_reset = false;
	foreach (item : ptr_items)
	{
		if (item.label == "x") found_x = true;
		if (item.label == "reset") found_reset = true;
	}
	assert(found_x);
	assert(found_reset);

	// 2. Completion on `(3.14).` (line 12, character 9)
	LspPosition num_pos = { .line = 12, .character = 9 };
	CompletionItem[] num_items = completion::resolve(&proj, doc_uri, num_pos)!!;
	bool found_dbl = false;
	foreach (item : num_items)
	{
		if (item.label == "custom_double_func") found_dbl = true;
	}
	assert(found_dbl);
}

fn void test_multiline_dot_completion() @test
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = `module app;
fn void test() {
  String text = "hello";
  text
    .
}
`;

	proj.workspace.process_file("/virtual/multiline_dot.c3", source);
	Uri doc_uri = uri::from_file_path(mem, "/virtual/multiline_dot.c3");
	defer doc_uri.free();

	LspPosition pos = { .line = 4, .character = 5 };
	CompletionItem[] items = completion::resolve(&proj, doc_uri, pos)!!;

	bool found_len = false;
	foreach (item : items)
	{
		if (item.label == "len") found_len = true;
		assert(item.label != "while" && item.label != "import");
	}
	assert(found_len);
}

fn void test_multiline_string_chain_completion() @test
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = `module demo;
fn String String.trim(String self) => self;
fn String String.strip_prefix(String self, String p) => self;
fn String String.treplace(String self, String from, String to) => self;
fn bool String.starts_with(String self, String p) => true;

fn void demo() {
    String text = "   Hello World from C3!   ";
    sz result = text
        .trim()
        .strip_prefix("Hello")
        .treplace("World", "C3!")
        .
}
`;

	proj.workspace.process_file("/virtual/multiline_chain.c3", source);
	Uri doc_uri = uri::from_file_path(mem, "/virtual/multiline_chain.c3");
	defer doc_uri.free();

	LspPosition pos = { .line = 12, .character = 9 };
	CompletionItem[] items = completion::resolve(&proj, doc_uri, pos)!!;

	bool found_len = false;
	bool found_starts_with = false;
	foreach (item : items)
	{
		if (item.label == "len") found_len = true;
		if (item.label == "starts_with") found_starts_with = true;
	}

	assert(found_len);
	assert(found_starts_with);
}

fn void test_designated_initializer_field_completion() @test
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = `module app;

struct CgltfFileOptions {
    int json_token_count;
    int memory;
}

struct CgltfOptions {
    CgltfFileOptions file;
    int type;
}

fn void test() {
    CgltfOptions options = { . };
    CgltfOptions options2 = {
        .file = {
            .
        }
    };
    (CgltfFileOptions){ . };
    (CgltfFileOptions[1])({ { . } });
}
`;

	proj.workspace.process_file("/virtual/des_comp.c3", source);
	Uri doc_uri = uri::from_file_path(mem, "/virtual/des_comp.c3");
	defer doc_uri.free();

	// 1. Direct designated initializer `CgltfOptions options = { . }` (line 13, char 30)
	LspPosition pos1 = { .line = 13, .character = 30 };
	CompletionItem[] items1 = completion::resolve(&proj, doc_uri, pos1)!!;
	bool found_file1 = false;
	bool found_type1 = false;
	foreach (item : items1)
	{
		if (item.label == "file") found_file1 = true;
		if (item.label == "type") found_type1 = true;
	}
	assert(found_file1);
	assert(found_type1);

	// 2. Nested designated initializer `.file = { . }` (line 16, char 13)
	LspPosition pos2 = { .line = 16, .character = 13 };
	CompletionItem[] items2 = completion::resolve(&proj, doc_uri, pos2)!!;
	bool found_json = false;
	bool found_mem = false;
	foreach (item : items2)
	{
		if (item.label == "json_token_count") found_json = true;
		if (item.label == "memory") found_mem = true;
	}
	assert(found_json);
	assert(found_mem);

	// 3. Compound literal `(CgltfFileOptions){ . }` (line 19, char 25)
	LspPosition pos3 = { .line = 19, .character = 25 };
	CompletionItem[] items3 = completion::resolve(&proj, doc_uri, pos3)!!;
	bool found_json3 = false;
	foreach (item : items3)
	{
		if (item.label == "json_token_count") found_json3 = true;
	}
	assert(found_json3);

	// 4. Array compound literal `(CgltfFileOptions[1])({ { . } })` (line 20, char 31)
	LspPosition pos4 = { .line = 20, .character = 31 };
	CompletionItem[] items4 = completion::resolve(&proj, doc_uri, pos4)!!;
	bool found_json4 = false;
	foreach (item : items4)
	{
		if (item.label == "json_token_count") found_json4 = true;
	}
	assert(found_json4);
}

fn void test_enum_completion_on_member_assignment_rhs() @test
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = `module app;

enum SdlGPUStoreOp {
    DONT_CARE,
    RESOLVE,
    STORE,
}

struct SdlGPUColorTargetInfo {
    SdlGPUStoreOp store_op;
}

fn void test() {
    SdlGPUColorTargetInfo info;
    info.store_op = 
}
`;

	proj.workspace.process_file("/virtual/enum_assign.c3", source);
	Uri doc_uri = uri::from_file_path(mem, "/virtual/enum_assign.c3");
	defer doc_uri.free();

	// Cursor at `info.store_op = ` (line 14, char 20)
	LspPosition pos = { .line = 14, .character = 20 };
	CompletionItem[] items = completion::resolve(&proj, doc_uri, pos)!!;

	bool found_dont_care = false;
	bool found_resolve = false;
	bool found_store = false;
	foreach (item : items)
	{
		if (item.label == "DONT_CARE")
		{
			found_dont_care = true;
			assert(item.sortText == "0000_DONT_CARE");
		}
		if (item.label == "RESOLVE") found_resolve = true;
		if (item.label == "STORE") found_store = true;
	}
	assert(found_dont_care);
	assert(found_resolve);
	assert(found_store);
}

fn void test_designated_initializer_return_and_alloc_edge_cases() @test
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = `module app;

struct FileOpts {
    int max_tokens;
    bool debug_mode;
}

struct Base {
    int base_id;
}

struct Derived {
    inline Base base;
    String name;
}

fn FileOpts get_options() {
    return { . };
}

fn void test() {
    FileOpts* opts = mem::new(FileOpts, { . });
    Derived d = { . };
}
`;

	proj.workspace.process_file("/virtual/edge_comp.c3", source);
	Uri doc_uri = uri::from_file_path(mem, "/virtual/edge_comp.c3");
	defer doc_uri.free();

	// 1. Return statement designated initializer `return { . }` (line 17, char 14)
	LspPosition pos1 = { .line = 17, .character = 14 };
	CompletionItem[] items1 = completion::resolve(&proj, doc_uri, pos1)!!;
	bool found_max_tokens1 = false;
	foreach (item : items1)
	{
		if (item.label == "max_tokens") found_max_tokens1 = true;
	}
	assert(found_max_tokens1);

	// 2. mem::new designated initializer `mem::new(FileOpts, { . })` (line 21, char 43)
	LspPosition pos2 = { .line = 21, .character = 43 };
	CompletionItem[] items2 = completion::resolve(&proj, doc_uri, pos2)!!;
	bool found_debug_mode2 = false;
	foreach (item : items2)
	{
		if (item.label == "debug_mode") found_debug_mode2 = true;
	}
	assert(found_debug_mode2);

	// 3. Inline substruct field in designated initializer `Derived d = { . }` (line 22, char 19)
	LspPosition pos3 = { .line = 22, .character = 19 };
	CompletionItem[] items3 = completion::resolve(&proj, doc_uri, pos3)!!;
	bool found_base_id3 = false;
	bool found_name3 = false;
	foreach (item : items3)
	{
		if (item.label == "base_id") found_base_id3 = true;
		if (item.label == "name") found_name3 = true;
	}
	assert(found_base_id3);
	assert(found_name3);
}

fn void test_designated_initializer_call_argument_completion() @test
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = `module app;

struct ServerConfig {
    int port;
    String host;
    bool enable_tls;
}

struct Client {
    int id;
}

fn void configure_server(ServerConfig cfg, int timeout) {}
fn void Client.connect(&self, ServerConfig cfg) {}

fn void test() {
    configure_server({ . }, 30);

    Client client;
    client.connect({ . });
}
`;

	proj.workspace.process_file("/virtual/call_des_comp.c3", source);
	Uri doc_uri = uri::from_file_path(mem, "/virtual/call_des_comp.c3");
	defer doc_uri.free();

	// 1. Function call argument `configure_server({ . }, 30)` -> cursor after `.` at character 24
	LspPosition pos1 = { .line = 16, .character = 24 };
	CompletionItem[] items1 = completion::resolve(&proj, doc_uri, pos1)!!;
	bool found_port1 = false;
	bool found_host1 = false;
	bool found_tls1 = false;
	foreach (item : items1)
	{
		if (item.label == "port") found_port1 = true;
		if (item.label == "host") found_host1 = true;
		if (item.label == "enable_tls") found_tls1 = true;
	}
	assert(found_port1);
	assert(found_host1);
	assert(found_tls1);

	// 2. Method call argument `client.connect({ . })` -> cursor after `.` at character 22
	LspPosition pos2 = { .line = 19, .character = 22 };
	CompletionItem[] items2 = completion::resolve(&proj, doc_uri, pos2)!!;
	bool found_port2 = false;
	bool found_host2 = false;
	bool found_tls2 = false;
	foreach (item : items2)
	{
		if (item.label == "port") found_port2 = true;
		if (item.label == "host") found_host2 = true;
		if (item.label == "enable_tls") found_tls2 = true;
	}
	assert(found_port2);
	assert(found_host2);
	assert(found_tls2);
}