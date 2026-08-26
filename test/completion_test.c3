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
	// 2. Completion on `this.` (arbitrary receiver parameter name)
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
