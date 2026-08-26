module lsp::module_extension_test @test;

import lsp::core;
import lsp::analysis::hover;
import lsp::analysis::goto_definition;
import lsp::analysis::completion;
import lsp::analysis::inlay_hints;
import lsp;
import uri;
import std::io;

fn void test_reopened_module_cross_file_methods()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();
	// File 1: Base module declares struct
	String file1 = `module geom;
struct Vector2D {
  float x;
  float y;
}
`;
	// File 2: Reopens `module geom;` in another file and adds methods
	String file2 = `module geom;
fn Vector2D Vector2D.add(&self, Vector2D other) {
  return { .x = self.x + other.x, .y = self.y + other.y };
}
fn float Vector2D.magnitude_sq(&self) {
  return self.x * self.x + self.y * self.y;
}
`;
	// File 3: Consumer imports `geom` and uses both fields and extension methods
	String file3 = `module game;
import geom;
fn void update() {
  Vector2D v1 = { .x = 1.0f, .y = 2.0f };
  Vector2D v2 = { .x = 3.0f, .y = 4.0f };
  Vector2D v3 = v1.add(v2);
  float mag = v3.magnitude_sq();
}
`;

	proj.workspace.process_file("/virtual/geom_base.c3", file1);
	proj.workspace.process_file("/virtual/geom_ext.c3", file2);
	proj.workspace.process_file("/virtual/game_app.c3", file3);

	Uri app_uri = uri::from_file_path(mem, "/virtual/game_app.c3");
	defer app_uri.free();
	// 1. Hover on `v1.add` in file 3 -> signature from file 2
	LspPosition add_pos = {.line = 5,.character = 20 };
	String add_hover = hover::hover(&proj, app_uri, add_pos)!!;
	assert(add_hover.contains("Vector2D.add"));
	// 2. Goto definition on `v1.add` -> jumps to file 2 (geom_ext.c3)
	LspLocation[] add_locs = goto_definition::goto_definition(&proj, app_uri, add_pos)!!;
	assert(add_locs.len > 0);
	assert(add_locs[0].uri.contains("geom_ext.c3"));
	assert(add_locs[0].range.start.line == 1);
	// 3. Inlay hints inside `v1.add(v2)` -> shows `other:` parameter hint
	LspRange call_range = {
		.start = {.line = 5,.character = 0 },
		.end = {.line = 5,.character = 30 }
	};
	InlayHint[] hints = inlay_hints::get_inlay_hints(&proj, app_uri, call_range)!!;
	assert(hints.len == 1);
	assert(hints[0].label == "other:");
	// 4. Completion on `v3.` -> suggests fields `x`, `y` from file 1 and methods `add`, `magnitude_sq` from file 2
	LspPosition comp_pos = {.line = 6,.character = 17 };
	CompletionItem[] items = completion::resolve(&proj, app_uri, comp_pos)!!;
	assert(items.len >= 4);
	bool found_x = false;
	bool found_add = false;
	bool found_mag = false;
	foreach (item : items)
	{
		if (item.label == "x") found_x = true;
		if (item.label == "add") found_add = true;
		if (item.label == "magnitude_sq") found_mag = true;
	}
	assert(found_x);
	assert(found_add);
	assert(found_mag);
}
