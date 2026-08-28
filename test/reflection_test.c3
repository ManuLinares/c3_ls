module lsp::reflection_test @test;

import lsp::core;
import lsp::analysis::hover;
import lsp::analysis::goto_definition;
import lsp::analysis::completion;
import lsp;
import uri;
import std::io;

fn void test_typefrom_navigation()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = `module app;
struct Packet { int length; }
fn void main() {
  $Typefrom(Packet::typeid) pkt;
}
`;

	proj.workspace.process_file("/virtual/refl_typefrom.c3", source);
	Uri doc_uri = uri::from_file_path(mem, "/virtual/refl_typefrom.c3");
	defer doc_uri.free();

	LspPosition packet_pos = {.line = 3,.character = 14 };
	LspLocation[] locs = goto_definition::goto_definition(&proj, doc_uri, packet_pos)!!;
	assert(locs.len > 0);
	assert(locs[0].range.start.line == 1);
}

fn void test_reflect_member_completion()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = `module app;
struct Account { int id; }
fn void run() {
  Account acc;
  sz sz_val = $reflect(acc).
}
`;

	proj.workspace.process_file("/virtual/refl_comp.c3", source);
	Uri doc_uri = uri::from_file_path(mem, "/virtual/refl_comp.c3");
	defer doc_uri.free();

	LspPosition pos = {.line = 4,.character = 28 };
	CompletionItem[] items = completion::resolve(&proj, doc_uri, pos)!!;

	bool found_offset = false;
	bool found_bitoffset = false;
	bool found_param_struct = false;

	foreach (item : items)
	{
		if (item.label == "offset") found_offset = true;
		if (item.label == "bitoffset") found_bitoffset = true;
		if (item.label == "param_struct") found_param_struct = true;
	}

	assert(found_offset);
	assert(found_bitoffset);
	assert(found_param_struct);
}

fn void test_reflect_bitoffset_and_bitsize_hover()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = `module app;
bitstruct Header : short {
  int mode : 0..3;
  bool flag : 4;
}
fn void run() {
  sz off = $reflect(Header.mode).bitoffset;
  sz len = $reflect(Header.mode).bitsize;
}
`;

	proj.workspace.process_file("/virtual/refl_bitstruct.c3", source);
	Uri doc_uri = uri::from_file_path(mem, "/virtual/refl_bitstruct.c3");
	defer doc_uri.free();

	LspPosition off_pos = {.line = 6,.character = 35 };
	String h_off = hover::hover(&proj, doc_uri, off_pos)!!;
	assert(h_off.contains("0 (bits)"));

	LspPosition len_pos = {.line = 7,.character = 35 };
	String h_len = hover::hover(&proj, doc_uri, len_pos)!!;
	assert(h_len.contains("4 (bits)"));
}

fn void test_typeof_static_completion()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = `module app;
struct Entity { int health; }
fn void run() {
  Entity ent;
  $Typeof(ent)::
}
`;

	proj.workspace.process_file("/virtual/refl_typeof.c3", source);
	Uri doc_uri = uri::from_file_path(mem, "/virtual/refl_typeof.c3");
	defer doc_uri.free();

	LspPosition static_pos = {.line = 4,.character = 16 };
	CompletionItem[] items = completion::resolve(&proj, doc_uri, static_pos)!!;

	bool found_align = false;
	bool found_has_equals = false;
	bool found_generic_args = false;

	foreach (item : items)
	{
		if (item.label == "alignment") found_align = true;
		if (item.label == "has_equals") found_has_equals = true;
		if (item.label == "generic_args") found_generic_args = true;
	}

	assert(found_align);
	assert(found_has_equals);
	assert(found_generic_args);
}

fn void test_generic_static_completion_and_private_guard()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String lib_code = `module std::collections::list;
struct List <Type> { Type* ptr; sz len; }
`;
	String priv_code = `module std::crypto::ed25519 @private;
struct Point { int x; int y; }
`;
	String app_code = `module app;
import std::collections::list;
fn void test() {
  List{int}::
  Point pt;
}
`;

	proj.workspace.process_file("/virtual/list_lib.c3", lib_code);
	proj.workspace.process_file("/virtual/ed25519.c3", priv_code);
	proj.workspace.process_file("/virtual/app_test.c3", app_code);

	Uri app_uri = uri::from_file_path(mem, "/virtual/app_test.c3");
	defer app_uri.free();
	// 1. `List{int}::` static completion provides reflection properties
	LspPosition list_pos = {.line = 3,.character = 13 };
	CompletionItem[] items = completion::resolve(&proj, app_uri, list_pos)!!;
	bool found_generic_args = false;
	bool found_size = false;
	foreach (item : items)
	{
		if (item.label == "generic_args") found_generic_args = true;
		if (item.label == "size") found_size = true;
	}
	assert(found_generic_args);
	assert(found_size);
	// 2. Unimported private `Point` does not jump to std::crypto::ed25519
	LspPosition point_pos = {.line = 4,.character = 4 };
	LspLocation[] locs = goto_definition::goto_definition(&proj, app_uri, point_pos)!!;
	assert(locs.len == 0);
}

