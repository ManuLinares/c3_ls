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
