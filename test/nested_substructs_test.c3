module lsp::nested_substructs_test @test;

import lsp::core;
import lsp::analysis::hover;
import lsp::analysis::goto_definition;
import lsp::analysis::completion;
import lsp;
import uri;
import std::io;

fn void test_nested_substruct_access_and_completion()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = `module app;

struct Engine {
  int horsepower;
  float displacement;
}

struct Car {
  String model;
  Engine engine;
}

fn void main() {
  Car my_car;
  int hp = my_car.engine.horsepower;
}
`;

	proj.workspace.process_file("/virtual/substructs.c3", source);
	Uri doc_uri = uri::from_file_path(mem, "/virtual/substructs.c3");
	defer doc_uri.free();
	// 1. Hover on `horsepower` at multi-level access `my_car.engine.horsepower` (line 14, col 27)
	LspPosition hp_pos = {.line = 14,.character = 27 };
	String hp_hover = hover::hover(&proj, doc_uri, hp_pos)!!;
	assert(hp_hover.contains("horsepower"));
	assert(hp_hover.contains("int"));
	// 2. Goto definition on `horsepower` -> jumps to `horsepower` in `struct Engine` (line 3)
	LspLocation[] locs = goto_definition::goto_definition(&proj, doc_uri, hp_pos)!!;
	assert(locs.len > 0);
	assert(locs[0].range.start.line == 3);
	// 3. Hover on `engine` in `my_car.engine` (line 14, col 20)
	LspPosition eng_pos = {.line = 14,.character = 20 };
	String eng_hover = hover::hover(&proj, doc_uri, eng_pos)!!;
	assert(eng_hover.contains("Engine"));
	// 4. Completion on `my_car.engine.` (line 14, col 25) -> suggests `horsepower` and `displacement`
	LspPosition comp_pos = {.line = 14,.character = 25 };
	CompletionItem[] items = completion::resolve(&proj, doc_uri, comp_pos)!!;
	assert(items.len >= 2);
	bool found_hp = false;
	bool found_disp = false;
	foreach (item : items)
	{
		if (item.label == "horsepower") found_hp = true;
		if (item.label == "displacement") found_disp = true;
	}
	assert(found_hp);
	assert(found_disp);
}

fn void test_anonymous_nested_union_field_hover_and_definition()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = `module app;

struct Whirlpool {
  ulong[8] hash;
  union {
    char[64] block;
    int128[4] block_128;
  }
  uint128 counter_high;
  uint128 counter_low;
}

fn void run() {
  Whirlpool w;
  w.block_128[0] = 0;
  ulong* hash_ref = (ulong*)&w.hash;
  ulong first = hash_ref[0];
}
`;

	proj.workspace.process_file("/virtual/anon_union.c3", source);
	Uri doc_uri = uri::from_file_path(mem, "/virtual/anon_union.c3");
	defer doc_uri.free();
	// 1. Hover on `w.block_128` inside anonymous union (line 14, col 6)
	LspPosition b128_pos = {.line = 14,.character = 6 };
	String b128_hover = hover::hover(&proj, doc_uri, b128_pos)!!;
	assert(b128_hover.contains("block_128"));
	assert(b128_hover.contains("int128[4]"));
	// 2. Go to definition on `w.block_128` -> jumps to `int128[4] block_128` on line 6
	LspLocation[] locs = goto_definition::goto_definition(&proj, doc_uri, b128_pos)!!;
	assert(locs.len > 0);
	assert(locs[0].range.start.line == 6);
	// 3. Hover on `hash_ref` (line 15, col 9) -> shows `ulong* hash_ref`
	LspPosition hash_ref_pos = {.line = 15,.character = 9 };
	String href_hover = hover::hover(&proj, doc_uri, hash_ref_pos)!!;
	assert(href_hover.contains("ulong* hash_ref"));
	// 4. Go to definition on `hash_ref` in `hash_ref[0]` (line 16, col 18)
	LspPosition href_idx_pos = {.line = 16,.character = 18 };
	LspLocation[] href_locs = goto_definition::goto_definition(&proj, doc_uri, href_idx_pos)!!;
	assert(href_locs.len > 0);
	assert(href_locs[0].range.start.line == 15);
}

