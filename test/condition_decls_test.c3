module lsp::condition_decls_test @test;

import lsp::core;
import lsp::analysis::hover;
import lsp::analysis::goto_definition;
import lsp::analysis::references;
import lsp::analysis::completion;
import lsp;
import uri;
import std::io;

fn void test_try_unwrap_and_while_declaration_scoping()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = `module app;

struct Node {
  int value;
  Node* next;
}

fn Node*? get_first_node() { return null; }

fn void process() {
  if (try Node* current = get_first_node()) {
    int v = current.value;
  }

  while (Node* curr = get_first_node()) {
    int v2 = curr.value;
  }
}
`;

	proj.workspace.process_file("/virtual/cond_decls.c3", source);
	Uri doc_uri = uri::from_file_path(mem, "/virtual/cond_decls.c3");
	defer doc_uri.free();

	LspPosition if_var_pos = {.line = 11,.character = 14 };
	String if_hover = hover::hover(&proj, doc_uri, if_var_pos)!!;
	assert(if_hover.contains("current"));

	LspLocation[] if_locs = goto_definition::goto_definition(&proj, doc_uri, if_var_pos)!!;
	assert(if_locs.len > 0);
	assert(if_locs[0].range.start.line == 10);

	LspPosition while_var_pos = {.line = 15,.character = 14 };
	String while_hover = hover::hover(&proj, doc_uri, while_var_pos)!!;
	assert(while_hover.contains("curr"));

	LspLocation[] while_locs = goto_definition::goto_definition(&proj, doc_uri, while_var_pos)!!;
	assert(while_locs.len > 0);
	assert(while_locs[0].range.start.line == 14);

	LspPosition curr_decl_pos = {.line = 14,.character = 15 };
	LspLocation[] refs = references::find_references(&proj, doc_uri, curr_decl_pos, {.includeDeclaration = true })!!;
	assert(refs.len == 2);
}

fn void test_while_try_inferred_call_completion_and_navigation()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String gfx_mod = `module std::gfx;

struct IntRect {
	int x;
	int y;
	int width;
	int height;
}

struct GfxWindowUpdateEvent {
	IntRect bounds;
}

union GfxEvent {
	int type;
	GfxWindowUpdateEvent update;
}

struct GfxWindow {
	int id;
}

fn GfxEvent? check_window_event(GfxWindow* win) {
	return null;
}
`;

	String app_code = `module app;
import std::gfx;

fn void run(GfxWindow* win) {
	while (try event = gfx::check_window_event(win)) {
		event.
		int w = event.update.bounds.width;
	}
}
`;

	proj.workspace.process_file("/virtual/gfx.c3", gfx_mod);
	proj.workspace.process_file("/virtual/app.c3", app_code);

	Uri doc_uri = uri::from_file_path(mem, "/virtual/app.c3");
	defer doc_uri.free();

	// 1. Completion on `event.`
	LspPosition comp_pos = { .line = 5, .character = 8 };
	CompletionItem[] items = completion::resolve(&proj, doc_uri, comp_pos)!!;
	bool found_update = false;
	bool found_type = false;
	foreach (item : items)
	{
		if (item.label == "update") found_update = true;
		if (item.label == "type") found_type = true;
	}
	assert(found_update);
	assert(found_type);

	// 2. Hover on `update`
	LspPosition update_pos = { .line = 6, .character = 16 };
	String h_update = hover::hover(&proj, doc_uri, update_pos)!!;
	assert(h_update.contains("GfxWindowUpdateEvent update"));

	// 3. Hover on `bounds`
	LspPosition bounds_pos = { .line = 6, .character = 23 };
	String h_bounds = hover::hover(&proj, doc_uri, bounds_pos)!!;
	assert(h_bounds.contains("IntRect bounds"));

	// 4. Hover on `width`
	LspPosition width_pos = { .line = 6, .character = 30 };
	String h_width = hover::hover(&proj, doc_uri, width_pos)!!;
	assert(h_width.contains("int width"));

	// 5. Go to definition on `width` in IntRect
	LspLocation[] locs_width = goto_definition::goto_definition(&proj, doc_uri, width_pos)!!;
	assert(locs_width.len > 0);
	assert(locs_width[0].uri.contains("gfx.c3"));
	assert(locs_width[0].range.start.line == 5);

	// 6. Go to definition on `update` in GfxEvent
	LspLocation[] locs_update = goto_definition::goto_definition(&proj, doc_uri, update_pos)!!;
	assert(locs_update.len > 0);
	assert(locs_update[0].uri.contains("gfx.c3"));
	assert(locs_update[0].range.start.line == 15);

	// 7. Hover on `event`
	LspPosition event_pos = { .line = 6, .character = 10 };
	String h_event = hover::hover(&proj, doc_uri, event_pos)!!;
	assert(h_event.contains("GfxEvent event"));

	// 8. Go to definition on `event` declaration
	LspLocation[] locs_event = goto_definition::goto_definition(&proj, doc_uri, event_pos)!!;
	assert(locs_event.len > 0);
	assert(locs_event[0].range.start.line == 4);
}