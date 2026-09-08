module lsp::interface_and_project_sync_test @test;

import lsp::core;
import lsp::core::config;
import lsp::analysis::completion;
import lsp;
import analyzer::core;
import analyzer::core::ast;
import analyzer::parser;
import uri;
import std::io;
import std::io::file;
import std::io::path;
import std::collections::list;
import std::collections::maybe;

<*
 Fix 1: Verifies interface methods AST population and recovery.
 Before the fix:
 - `node.methods` mistakenly cloned the parent interface list (`list`),
   so methods were either empty or populated with TypeExpr parent types.
 - Doc comments inside the interface body broke the recovery loop.
*>
fn void test_interface_methods_population_and_doc_comments()
{
	String source_code = `
		module test_iface;

		interface Printable {}
		interface Serializable {}

		interface Stream : Printable, Serializable
		{
			<* Flushes the buffer *>
			fn void flush();

			<* Closes the stream *>
			fn bool close(int code);
		}
	`;

	AnalyzerContext* context = context::create(tmem);
	bool success = context::process(context, source_code, "test_iface.c3");
	assert(success);

	Module* mod = context.modules.get("test_iface")!!;
	InterfaceDecl* stream_iface = null;

	foreach (node : mod.nodes)
	{
		if (node && node.kind == INTERFACE_DECL)
		{
			InterfaceDecl* id = node.as(InterfaceDecl);
			if (id.name && id.name.text == "Stream")
			{
				stream_iface = id;
				break;
			}
		}
	}

	assert(stream_iface != null);

	// 1. Parent interfaces must contain Printable and Serializable
	test::eq(stream_iface.interfaces.len, 2);
	test::eq(stream_iface.interfaces[0].as(TypeExpr).unresolved.name.text, "Printable");
	test::eq(stream_iface.interfaces[1].as(TypeExpr).unresolved.name.text, "Serializable");

	// 2. Methods must be populated with FnDecl* nodes, NOT the parent interface types
	test::eq(stream_iface.methods.len, 2);
	test::eq(stream_iface.methods[0].kind, NodeKind.FN_DECL);
	test::eq(stream_iface.methods[1].kind, NodeKind.FN_DECL);

	FnDecl* fn_flush = stream_iface.methods[0].as(FnDecl);
	test::eq(fn_flush.name.text, "flush");
	assert(@ok(fn_flush.contract.get()));

	FnDecl* fn_close = stream_iface.methods[1].as(FnDecl);
	test::eq(fn_close.name.text, "close");
	test::eq(fn_close.params.len, 1);
	assert(@ok(fn_close.contract.get()));
}

<*
 Fix 2: Verifies editor buffer precedence over workspace disk scans.
 Before the fix:
 - `LspProject.open_file` dropped didOpen notifications if the file was
   already registered during workspace initialization, causing completions
   and symbols to be missing on newly opened files until the first edit.
*>
fn void test_did_open_overrides_stale_workspace_scan()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String file_path = "/virtual/workspace_open_test.c3";
	Uri doc_uri = uri::from_file_path(mem, file_path);
	defer doc_uri.free();
	DocumentUri raw_uri = (DocumentUri)doc_uri.to_raw_string(tmem);

	// 1. Simulate workspace initialization scanning a file from disk
	// (Passed positionally so it compiles across both commits)
	proj.open_file({ .uri = raw_uri, .text = "module app;\n" }, true);
	proj.update();

	// Initially, `my_new_helper` does not exist
	List{SymbolEntry} initial_syms = proj.workspace.find_symbol_by_name("my_new_helper");
	test::eq(initial_syms.len(), 0);

	// 2. Editor sends `didOpen` with unsaved / newly loaded buffer content
	String editor_text = `module app;
fn void my_new_helper() {}
fn void run() {
  my_new_
}
`;
	proj.open_file({ .uri = raw_uri, .text = editor_text }, false);
	proj.update();

	// 3. The symbol from the editor buffer must now be analyzed and indexed
	List{SymbolEntry} updated_syms = proj.workspace.find_symbol_by_name("my_new_helper");
	assert(updated_syms.len() > 0);
	test::eq(updated_syms.get(0).node.kind, NodeKind.FN_DECL);

	// 4. Completions for `my_new_` must resolve immediately
	LspPosition pos = { .line = 3, .character = 9 };
	CompletionItem[] items = completion::resolve(&proj, doc_uri, pos)!!;
	bool found = false;
	foreach (item : items)
	{
		if (item.label == "my_new_helper") found = true;
	}
	assert(found);
}

<*
 Fix 3: Verifies library discovery matches dependency names against manifest `provides`.
 Before the fix:
 - `process_libs` guessed candidate file paths matching `dep_name.c3l`, failing when
   the library directory or archive was named differently (e.g. `vendor_sqlite.c3l`).
*>
fn void test_process_libs_matches_manifest_provides()
{
	Path? tmp_dir = path::temp_directory(tmem);
	if (catch tmp_dir) return;

	Path test_root = tmp_dir.tappend("c3_ls_lib_test")!!;
	Path lib_dir = test_root.tappend("lib")!!;
	// Folder name is "vendor_sqlite.c3l", but manifest provides "sqlite"
	Path vendor_lib = lib_dir.tappend("vendor_sqlite.c3l")!!;

	(void)path::mkdir(vendor_lib, recursive: true);
	defer (void)path::rmtree(test_root);

	// Write manifest.json with "provides": "sqlite"
	Path manifest_file = vendor_lib.tappend("manifest.json")!!;
	file::save(manifest_file, `{"provides": "sqlite", "sources": ["."]}`)!!;

	// Write dummy source file inside the library
	Path lib_src = vendor_lib.tappend("sqlite.c3")!!;
	file::save(lib_src, "module sqlite;\nfn void sqlite_init() {}\n")!!;

	// Set up project config with dependency "sqlite"
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	proj.config.root_path = ((String)test_root).copy(mem);
	String[] deps = alloc::alloc_array(mem, String, 1);
	deps[0] = "sqlite".copy(mem);
	proj.config.dependencies = maybe::value(deps);

	String[] search_paths = alloc::alloc_array(mem, String, 1);
	search_paths[0] = "lib".copy(mem);
	proj.config.dependency_search_paths = maybe::value(search_paths);

	// Process libraries and update
	proj.process_libs();
	proj.update();

	// Verify that sqlite_init was discovered and registered
	List{SymbolEntry} syms = proj.workspace.find_symbol_by_name("sqlite_init");
	assert(syms.len() > 0);
	test::eq(syms.get(0).node.kind, NodeKind.FN_DECL);
}