fn void test_nested_union_with_doc_comment_above()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = `module app;

struct EcsQueryIter { int q; }
struct EcsPageIter { int p; }
struct EcsWorkerIter { int w; }
struct EcsEachIter { int e; }

struct EcsIter {
	<*
	 Private iterator data used by iterator implementations to keep track of
	 progress.
	*>
	union {
		EcsQueryIter query;
		EcsPageIter page;
		EcsWorkerIter worker;
		EcsEachIter each;
	}

	<* Query applied after matching a table. *>
	void* entity_iter;
}

fn void test() {
	EcsIter it;
	it.query.q = 10;
	it.page.p = 20;
}
`;

	proj.workspace.process_file("/virtual/nested_union_doc.c3", source);
	Uri doc_uri = uri::from_file_path(mem, "/virtual/nested_union_doc.c3");
	defer doc_uri.free();

	LspDiagnostic[] diags = proj.workspace.get_diagnostics("/virtual/nested_union_doc.c3");
	test::eq(diags.len, 0);

	LspPosition query_pos = { .line = 25, .character = 4 };
	String h_query = hover::hover(&proj, doc_uri, query_pos)!!;
	assert(h_query.contains("EcsQueryIter query"));

	LspLocation[] locs_query = goto_definition::goto_definition(&proj, doc_uri, query_pos)!!;
	assert(locs_query.len > 0);
	assert(locs_query[0].range.start.line == 13);
}

fn void test_issue_6_named_nested_struct_completion() @test
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = `module app;

struct MyStruct
{
    int foo;
    int bar;

    struct inner
    {
        int baz;
    }
}

fn void test() {
    MyStruct ms = {
        .
    };

    MyStruct ms2 = {
        .inner = {
            .
        }
    };
}
`;

	proj.workspace.process_file("/virtual/issue_6.c3", source);
	Uri doc_uri = uri::from_file_path(mem, "/virtual/issue_6.c3");
	defer doc_uri.free();

	// 1. Completion inside `MyStruct ms = { .` (line 15, col 9)
	LspPosition pos1 = { .line = 15, .character = 9 };
	CompletionItem[] items1 = completion::resolve(&proj, doc_uri, pos1)!!;

	bool found_foo = false;
	bool found_bar = false;
	bool found_inner = false;
	bool found_baz1 = false;

	foreach (item : items1)
	{
		if (item.label == "foo") found_foo = true;
		if (item.label == "bar") found_bar = true;
		if (item.label == "inner") found_inner = true;
		if (item.label == "baz") found_baz1 = true;
	}

	assert(found_foo);
	assert(found_bar);
	assert(found_inner);
	assert(!found_baz1);

	// 2. Completion inside `.inner = { .` (line 20, col 13)
	LspPosition pos2 = { .line = 20, .character = 13 };
	CompletionItem[] items2 = completion::resolve(&proj, doc_uri, pos2)!!;

	bool found_baz2 = false;
	bool found_global = false;

	foreach (item : items2)
	{
		if (item.label == "baz") found_baz2 = true;
		if (item.label == "ms" || item.label.starts_with("@")) found_global = true;
	}

	assert(found_baz2);
	assert(!found_global);
}

