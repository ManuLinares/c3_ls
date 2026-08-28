module lsp::deep_method_chain_test @test;

import lsp::core;
import lsp::analysis::completion;
import lsp::analysis::goto_definition;
import lsp::analysis::hover;
import lsp::analysis::signature_help;
import lsp;
import uri;
import std::io;

fn void test_deep_method_and_member_chaining() @test
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = `module demo::chain_app;

struct NodeA {
	NodeB b;
}

struct NodeB {
	int val;
}

fn NodeC NodeB.to_c(self) {
	return {};
}

struct NodeC {
	NodeD* d_ptr;
}

struct NodeD {
	NodeE e;
}

fn NodeE NodeD.get_e(&self) {
	return self.e;
}

struct NodeE {
	String name;
}

fn double double.custom_clamp(self, double min, double max) {
	return self;
}

fn double sz.to_double(self) {
	return (double)self;
}

fn void main() {
	NodeD d_inst;
	NodeA a;
	a.b.to_c().d_ptr.get_e().name.len.to_double().custom_clamp(1.0, 10.0);
}
`;

	proj.workspace.process_file("/virtual/deep_chain.c3", source);
	Uri doc_uri = uri::from_file_path(mem, "/virtual/deep_chain.c3");
	defer doc_uri.free();

	// Line 41 (0-based) is:
	// 	a.b.to_c().d_ptr.get_e().name.len.to_double().custom_clamp(1.0, 10.0);
	// 0123456789012345678901234567890123456789012345678901234567890123456789012
	//           1         2         3         4         5         6         7

	// 1. Hover on `to_c` (line 41, col 6) -> returns NodeB.to_c
	LspPosition hover_to_c = { .line = 41, .character = 6 };
	String h_c = hover::hover(&proj, doc_uri, hover_to_c)!!;
	assert(h_c.contains("NodeB.to_c"));

	// 2. Hover on `get_e` (line 41, col 20) -> returns NodeD.get_e
	LspPosition hover_get_e = { .line = 41, .character = 20 };
	String h_e = hover::hover(&proj, doc_uri, hover_get_e)!!;
	assert(h_e.contains("NodeD.get_e"));

	// 3. Hover on `to_double` (line 41, col 38) -> returns sz.to_double
	LspPosition hover_to_d = { .line = 41, .character = 38 };
	String h_d = hover::hover(&proj, doc_uri, hover_to_d)!!;
	assert(h_d.contains("sz.to_double"));

	// 4. Hover on `custom_clamp` (line 41, col 50) -> returns double.custom_clamp
	LspPosition hover_clamp = { .line = 41, .character = 50 };
	String h_clamp = hover::hover(&proj, doc_uri, hover_clamp)!!;
	assert(h_clamp.contains("double.custom_clamp"));

	// 5. Go to definition on `custom_clamp` (line 41, col 50) -> jumps to line 30
	LspLocation[] locs = goto_definition::goto_definition(&proj, doc_uri, hover_clamp)!!;
	assert(locs.len > 0);
	assert(locs[0].range.start.line == 30);

	// 6. Go to definition on `get_e` (line 41, col 20) -> jumps to line 22
	LspLocation[] locs_e = goto_definition::goto_definition(&proj, doc_uri, hover_get_e)!!;
	assert(locs_e.len > 0);
	assert(locs_e[0].range.start.line == 22);

	// 7. Signature help inside `custom_clamp(` (line 41, col 63)
	LspPosition sig_pos = { .line = 41, .character = 63 };
	SignatureHelpResult sig_res = signature_help::signature_help(&proj, doc_uri, sig_pos)!!;
	assert(sig_res.signatures.len > 0);
	assert(sig_res.signatures[0].parameters.len == 2);
	assert(sig_res.signatures[0].parameters[0].label.contains("min"));
	assert(sig_res.signatures[0].parameters[1].label.contains("max"));
}

fn void test_deep_method_chain_completion() @test
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = `module demo::chain_comp;

struct Level1 { Level2 l2; }
struct Level2 { Level3 l3; }
struct Level3 { Level4 l4; }
struct Level4 { Level5 l5; }
struct Level5 { Level6 l6; }
struct Level6 { String greeting; }

fn void Level6.shout(self) {}

fn void run() {
	Level1 root;
	root.l2.l3.l4.l5.l6.
}
`;

	proj.workspace.process_file("/virtual/chain_comp.c3", source);
	Uri doc_uri = uri::from_file_path(mem, "/virtual/chain_comp.c3");
	defer doc_uri.free();

	// Completion after 6th dot: `\troot.l2.l3.l4.l5.l6.` (line 13, character 21)
	LspPosition comp_pos = { .line = 13, .character = 21 };
	CompletionItem[] items = completion::resolve(&proj, doc_uri, comp_pos)!!;
	assert(items.len > 0);

	bool found_greeting = false;
	bool found_shout = false;
	foreach (item : items)
	{
		if (item.label == "greeting") found_greeting = true;
		if (item.label == "shout") found_shout = true;
	}
	assert(found_greeting);
	assert(found_shout);
}
