module lsp::condition_decls_test @test;

import lsp::core;
import lsp::analysis::hover;
import lsp::analysis::goto_definition;
import lsp::analysis::references;
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
	// 1. Hover on `current` inside the `if (try ...)` body (line 11, col 14)
	LspPosition if_var_pos = {.line = 11,.character = 14 };
	String if_hover = hover::hover(&proj, doc_uri, if_var_pos)!!;
	assert(if_hover.contains("current"));
	// 2. Goto definition on `current` -> jumps to `if (try Node* current = ...)` at line 10
	LspLocation[] if_locs = goto_definition::goto_definition(&proj, doc_uri, if_var_pos)!!;
	assert(if_locs.len > 0);
	assert(if_locs[0].range.start.line == 10);
	// 3. Hover on `curr` inside the `while (Node* curr = ...)` body (line 15, col 14)
	LspPosition while_var_pos = {.line = 15,.character = 14 };
	String while_hover = hover::hover(&proj, doc_uri, while_var_pos)!!;
	assert(while_hover.contains("curr"));
	// 4. Goto definition on `curr` -> jumps to `while (Node* curr = ...)` at line 14
	LspLocation[] while_locs = goto_definition::goto_definition(&proj, doc_uri, while_var_pos)!!;
	assert(while_locs.len > 0);
	assert(while_locs[0].range.start.line == 14);
	// 5. Find references on `curr` (line 14, col 15) -> matches declaration and usage on line 15
	LspPosition curr_decl_pos = {.line = 14,.character = 15 };
	LspLocation[] refs = references::find_references(&proj, doc_uri, curr_decl_pos, {.includeDeclaration = true })!!;
	assert(refs.len == 2);
}
