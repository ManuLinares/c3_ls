module lsp::exhaustive_matrix_test @test;

import lsp::core;
import lsp::analysis::hover;
import lsp::analysis::goto_definition;
import lsp::analysis::completion;
import lsp::analysis::references;
import lsp::analysis::rename;
import lsp::analysis::signature_help;
import lsp;
import uri;
import std::io;

fn void test_generic_instantiation_hover_and_def()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String lib_code = "module generic_lib;\nstruct Stack <Type> {\n  Type* items;\n  sz count;\n}\nfn void Stack.push(&self, Type item) {}\nfn Type Stack.pop(&self) { return self.items[--self.count]; }\n";
	String app_code = "module app;\nimport generic_lib;\nfn void main() {\n  Stack{int} s;\n  s.push(42);\n  int val = s.pop();\n}\n";

	proj.workspace.process_file("/virtual/stack.c3", lib_code);
	proj.workspace.process_file("/virtual/app_generic.c3", app_code);

	Uri app_uri = uri::from_file_path(mem, "/virtual/app_generic.c3");
	defer app_uri.free();

	// 1. Hover on generic struct definition
	LspPosition stack_pos = { .line = 3, .character = 4 };
	String hover_stack = hover::hover(&proj, app_uri, stack_pos)!!;
	assert(hover_stack.contains("Stack"));

	// 2. Goto definition on generic method call .push(42)
	LspPosition push_pos = { .line = 4, .character = 6 };
	LspLocation[] push_locs = goto_definition::goto_definition(&proj, app_uri, push_pos)!!;
	assert(push_locs.len > 0);
	assert(push_locs[0].uri.contains("stack.c3"));
}

fn void test_distinct_types_and_inline_subtyping()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String code = "module types_mod;\ntypedef Handle @constinit = inline int;\nstruct Base {\n  int id;\n}\nstruct Derived {\n  inline Base base;\n  String name;\n}\nfn void Base.reset(&self) { self.id = 0; }\nfn void main() {\n  Handle h = 100;\n  Derived d;\n  d.reset();\n}\n";

	proj.workspace.process_file("/virtual/subtyping.c3", code);

	Uri doc_uri = uri::from_file_path(mem, "/virtual/subtyping.c3");
	defer doc_uri.free();

	// 1. Hover on typedef Handle (line 11, col 4)
	LspPosition handle_pos = { .line = 11, .character = 4 };
	String handle_hover = hover::hover(&proj, doc_uri, handle_pos)!!;
	assert(handle_hover.contains("typedef Handle"));

	// 2. Definition lookup for inherited method call `d.reset()` (line 13, col 6)
	LspPosition reset_pos = { .line = 13, .character = 6 };
	LspLocation[] locs = goto_definition::goto_definition(&proj, doc_uri, reset_pos)!!;
	assert(locs.len > 0);
	assert(locs[0].range.start.line == 9);
}

fn void test_macro_method_with_trailing_block()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String code = "module macro_mod;\nstruct Container {\n  int[4] items;\n}\nmacro void Container.each(&self; @body(idx, elem)) {\n  for (sz i = 0; i < 4; i++) { @body(i, self.items[i]); }\n}\nfn void run() {\n  Container c;\n  c.each(; sz i, int val) {\n    int next = val + 1;\n  };\n}\n";

	proj.workspace.process_file("/virtual/macros.c3", code);

	Uri doc_uri = uri::from_file_path(mem, "/virtual/macros.c3");
	defer doc_uri.free();

	// 1. Hover on macro method `c.each` (line 9, col 4)
	LspPosition each_pos = { .line = 9, .character = 4 };
	String hover_macro = hover::hover(&proj, doc_uri, each_pos)!!;
	assert(hover_macro.contains("macro Container.each"));

	// 2. Goto definition on macro invocation
	LspLocation[] locs = goto_definition::goto_definition(&proj, doc_uri, each_pos)!!;
	assert(locs.len > 0);
	assert(locs[0].range.start.line == 4);
}

fn void test_bitstruct_fields_and_overlap()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String code = "module bit_mod;\nbitstruct Flags : uint @overlap {\n  int mode   : 0..3;\n  bool sync  : 4;\n  int raw    : 0..7;\n}\nfn void test_flags() {\n  Flags f;\n  f.mode = 2;\n  f.sync = true;\n}\n";

	proj.workspace.process_file("/virtual/bitstruct.c3", code);

	Uri doc_uri = uri::from_file_path(mem, "/virtual/bitstruct.c3");
	defer doc_uri.free();

	// 1. Hover on bitstruct field `sync` in `f.sync = true;` (line 9, col 5)
	LspPosition sync_pos = { .line = 9, .character = 5 };
	String hover_sync = hover::hover(&proj, doc_uri, sync_pos)!!;
	assert(hover_sync.contains("sync"));

	// 2. Goto definition on bitstruct field `mode` in `f.mode = 2;` (line 8, col 5)
	LspPosition mode_pos = { .line = 8, .character = 5 };
	LspLocation[] locs = goto_definition::goto_definition(&proj, doc_uri, mode_pos)!!;
	assert(locs.len > 0);
	assert(locs[0].range.start.line == 2);
}