fn void test_deeply_nested_and_mixed_substructs() @test
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = `module app;

struct Outer {
    int root_val;

    struct level1 {
        int l1_val;

        struct level2 {
            int l2_val;
        }

        union {
            int anon_u_int;
            float anon_u_float;
        }
    }

    struct sibling {
        int sib_val;
    }
}

fn void test() {
    Outer o;
    int a = o.root_val;
    int b = o.level1.l1_val;
    int c = o.level1.level2.l2_val;
    int d = o.level1.anon_u_int;
    int e = o.sibling.sib_val;

    Outer o1 = {
        .
    };

    Outer o2 = {
        .level1 = {
            .
        }
    };

    Outer o3 = {
        .level1 = {
            .level2 = {
                .
            }
        }
    };

    Outer o4 = {
        .level1.level2.
    };
}
`;

	proj.workspace.process_file("/virtual/deep_nested.c3", source);
	Uri doc_uri = uri::from_file_path(mem, "/virtual/deep_nested.c3");
	defer doc_uri.free();

	// 1. Root designated initializer completion `Outer o1 = { .` (line 32, col 9)
	LspPosition pos1 = { .line = 32, .character = 9 };
	CompletionItem[] items1 = completion::resolve(&proj, doc_uri, pos1)!!;

	bool has_root_val = false;
	bool has_level1 = false;
	bool has_sibling = false;
	bool leak_l1_val = false;
	bool leak_level2 = false;
	bool leak_l2_val = false;
	bool leak_sib_val = false;

	foreach (item : items1)
	{
		if (item.label == "root_val") has_root_val = true;
		if (item.label == "level1") has_level1 = true;
		if (item.label == "sibling") has_sibling = true;
		if (item.label == "l1_val") leak_l1_val = true;
		if (item.label == "level2") leak_level2 = true;
		if (item.label == "l2_val") leak_l2_val = true;
		if (item.label == "sib_val") leak_sib_val = true;
	}

	assert(has_root_val);
	assert(has_level1);
	assert(has_sibling);
	assert(!leak_l1_val);
	assert(!leak_level2);
	assert(!leak_l2_val);
	assert(!leak_sib_val);

	// 2. Level 1 designated initializer completion `.level1 = { .` (line 37, col 13)
	LspPosition pos2 = { .line = 37, .character = 13 };
	CompletionItem[] items2 = completion::resolve(&proj, doc_uri, pos2)!!;

	bool has_l1_val = false;
	bool has_level2 = false;
	bool has_anon_u = false;
	bool leak_root = false;
	bool leak_sib = false;
	bool leak_l2 = false;

	foreach (item : items2)
	{
		if (item.label == "l1_val") has_l1_val = true;
		if (item.label == "level2") has_level2 = true;
		if (item.label == "anon_u_int") has_anon_u = true;
		if (item.label == "root_val") leak_root = true;
		if (item.label == "sibling") leak_sib = true;
		if (item.label == "l2_val") leak_l2 = true;
	}

	assert(has_l1_val);
	assert(has_level2);
	assert(has_anon_u);
	assert(!leak_root);
	assert(!leak_sib);
	assert(!leak_l2);

	// 3. Level 2 designated initializer completion `.level2 = { .` (line 44, col 17)
	LspPosition pos3 = { .line = 44, .character = 17 };
	CompletionItem[] items3 = completion::resolve(&proj, doc_uri, pos3)!!;

	bool has_l2_val = false;
	bool leak_outer = false;

	foreach (item : items3)
	{
		if (item.label == "l2_val") has_l2_val = true;
		if (item.label == "l1_val" || item.label == "root_val" || item.label == "level1") leak_outer = true;
	}

	assert(has_l2_val);
	assert(!leak_outer);

	// 4. Chained designator dot completion `.level1.level2.` (line 50, col 23)
	LspPosition pos4 = { .line = 50, .character = 23 };
	CompletionItem[] items4 = completion::resolve(&proj, doc_uri, pos4)!!;

	bool has_chained_l2 = false;
	foreach (item : items4)
	{
		if (item.label == "l2_val") has_chained_l2 = true;
	}
	assert(has_chained_l2);

	// 5. Hover on 3rd level field `o.level1.level2.l2_val` (line 27, col 29)
	LspPosition hover_pos = { .line = 27, .character = 29 };
	String h = hover::hover(&proj, doc_uri, hover_pos)!!;
	assert(h.contains("int l2_val"));

	// 6. Goto definition on 3rd level field `l2_val` -> line 9
	LspLocation[] locs = goto_definition::goto_definition(&proj, doc_uri, hover_pos)!!;
	assert(locs.len > 0);
	assert(locs[0].range.start.line == 9);

	// 7. Goto definition on 2nd level sub-struct `level2` (line 27, col 22) -> line 8
	LspPosition l2_def_pos = { .line = 27, .character = 22 };
	LspLocation[] locs_l2 = goto_definition::goto_definition(&proj, doc_uri, l2_def_pos)!!;
	assert(locs_l2.len > 0);
	assert(locs_l2[0].range.start.line == 8);
}