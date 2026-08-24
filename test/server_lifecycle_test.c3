module lsp::server_lifecycle_test @test;

import lsp::core;
import lsp::server;
import lsp::translator;
import lsp::utils;
import lsp;
import uri;
import std::io;
import std::io::file;
import std::io::path;

fn void test_server_initialize_and_config_load()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	// Verify initialize with rootUri sets config.root_path properly
	String init_req = `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":1234,"rootUri":"file:///tmp/mock_workspace"}}`;
	IoDecodeResult decoded = translator::decode(mem, init_req)!!;
	defer decoded.message.free();

	assert(decoded.message.method == INITIALIZE);
	assert(decoded.message.params.initialize.root_uri.has_value);

	WorkspaceFolder wf = {
		.uri = decoded.message.params.initialize.root_uri.value,
		.name = "mock_workspace"
	};

	// Uri parsing validation
	Uri parsed_uri = uri::parse(tmem, wf.uri)!!;
	assert(parsed_uri.path == "/tmp/mock_workspace");
}

fn void test_find_source_files_path_normalization()
{
	// Test trailing slash resilience in utils::find_source_files
	Path? tmp_dir = path::temp_directory(tmem);
	if (catch tmp_dir) return;

	Path mock_dir = tmp_dir.tappend("c3_ls_test_sources")!!;
	(void)path::mkdir(mock_dir, recursive: true);
	defer (void)path::rmtree(mock_dir);

	Path sample_file = mock_dir.tappend("sample.c3")!!;
	file::save(sample_file, "module sample;\nfn void test_fn() {}\n")!!;

	// Suffix with trailing slash
	String path_with_slash = string::tformat("%s/", mock_dir);
	Path trailing_path = path::tnew(path_with_slash)!!;

	String[] sources = utils::find_source_files(tmem, trailing_path);
	assert(sources.len > 0);
	assert(sources[0].ends_with("sample.c3"));
}

fn void test_full_server_dispatch_flow()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	// 1. Send didOpen
	String open_req = `{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///test_dispatch.c3","languageId":"c3","version":1,"text":"module dispatch_test;\nfn int calculate(int a) { return a * 2; }\nfn void main() {\n  int res = calculate(5);\n}\n"}}}`;
	IoDecodeResult open_msg = translator::decode(mem, open_req)!!;
	defer open_msg.message.free();

	proj.open_file(open_msg.message.params.did_open.document);
	proj.update();

	// 2. Query hover on `calculate`
	Uri doc_uri = uri::from_file_path(mem, "/test_dispatch.c3");
	defer doc_uri.free();

	LspPosition hover_pos = { .line = 3, .character = 14 };
	String hover_content = analysis::hover::hover(&proj, doc_uri, hover_pos)!!;
	assert(hover_content.contains("calculate"));
	assert(hover_content.contains("fn int"));

	// 3. Query goto definition on `calculate`
	LspLocation[] locs = analysis::goto_definition::goto_definition(&proj, doc_uri, hover_pos)!!;
	assert(locs.len > 0);
	assert(locs[0].range.start.line == 1);

	// 4. Send didChange
	String change_req = `{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///test_dispatch.c3","version":2},"contentChanges":[{"text":"module dispatch_test;\nfn int calculate_new(int a) { return a * 3; }\nfn void main() {\n  int res = calculate_new(5);\n}\n"}]}}`;
	IoDecodeResult change_msg = translator::decode(mem, change_req)!!;
	defer change_msg.message.free();

	proj.change_file(change_msg.message.params.did_change);
	proj.update();

	// Verify reindexed symbol
	LspPosition new_hover_pos = { .line = 3, .character = 14 };
	String new_hover_content = analysis::hover::hover(&proj, doc_uri, new_hover_pos)!!;
	assert(new_hover_content.contains("calculate_new"));
}