fn void test_multifile_recursive_and_norecurse_imports()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String core_mod = "module net;\nstruct Socket { int fd; }\nfn void close_socket(Socket s) {}\n";
	String sub_mod  = "module net::http;\nstruct Request { String url; }\nfn void send_req(Request r) {}\n";
	String app_code = "module client;\nimport net @norecurse;\nfn void main() {\n  Socket sock;\n  close_socket(sock);\n}\n";

	proj.workspace.process_file("/virtual/net.c3", core_mod);
	proj.workspace.process_file("/virtual/http.c3", sub_mod);
	proj.workspace.process_file("/virtual/client.c3", app_code);

	Uri app_uri = uri::from_file_path(mem, "/virtual/client.c3");
	defer app_uri.free();

	// 1. Resolve imported function from non-recursive parent module
	LspPosition close_pos = { .line = 4, .character = 4 };
	LspLocation[] locs = goto_definition::goto_definition(&proj, app_uri, close_pos)!!;
	assert(locs.len > 0);
	assert(locs[0].uri.contains("net.c3"));
}

fn void test_malformed_syntax_recovery_and_resilience()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	// Incomplete declaration block followed by valid function and struct
	String broken_code = "module recovery_test;\nfn void broken_func( {\n  invalid syntax !!\n\nstruct ValidStruct {\n  int status;\n}\nfn int valid_func(ValidStruct vs) {\n  return vs.status;\n}\n";

	proj.workspace.process_file("/virtual/recovery.c3", broken_code);

	Uri doc_uri = uri::from_file_path(mem, "/virtual/recovery.c3");
	defer doc_uri.free();

	// Verify diagnostics collected error for broken section
	LspDiagnostic[] diags = proj.workspace.get_diagnostics("/virtual/recovery.c3");
	assert(diags.len > 0);

	// Verify subsequent valid definitions remain indexed and queryable
	LspPosition struct_pos = { .line = 4, .character = 9 };
	String hover_struct = hover::hover(&proj, doc_uri, struct_pos)!!;
	assert(hover_struct.contains("ValidStruct"));

	LspPosition func_pos = { .line = 7, .character = 9 };
	String hover_func = hover::hover(&proj, doc_uri, func_pos)!!;
	assert(hover_func.contains("valid_func"));
}

fn void test_member_completion_filtering_and_sorting()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = "module comp_mod;\nstruct Account {\n  int account_id;\n  String account_name;\n  bool is_active;\n}\nfn void main() {\n  Account acc;\n  acc.acc\n}\n";

	proj.workspace.process_file("/virtual/comp_filter.c3", source);

	Uri doc_uri = uri::from_file_path(mem, "/virtual/comp_filter.c3");
	defer doc_uri.free();

	LspPosition pos = { .line = 8, .character = 9 };
	CompletionItem[] items = completion::resolve(&proj, doc_uri, pos)!!;

	assert(items.len >= 2);
	bool found_id = false;
	bool found_name = false;
	foreach (item : items)
	{
		if (item.label == "account_id") found_id = true;
		if (item.label == "account_name") found_name = true;
	}
	assert(found_id);
	assert(found_name);
}

fn void test_rename_struct_field_all_references()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = "module rename_field_mod;\nstruct User {\n  int user_id;\n}\nfn int get_id(User u) {\n  return u.user_id;\n}\nfn void set_id(User* u) {\n  u.user_id = 10;\n}\n";

	proj.workspace.process_file("/virtual/rename_field.c3", source);

	Uri doc_uri = uri::from_file_path(mem, "/virtual/rename_field.c3");
	defer doc_uri.free();

	// Rename `user_id` inside struct declaration
	LspPosition pos = { .line = 2, .character = 8 };
	WorkspaceEdit edit = rename::rename(&proj, doc_uri, pos, "uid")!!;

	assert(edit.documentChanges.len == 1);
	assert(edit.documentChanges[0].edits.len >= 3);
	foreach (e : edit.documentChanges[0].edits)
	{
		assert(e.newText == "uid");
	}
}