fn void test_defined_expression_navigation_and_hover()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = `module app;
struct User { int id; }
fn void test_def() {
  User u;
  if ($defined(u.id)) { int x = u.id; }
}
`;

	proj.workspace.process_file("/virtual/refl_def.c3", source);
	Uri doc_uri = uri::from_file_path(mem, "/virtual/refl_def.c3");
	defer doc_uri.free();

	LspPosition id_pos = {.line = 4,.character = 18 };
	LspLocation[] locs = goto_definition::goto_definition(&proj, doc_uri, id_pos)!!;
	assert(locs.len > 0);
	assert(locs[0].range.start.line == 1);

	LspPosition u_pos = {.line = 4,.character = 16 };
	String h = hover::hover(&proj, doc_uri, u_pos)!!;
	assert(h.contains("User u"));
}

fn void test_unresolved_member_access_does_not_leak_globals()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = `module app;
fn void test() {
  non_existent_var.
}
`;

	proj.workspace.process_file("/virtual/unresolved_comp.c3", source);
	Uri doc_uri = uri::from_file_path(mem, "/virtual/unresolved_comp.c3");
	defer doc_uri.free();

	LspPosition pos = {.line = 2,.character = 19 };
	CompletionItem[] items = completion::resolve(&proj, doc_uri, pos)!!;
	assert(items.len == 0);
}

fn void test_chained_member_access_completion()
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
  my_car.engine.
}
`;

	proj.workspace.process_file("/virtual/chain_comp.c3", source);
	Uri doc_uri = uri::from_file_path(mem, "/virtual/chain_comp.c3");
	defer doc_uri.free();

	LspPosition pos = {.line = 11,.character = 16 };
	CompletionItem[] items = completion::resolve(&proj, doc_uri, pos)!!;
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

fn void test_generic_instance_member_completion()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = `module app;
struct List <Type> {
  Type* items;
  sz count;
}
fn void List.push(&self, Type elem) {}
fn Type List.pop(&self) { return self.items[--self.count]; }

fn void main() {
  List{int} a;
  a.
}
`;

	proj.workspace.process_file("/virtual/gen_inst_comp.c3", source);
	Uri doc_uri = uri::from_file_path(mem, "/virtual/gen_inst_comp.c3");
	defer doc_uri.free();

	LspPosition pos = {.line = 10,.character = 4 };
	CompletionItem[] items = completion::resolve(&proj, doc_uri, pos)!!;
	assert(items.len >= 4);

	bool found_items = false;
	bool found_count = false;
	bool found_push = false;
	bool found_pop = false;

	foreach (item : items)
	{
		if (item.label == "items") found_items = true;
		if (item.label == "count") found_count = true;
		if (item.label == "push") found_push = true;
		if (item.label == "pop") found_pop = true;
		assert(item.label != "while" && item.label != "struct" && item.label != "import");
	}

	assert(found_items);
	assert(found_count);
	assert(found_push);
	assert(found_pop);
}

fn void test_multi_section_file_visibility()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String mixed_file = `module crypto::ed25519;
fn void sign_data() {}

module crypto::ed25519 @private;
struct SecretKey { ulong k; }
`;
	String app_file = `module consumer;
import crypto::ed25519;
fn void run() {
  crypto::ed25519::sign_data();
  SecretKey sk;
}
`;

	proj.workspace.process_file("/virtual/ed.c3", mixed_file);
	proj.workspace.process_file("/virtual/consumer.c3", app_file);

	Uri app_uri = uri::from_file_path(mem, "/virtual/consumer.c3");
	defer app_uri.free();
	// 1. Public function in first section resolves cleanly
	LspPosition fn_pos = {.line = 3,.character = 20 };
	LspLocation[] fn_locs = goto_definition::goto_definition(&proj, app_uri, fn_pos)!!;
	assert(fn_locs.len > 0);
	assert(fn_locs[0].range.start.line == 1);
	// 2. Struct in @private section of same file is not accessible to consumer
	LspPosition sk_pos = {.line = 4,.character = 4 };
	LspLocation[] sk_locs = goto_definition::goto_definition(&proj, app_uri, sk_pos)!!;
	assert(sk_locs.len == 0);
}

fn void test_single_colon_and_double_colon_completion_text()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = `module app;
struct Point { int x; }
fn void run() {
  Point:
  Point::
}
`;

	proj.workspace.process_file("/virtual/colon_test.c3", source);
	Uri doc_uri = uri::from_file_path(mem, "/virtual/colon_test.c3");
	defer doc_uri.free();
	// 1. Single colon `Point:` -> insertText starts with `:` to complete `::`
	LspPosition single_pos = {.line = 3,.character = 8 };
	CompletionItem[] single_items = completion::resolve(&proj, doc_uri, single_pos)!!;
	bool found_single_align = false;
	foreach (item : single_items)
	{
		if (item.label == "alignment")
		{
			assert(item.insertText == ":alignment");
			found_single_align = true;
		}
	}
	assert(found_single_align);
	// 2. Double colon `Point::` -> insertText does NOT have leading `:`
	LspPosition double_pos = {.line = 4,.character = 9 };
	CompletionItem[] double_items = completion::resolve(&proj, doc_uri, double_pos)!!;
	bool found_double_align = false;
	foreach (item : double_items)
	{
		if (item.label == "alignment")
		{
			assert(item.insertText == "alignment");
			found_double_align = true;
		}
	}
	assert(found_double_align);
}
