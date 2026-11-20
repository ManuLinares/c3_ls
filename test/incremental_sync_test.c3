module lsp::incremental_sync_test;

import lsp, uri;

macro String text_after(String initial, TextDocumentContentChangeEvent[] changes)
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();
	Uri u = uri::from_file_path(tmem, "/virtual/sync.c3");
	DocumentUri raw = (DocumentUri)u.to_raw_string(tmem);
	proj.open_file({ .uri = raw, .language_id = "c3", .version = 1, .text = initial });
	proj.change_file({ .document = { .uri = raw, .version = 2 }, .content_changes = changes });
	return proj.files.get(u.path)!!.text.tcopy();
}

macro LspRange* range(uint l1, uint c1, uint l2, uint c2) => mem::tnew(LspRange, { { l1, c1 }, { l2, c2 } });

fn void edits_apply_in_order() @test
{
	String after = text_after("module app;\nfn void f() {}\n", {
		{ .range = range(1, 8, 1, 9), .text = "g" },
		{ .range = range(1, 13, 1, 13), .text = "return; " },
	});
	test::eq(after, "module app;\nfn void g() {return; }\n");
}

fn void full_text_change_replaces_everything() @test
{
	test::eq(text_after("module app;\n", { { .text = "module other;\n" } }), "module other;\n");
}

fn void characters_count_utf16_units() @test
{
	// `é` is one UTF-16 unit, the emoji two; both are several UTF-8 bytes.
	String after = text_after("module app;\nString s = \"é😀x\";\n", { { .range = range(1, 15, 1, 16), .text = "y" } });
	test::eq(after, "module app;\nString s = \"é😀y\";\n");
}

fn void decoded_ranges_are_freed() @test
{
	IoDecodeResult res = translator::decode(mem, `{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///a.c3","version":2},"contentChanges":[{"range":{"start":{"line":1,"character":2},"end":{"line":1,"character":3}},"text":"x"},{"text":"all"}]}}`)!!;
	defer res.message.free();
	TextDocumentContentChangeEvent[] changes = res.message.params.did_change.content_changes;
	assert(changes.len == 2 && changes[0].range && changes[0].range.end.character == 3 && !changes[1].range);
}

fn void edits_on_later_lines() @test
{
	String after = text_after("module app;\nfn void f() {}\nfn void g() {}\nfn void h() {}\n", { { .range = range(3, 8, 3, 9), .text = "k" } });
	test::eq(after, "module app;\nfn void f() {}\nfn void g() {}\nfn void k() {}\n");
}

fn void invalid_utf8_counts_as_one_unit() @test
{
	String after = text_after("module app;\n\"\xFFab\";\n", { { .range = range(1, 2, 1, 3), .text = "X" } });
	test::eq(after, "module app;\n\"\xFFXb\";\n");
}

fn void replacement_character_is_one_unit() @test
{
	String after = text_after("module app;\n\"\uFFFDab\";\n", { { .range = range(1, 2, 1, 3), .text = "X" } });
	test::eq(after, "module app;\n\"\uFFFDXb\";\n");
}

fn void client_version_zero_first_change_not_dropped() @test
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();
	Uri u = uri::from_file_path(tmem, "/virtual/helix.c3");
	DocumentUri raw = (DocumentUri)u.to_raw_string(tmem);
	proj.open_file({ .uri = raw, .language_id = "c3", .version = 0, .text = "module app;\nfn void f() {}\n" });
	proj.change_file({ .document = { .uri = raw, .version = 1 }, .content_changes = (TextDocumentContentChangeEvent[]){
		{ .range = range(1, 14, 1, 14), .text = "\n" },
	}});
	String text = proj.files.get(u.path)!!.text.tcopy();
	test::eq(text, "module app;\nfn void f() {}\n\n");
}

fn void insert_line_keeps_later_lines_in_sync() @test
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();
	Uri u = uri::from_file_path(tmem, "/virtual/desync.c3");
	DocumentUri raw = (DocumentUri)u.to_raw_string(tmem);
	proj.open_file({ .uri = raw, .language_id = "c3", .version = 0, .text = "module app;\nfn void f() {}\nfn void g() {}\n" });
	// Insert a blank line after line 1
	proj.change_file({ .document = { .uri = raw, .version = 1 }, .content_changes = (TextDocumentContentChangeEvent[]){
		{ .range = range(1, 14, 1, 14), .text = "\n" },
	}});
	// Edit on the line that shifted from 2 to 3
	proj.change_file({ .document = { .uri = raw, .version = 2 }, .content_changes = (TextDocumentContentChangeEvent[]){
		{ .range = range(3, 8, 3, 9), .text = "k" },
	}});
	String text = proj.files.get(u.path)!!.text.tcopy();
	test::eq(text, "module app;\nfn void f() {}\n\nfn void k() {}\n");
}
