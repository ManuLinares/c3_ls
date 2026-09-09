module lsp::code_action_test @test;

import lsp::core;
import lsp::analysis::code_actions;
import lsp;
import uri;
import std::io;
import std::collections::list;

fn void test_quick_fix_suggests_binding_generation_for_missing_module()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	// Temporary source file with an unresolved import
	String file_path = "/virtual/app_missing_zlib.c3";
	String source = "module app;\nimport zlib;\nfn void main() {}\n";

	proj.workspace.process_file(file_path, source);
	Uri doc_uri = uri::from_file_path(mem, file_path);
	defer doc_uri.free();

	LspDiagnostic[] diags = proj.workspace.get_diagnostics(file_path);
	assert(diags.len > 0);
	assert(diags[0].message.contains("No module 'zlib' found"));

	CodeActionParams ca_params = {
		.text_document = { .uri = doc_uri.to_raw_string(tmem) },
		.range = diags[0].range,
		.context = {
			.diagnostics = diags
		}
	};

	CodeAction[] actions = code_actions::get_code_actions(&proj, doc_uri, ca_params)!!;

	// On systems with /usr/include/zlib.h, a Quick Fix code action must be suggested
	if (file::exists("/usr/include/zlib.h"))
	{
		assert(actions.len > 0);
		CodeAction action = actions[0];
		assert(action.kind == "quickfix");
		assert(action.isPreferred);
		assert(action.title.contains("Generate C3 bindings for 'zlib'"));
		assert(action.command.command == "c3.generateBindings");
		assert(action.command.arguments.len == 3);
		assert(action.command.arguments[0].contains("zlib.h"));
		assert(action.command.arguments[1] == "zlib");
		assert(action.command.arguments[2].contains("zlib.c3i"));
	}
}

fn void test_quick_fix_discovers_prefixed_and_directory_headers() //TODO remove this test :(
{
	Path? tmp_dir = path::temp_directory(tmem);
	if (catch tmp_dir) return;

	Path mock_root = tmp_dir.tappend("c3_ls_mock_headers")!!;
	Path inc_dir = mock_root.tappend("include")!!;
	Path alsa_dir = inc_dir.tappend("alsa")!!;

	(void)path::mkdir(alsa_dir, recursive: true);
	defer (void)path::rmtree(mock_root);

	// Mock wayland-client.h, wayland-server.h
	file::save(inc_dir.tappend("wayland-client.h")!!, "void wl_client_connect();\n")!!;
	file::save(inc_dir.tappend("wayland-server.h")!!, "void wl_server_create();\n")!!;

	// Mock alsa/asoundlib.h, alsa/pcm.h
	file::save(alsa_dir.tappend("asoundlib.h")!!, "void snd_pcm_open();\n")!!;
	file::save(alsa_dir.tappend("pcm.h")!!, "void snd_pcm_read();\n")!!;

	LspProject proj;
	proj.init(mem);
	defer proj.free();
	proj.config.root_path = ((String)mock_root).copy(mem);

	// 1. Wayland discovery
	List{CandidateHeader} wl_cands = code_actions::find_candidate_c_headers(&proj, "wayland");
	assert(wl_cands.len() >= 2);
	bool found_client = false;
	bool found_server = false;
	foreach (c : wl_cands)
	{
		if (c.path.contains("wayland-client.h")) found_client = true;
		if (c.path.contains("wayland-server.h")) found_server = true;
	}
	assert(found_client);
	assert(found_server);

	// 2. ALSA directory discovery
	List{CandidateHeader} alsa_cands = code_actions::find_candidate_c_headers(&proj, "alsa");
	assert(alsa_cands.len() >= 2);
	bool found_asoundlib = false;
	bool found_pcm = false;
	foreach (c : alsa_cands)
	{
		if (c.path.contains("asoundlib.h")) found_asoundlib = true;
		if (c.path.contains("pcm.h")) found_pcm = true;
	}
	assert(found_asoundlib);
	assert(found_pcm);
}

fn void test_quick_fix_discovers_prefixed_and_directory_headers2()
{
	const int MIN_PREFIX_SCORE = 80;
	const int EXACT_MATCH_SCORE = 100;

	// 1. Wayland prefixed headers
	assert(code_actions::match_name_score("wayland", "wayland-client.h") >= MIN_PREFIX_SCORE);
	assert(code_actions::match_name_score("wayland", "wayland-server.h") >= MIN_PREFIX_SCORE);
	assert(code_actions::match_name_score("wayland", "wayland_egl.h") >= MIN_PREFIX_SCORE);

	// 2. Unrelated headers rejected
	test::eq(code_actions::match_name_score("wayland", "stdio.h"), 0);
	test::eq(code_actions::match_name_score("wayland", "window.h"), 0);

	// 3. Directory and library prefix matching
	test::eq(code_actions::match_name_score("alsa", "alsa"), EXACT_MATCH_SCORE);
	test::eq(code_actions::match_name_score("asound", "libasound.h"), EXACT_MATCH_SCORE);
	test::eq(code_actions::match_name_score("sdl", "SDL3.h"), 70);
	test::eq(code_actions::match_name_score("zlib", "zlib.h"), EXACT_MATCH_SCORE);

	// 4. Unrelated directories rejected
	test::eq(code_actions::match_name_score("alsa", "sys"), 0);
	test::eq(code_actions::match_name_score("alsa", "net"), 0);
}