<*
 Issue: Type methods (`Vector2.scale`, `Vector2.reset`) should only be suggested
 on member access (`v.scale`), NEVER in bare global completion when typing
 inside a function body.
*>
fn void test_methods_excluded_from_bare_global_completion() @test
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String source = `module app;

struct Vector2 {
    float x;
    float y;
}

fn void free_helper_func() {}
fn void Vector2.scale(&self, float factor) {}
macro void Vector2.reset(&self) {}

fn void run() {
    
}
`;

	proj.workspace.process_file("/virtual/global_comp.c3", source);
	Uri doc_uri = uri::from_file_path(mem, "/virtual/global_comp.c3");
	defer doc_uri.free();

	// Line 12 (0-based) inside `run()` body: bare completion
	LspPosition pos = { .line = 12, .character = 4 };
	CompletionItem[] items = completion::resolve(&proj, doc_uri, pos)!!;

	bool found_helper = false;
	bool found_vector2 = false;
	bool found_scale = false;
	bool found_reset = false;

	foreach (item : items)
	{
		if (item.label == "free_helper_func") found_helper = true;
		if (item.label == "Vector2") found_vector2 = true;
		if (item.label == "scale") found_scale = true;
		if (item.label == "reset") found_reset = true;
	}

	assert(found_helper);
	assert(found_vector2);

	// FAILS on current code:
	// `scale` and `reset` are methods, but are currently leaked into global completion
	assert(!found_scale);
	assert(!found_reset);
}

<*
 Issue: In `change_file`, `input.path` and `input.uri` stored `lookup_key`
 (allocated in temporary memory `tmem`). When the `@pool()` that triggered
 `didChange` finishes, the memory is freed, corrupting the queued path
 when `proj.update()` later processes it.
*>
fn void test_change_file_path_survives_tmem_reset() @test
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	String file_path = "/virtual/change_path_test.c3";
	Uri doc_uri = uri::from_file_path(mem, file_path);
	defer doc_uri.free();
	DocumentUri raw_uri = (DocumentUri)doc_uri.to_raw_string(mem);
	defer raw_uri.free(mem);

	proj.open_file({ .uri = raw_uri, .text = "module app;\nfn void original_fn() {}\n" }, true);
	proj.update();

	LspFile* tracked = proj.files.get(file_path)!!;

	// 1. Simulate `didChange` executing inside a temporary pool that closes
	@pool()
	{
		TextDocumentContentChangeEvent[1] changes = {
			{ .text = "module app;\nfn void reindexed_fn() {}\n" }
		};
		proj.change_file({
			.document = { .uri = raw_uri, .version = 2 },
			.content_changes = &changes
		});
	}; // Pool closes here, invalidating any strings allocated in tmem!

	// Check 1: Pointer ownership
	// The path pushed to the queue MUST point to `tracked.uri.path.ptr` (persistent heap),
	// NOT to `tmem` which was just invalidated when the pool closed.
	// FAILS on current code: process_queue[0].path.ptr is pointing to tmem!
	test::eq(proj.process_queue[0].path.ptr, tracked.uri.path.ptr);
	test::eq(proj.process_queue[0].uri.ptr, tracked.uri.path.ptr);

	// 2. Thrash tmem to overwrite deallocated pool memory with 'X'
	@pool()
	{
		char[] garbage = mem::temp_array(char, 2048);
		for (sz i = 0; i < garbage.len; i++) garbage[i] = 'X';
	};

	// Check 2: String integrity after tmem reuse
	// FAILS on current code: process_queue[0].path has been overwritten with 'X's!
	test::eq(proj.process_queue[0].path, file_path);

	// 3. Process the queue and verify workspace file path lookup
	// FAILS on current code: SourceFile is registered under corrupted 'X' path,
	// causing get_source_file_by_path to return null!
	proj.update();
	SourceFile* sf = proj.workspace.get_source_file_by_path(file_path);
	assert(sf != null);
	test::eq(sf.path, file_path);
}

import lsp::core::cache;

<*
 Issue: `.lsp-cache` was created at the workspace root, showing up as an
 untracked directory in git status. It should reside under `build/.lsp-cache`
 where default C3 .gitignore rules automatically cover it.
*>
fn void test_cache_directory_located_in_build_folder() @test
{
	Path? tmp_dir = path::temp_directory(tmem);
	if (catch tmp_dir) return;

	Path mock_root = tmp_dir.tappend("mock_project_root")!!;
	(void)path::mkdir(mock_root, recursive: true);
	defer (void)path::rmtree(mock_root);

	Path? cache_path = cache::get_or_create_cache_dir((String)mock_root);
	assert(@ok(cache_path));

	String cache_str = (String)cache_path!!;

	// FAILS on current code:
	// Returns `.../mock_project_root/.lsp-cache` (does not contain "build")
	assert(cache_str.contains("build"));
}