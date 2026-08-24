// test/nested_substructs_test.c3
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
	LspPosition hp_pos = { .line = 14, .character = 27 };
	String hp_hover = hover::hover(&proj, doc_uri, hp_pos)!!;
	assert(hp_hover.contains("horsepower"));
	assert(hp_hover.contains("int"));

	// 2. Goto definition on `horsepower` -> jumps to `horsepower` in `struct Engine` (line 3)
	LspLocation[] locs = goto_definition::goto_definition(&proj, doc_uri, hp_pos)!!;
	assert(locs.len > 0);
	assert(locs[0].range.start.line == 3);

	// 3. Hover on `engine` in `my_car.engine` (line 14, col 20)
	LspPosition eng_pos = { .line = 14, .character = 20 };
	String eng_hover = hover::hover(&proj, doc_uri, eng_pos)!!;
	assert(eng_hover.contains("Engine"));

	// 4. Completion on `my_car.engine.` (line 14, col 25) -> suggests `horsepower` and `displacement`
	LspPosition comp_pos = { .line = 14, .character = 25 };
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
	LspPosition b128_pos = { .line = 14, .character = 6 };
	String b128_hover = hover::hover(&proj, doc_uri, b128_pos)!!;
	assert(b128_hover.contains("block_128"));
	assert(b128_hover.contains("int128[4]"));

	// 2. Go to definition on `w.block_128` -> jumps to `int128[4] block_128` on line 6
	LspLocation[] locs = goto_definition::goto_definition(&proj, doc_uri, b128_pos)!!;
	assert(locs.len > 0);
	assert(locs[0].range.start.line == 6);

	// 3. Hover on `hash_ref` (line 15, col 9) -> shows `ulong* hash_ref`
	LspPosition hash_ref_pos = { .line = 15, .character = 9 };
	String href_hover = hover::hover(&proj, doc_uri, hash_ref_pos)!!;
	assert(href_hover.contains("ulong* hash_ref"));

	// 4. Go to definition on `hash_ref` in `hash_ref[0]` (line 16, col 18)
	LspPosition href_idx_pos = { .line = 16, .character = 18 };
	LspLocation[] href_locs = goto_definition::goto_definition(&proj, doc_uri, href_idx_pos)!!;
	assert(href_locs.len > 0);
	assert(href_locs[0].range.start.line == 15);
}