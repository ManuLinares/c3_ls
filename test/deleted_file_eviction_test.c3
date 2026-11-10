module lsp::deleted_file_eviction_test @test;

import lsp, uri, std::io;

fn void test_deleted_dependency_eviction_and_definition_guard()
{
	Path? tmp_dir = path::temp_directory(tmem);
	if (catch tmp_dir) return;

	Path test_dir = tmp_dir.tappend("c3_ls_evict_test")!!;
	Path lib_dir = test_dir.tappend("lib")!!;
	(void)path::mkdir(lib_dir, recursive: true);
	defer (void)path::rmtree(test_dir);

	Path dep_path = lib_dir.tappend("temp_dep.c3")!!;
	file::save(dep_path, "module temp_dep;\nfn void dep_func() {}\n")!!;

	Path main_path = test_dir.tappend("main.c3")!!;
	file::save(main_path, "module app;\nimport temp_dep;\nfn void main() {\n  temp_dep::dep_func();\n}\n")!!;

	LspProject proj;
	proj.init(mem);
	defer proj.free();

	Uri dep_uri = uri::from_file_path(mem, (String)dep_path);
	defer dep_uri.free();
	proj.open_file({ .uri = (DocumentUri)dep_uri.to_raw_string(tmem) }, from_disk: true);

	Uri main_uri = uri::from_file_path(mem, (String)main_path);
	defer main_uri.free();
	String main_source = (String)file::load(tmem, main_path)!!;
	proj.open_file({ .uri = (DocumentUri)main_uri.to_raw_string(tmem), .text = main_source }, from_disk: false);
	proj.update();

	// 1. Initially valid: 0 diagnostics, goto-definition resolves to temp_dep.c3
	LspDiagnostic[] diags = proj.workspace.get_diagnostics((String)main_path);
	assert(diags.len == 0);

	LspPosition call_pos = { .line = 3, .character = 14 };
	LspLocation[] locs = definition::goto_definition(&proj, main_uri, call_pos)!!;
	assert(locs.len > 0);
	assert(locs[0].uri.contains("temp_dep.c3"));

	// 2. Delete lib directory externally (simulating `rm -rf lib`)
	(void)path::rmtree(lib_dir);

	// 3. Next edit/update in main.c3
	TextDocumentContentChangeEvent[1] changes = {
		{ .text = "module app;\nimport temp_dep;\nfn void main() {\n  temp_dep::dep_func(); // edit\n}\n" }
	};
	proj.change_file({
		.document = { .uri = (DocumentUri)main_uri.to_raw_string(tmem), .version = 2 },
		.content_changes = &changes
	});
	proj.update();

	// 4. Diagnostic "No module 'temp_dep' found" is restored immediately
	LspDiagnostic[] new_diags = proj.workspace.get_diagnostics((String)main_path);
	assert(new_diags.len > 0);
	assert(new_diags[0].message.contains("No module 'temp_dep' found"));
}
macro String file_uri(Path path) => uri::from_file_path(tmem, (String)path).to_raw_string(tmem);
macro String file_key(Path path) => uri::from_file_path(tmem, (String)path).path;

fn void test_file_text_lifecycle_frees_everything()
{
	Path dir = path::temp_directory(tmem)!!.tappend("c3_ls_text_lifecycle_test")!!;
	(void)path::rmtree(dir);
	(void)path::mkdir(dir.tappend("lib")!!, recursive: true);
	defer (void)path::rmtree(dir);
	Path main_path = dir.tappend("main.c3")!!;
	Path dep_path = dir.tappend("lib")!!.tappend("dep.c3")!!;
	file::save(main_path, "module app;\n")!!;
	file::save(dep_path, "module dep;\n")!!;

	LspProject proj;
	proj.init(mem);
	defer proj.free();

	proj.open_file({ .uri = file_uri(main_path) }, from_disk: true);
	proj.open_file({ .uri = file_uri(main_path), .text = "module app;\nfn void f() {}\n" });
	TextDocumentContentChangeEvent[1] empty = { { .text = "" } };
	proj.change_file({ .document = { .uri = file_uri(main_path), .version = 2 }, .content_changes = &empty });
	TextDocumentContentChangeEvent[1] full = { { .text = "module app;\n" } };
	proj.change_file({ .document = { .uri = file_uri(main_path), .version = 3 }, .content_changes = &full });
	proj.close_document(file_uri(main_path));
	assert(proj.files.has_key(file_key(main_path)));

	proj.open_file({ .uri = file_uri(dep_path), .text = "module dep;\n" });
	proj.update();
	proj.close_file(file_uri(dir.tappend("lib")!!));
	assert(!proj.files.has_key(file_key(dep_path)));
}

fn void test_evicting_directory_clears_c3c_diagnostics()
{
	Path dir = path::temp_directory(tmem)!!.tappend("c3_ls_evict_diag_test")!!;
	(void)path::rmtree(dir);
	(void)path::mkdir(dir.tappend("lib")!!, recursive: true);
	defer (void)path::rmtree(dir);
	Path dep_path = dir.tappend("lib")!!.tappend("dep.c3")!!;
	file::save(dep_path, "module dep;\n")!!;

	LspProject proj;
	proj.init(mem);
	defer proj.free();

	proj.open_file({ .uri = file_uri(dep_path), .text = "module dep;\n" });
	proj.workspace.add_c3c_diagnostic(file_key(dep_path), { .message = "stale".copy(mem) });
	proj.close_file(file_uri(dir.tappend("lib")!!));
	assert(proj.workspace.get_diagnostics(file_key(dep_path)).len == 0);
}
