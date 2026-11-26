module lsp::c3c_diagnostics_test @test;

import lsp::core;
import lsp::core::config;
import lsp;
import std::io;
import std::collections::list;
import std::collections::maybe;
import uri;
import lsp::server;
import std::os::env;
import lsp::core::cache;
import lsp::analysis::code_actions;

fn void test_c3c_lsp_output_parsing()
{
	LspWorkspace ws;
	ws.init(mem);
	defer ws.free();

	String sample_output = `> BEGINLSP
> LSPERR|error|"/home/mb/project/src/main.c3"|1284|27|"A comma or '}' was expected here."
> LSPERR|warn|"/home/mb/project/src/main.c3"|712|2|"Warning message."
> LSPERR|note|"/home/mb/project/src/other.c3"|720|3|"Inlined from here."
> ENDLSP-OK
`;

	ws.parse_c3c_lsp_output(sample_output, "/home/mb/project");

	LspDiagnostic[] main_diags = ws.get_diagnostics("/home/mb/project/src/main.c3");
	test::eq(main_diags.len, 2);

	test::eq(main_diags[0].severity, 1);
	test::eq(main_diags[0].range.start.line, 1283u);
	test::eq(main_diags[0].range.start.character, 26u);
	test::eq(main_diags[0].message, "A comma or '}' was expected here.");
	test::eq(main_diags[0].source, "c3c");

	test::eq(main_diags[1].severity, 2);
	test::eq(main_diags[1].range.start.line, 711u);
	test::eq(main_diags[1].range.start.character, 1u);
	test::eq(main_diags[1].message, "Warning message.");

	LspDiagnostic[] other_diags = ws.get_diagnostics("/home/mb/project/src/other.c3");
	test::eq(other_diags.len, 1);
	test::eq(other_diags[0].severity, 4);
	test::eq(other_diags[0].range.start.line, 719u);
	test::eq(other_diags[0].range.start.character, 2u);
	test::eq(other_diags[0].message, "Inlined from here.");
}

fn void test_c3c_merge_analyzer_takes_precedence_on_overlap()
{
	LspWorkspace ws;
	ws.init(mem);
	defer ws.free();

	String file_path = "/home/mb/project/src/main.c3";

	String sample_output = `> BEGINLSP
> LSPERR|error|"/home/mb/project/src/main.c3"|10|5|"c3c error at 10:5"
> LSPERR|warn|"/home/mb/project/src/main.c3"|20|1|"c3c warning at 20:1"
> ENDLSP-OK
`;
	ws.parse_c3c_lsp_output(sample_output, "/home/mb/project");

	List{LspDiagnostic} analyzer_list;
	analyzer_list.init(ws.allocator);
	analyzer_list.push({
		.range = {
			.start = { .line = 9, .character = 4 },
			.end = { .line = 9, .character = 10 }
		},
		.severity = 1,
		.message = "analyzer error at 9:4".copy(ws.allocator),
		.source = "c3-analyzer"
	});
	ws.diagnostics.set(file_path, analyzer_list);

	LspDiagnostic[] merged = ws.get_diagnostics(file_path);
	test::eq(merged.len, 2);

	test::eq(merged[0].source, "c3-analyzer");
	test::eq(merged[0].message, "analyzer error at 9:4");

	test::eq(merged[1].source, "c3c");
	test::eq(merged[1].range.start.line, 19u);
}

fn void test_c3c_stale_errors_replaced_and_cleared_on_edit()
{
	LspWorkspace ws;
	ws.init(mem);
	defer ws.free();

	String run1 = `> BEGINLSP
> LSPERR|error|"/home/mb/project/src/file_a.c3"|5|2|"file a error"
> LSPERR|error|"/home/mb/project/src/file_b.c3"|8|4|"file b error"
> ENDLSP-OK
`;
	ws.parse_c3c_lsp_output(run1, "/home/mb/project");

	test::eq(ws.get_diagnostics("/home/mb/project/src/file_a.c3").len, 1);
	test::eq(ws.get_diagnostics("/home/mb/project/src/file_b.c3").len, 1);

	ws.clear_c3c_diagnostics_for_path("/home/mb/project/src/file_a.c3");
	test::eq(ws.get_diagnostics("/home/mb/project/src/file_a.c3").len, 0);
	test::eq(ws.get_diagnostics("/home/mb/project/src/file_b.c3").len, 1);

	String run2 = `> BEGINLSP
> LSPERR|error|"/home/mb/project/src/file_c.c3"|1|1|"file c error"
> ENDLSP-OK
`;
	ws.parse_c3c_lsp_output(run2, "/home/mb/project");

	test::eq(ws.get_diagnostics("/home/mb/project/src/file_a.c3").len, 0);
	test::eq(ws.get_diagnostics("/home/mb/project/src/file_b.c3").len, 0);
	test::eq(ws.get_diagnostics("/home/mb/project/src/file_c.c3").len, 1);
}

fn void test_c3c_target_and_command_selection()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();

	proj.config.root_path = "/home/mb/project".copy(mem);

	String[] srcs = alloc::alloc_array(mem, String, 1);
	srcs[0] = "src/**".copy(mem);
	proj.config.sources = srcs;

	String[] test_srcs = alloc::alloc_array(mem, String, 1);
	test_srcs[0] = "test/**".copy(mem);
	proj.config.test_sources = test_srcs;

	test::eq(proj.is_test_source_file("/home/mb/project/src/app.c3"), false);
	test::eq(proj.is_test_source_file("/home/mb/project/test/app_test.c3"), true);

	test::eq(proj.get_c3c_target("/home/mb/project/src/app.c3"), "");

	proj.config.targets.init(mem);

	TargetConfig t1 = {};
	String[] t1_feats = alloc::alloc_array(mem, String, 1);
	t1_feats[0] = "OTHER_FEAT".copy(mem);
	t1.features = t1_feats;
	proj.config.targets["t1"] = t1;

	TargetConfig t2 = {};
	String[] t2_feats = alloc::alloc_array(mem, String, 1);
	t2_feats[0] = "LSP_TARGET".copy(mem);
	t2.features = t2_feats;
	proj.config.targets["t2_target"] = t2;

	test::eq(proj.get_c3c_target("/home/mb/project/src/app.c3"), "t2_target");
}

fn void test_c3c_diagnostics_pool_lifetime()
{
	LspWorkspace ws;
	ws.init(mem);
	defer ws.free();

	@pool()
	{
		String sample_output = `> BEGINLSP
> LSPERR|error|"/home/mb/project/src/foo.c3"|10|5|"error message"
> ENDLSP-OK
`;
		ws.parse_c3c_lsp_output(sample_output, "/home/mb/project");
	};

	LspDiagnostic[] diags = ws.get_diagnostics("/home/mb/project/src/foo.c3");
	test::eq(diags.len, 1);
	test::eq(diags[0].message, "error message");
}

fn void test_c3c_inherits_environment() => @pool()
{
	$if env::POSIX:
		Path dir = path::temp_directory(tmem)!!.tappend("c3_ls_env_test")!!;
		(void)path::mkdir(dir, true);
		String root = (String)dir;
		String script = (String)dir.tappend("fake_c3c")!!;
		String main_file = string::tformat("%s/src/main.c3", root);
		file::save(script, string::tformat("#!/bin/sh\necho '> BEGINLSP'\necho \"> LSPERR|error|\\\"%s\\\"|1|1|\\\"$C3C_LIB\\\"\"\necho '> ENDLSP-OK'\n", main_file))!!;
		file::chmod(script, USER_READ | USER_WRITE | USER_EXEC)!!;
		defer (void)path::rmtree(dir);

		env::set_var("C3C_LIB", "/custom/lib");
		defer env::clear_var("C3C_LIB");
		String old_compiler = server::compiler_path.copy(tmem);
		server::set_compiler_path(script);
		defer server::set_compiler_path(old_compiler);

		LspProject proj;
		proj.init(mem);
		defer proj.free();
		proj.config.root_path = root.copy(mem);

		proj.run_c3c_diagnostics(main_file);

		LspDiagnostic[] diags = proj.workspace.get_diagnostics(main_file);
		test::eq(diags.len, 1);
		test::eq(diags[0].message, "/custom/lib");
	$endif
}

fn void test_c3c_diagnostic_covers_token()
{
	LspWorkspace ws;
	ws.init(mem);
	defer ws.free();

	ws.process_file("/home/mb/project/src/main.c3", "module t;\nfn void main()\n{\n\t\tint x = undefined_thing;\n}\n");
	ws.parse_c3c_lsp_output(`> BEGINLSP
> LSPERR|error|"/home/mb/project/src/main.c3"|4|11|"'undefined_thing' could not be found."
> LSPERR|error|"/home/mb/project/src/other.c3"|2|5|"Not loaded."
> ENDLSP-OK
`, "/home/mb/project");

	LspDiagnostic[] diags = ws.get_diagnostics("/home/mb/project/src/main.c3");
	test::eq(diags.len, 1);
	test::eq(diags[0].range.start.character, 10u);
	test::eq(diags[0].range.end.character, 25u);

	LspDiagnostic[] other = ws.get_diagnostics("/home/mb/project/src/other.c3");
	test::eq(other.len, 1);
	test::eq(other[0].range.start.character, 4u);
	test::eq(other[0].range.end.character, 5u);
}

<*
 Runs `run_c3c_diagnostics` for `file` in a project rooted at `root`, with a compiler that
 reports its own arguments as an error on `file`, and returns that message.
*>
macro String @c3c_args_for(String dir, String root, String file, String[] sources = {})
{
	String script = string::tformat("%s/fake_c3c", dir);
	file::save(script, string::tformat("#!/bin/sh\necho '> BEGINLSP'\necho \"> LSPERR|error|\\\"%s\\\"|1|1|\\\"$*\\\"\"\necho '> ENDLSP-OK'\n", file))!!;
	file::chmod(script, USER_READ | USER_WRITE | USER_EXEC)!!;
	String old_compiler = server::compiler_path.copy(tmem);
	server::set_compiler_path(script);
	defer server::set_compiler_path(old_compiler);

	LspProject proj;
	proj.init(mem);
	defer proj.free();
	if (root.len) proj.config.root_path = root.copy(mem);
	if (sources.len)
	{
		proj.config.sources = alloc::alloc_array(mem, String, sources.len);
		foreach (i, source : sources) proj.config.sources[i] = source.copy(mem);
	}
	proj.run_c3c_diagnostics(file);
	LspDiagnostic[] diags = proj.workspace.get_diagnostics(file);
	return diags.len == 1 ? diags[0].message.copy(tmem) : "";
}

fn void test_c3c_checks_stdlib_and_standalone_files() => @pool()
{
	$if env::POSIX:
		Path dir = path::temp_directory(tmem)!!.tappend("c3_ls_check_test")!!;
		(void)path::mkdir(dir.tappend("lib/std/io")!!, true);
		defer (void)path::rmtree(dir);
		String d = (String)dir;
		String old_std = server::std_path.copy(tmem);
		server::set_std_path(string::tformat("%s/lib/std", d));
		defer server::set_std_path(old_std);

		String stdlib_args = @c3c_args_for(d, "", string::tformat("%s/lib/std/io/formatter.c3", d));
		test::eq(stdlib_args, "compile -C - --lsp --warn-builtin=no");

		String lone = string::tformat("%s/lone.c3", d);
		test::eq(@c3c_args_for(d, "", lone), string::tformat("compile -C %s --lsp --warn-builtin=no", lone));

		String project_build = string::tformat("--path %s build --lsp --warn-builtin=no", d);
		String[] sources = { "src/**" };
		test::eq(@c3c_args_for(d, d, string::tformat("%s/src/main.c3", d), sources), project_build);
		test::eq(@c3c_args_for(d, d, string::tformat("%s/lib/dep.c3l/dep.c3", d), sources), project_build);
		test::eq(@c3c_args_for(d, d, string::tformat("%s/lib/std/io/formatter.c3", d), sources), project_build);

		// The trust level the user chose for the project, from its LSP cache folder.
		cache::save_trust_level(d, "include")!!;
		test::eq(@c3c_args_for(d, d, string::tformat("%s/src/main.c3", d), sources), string::tformat("--path %s build --lsp --warn-builtin=no --trust=include", d));
		(void)file::delete(string::tformat("%s/build/.lsp-cache/.trust", d));

		// A file in the project folder that its build does not compile is checked alone.
		String stray = string::tformat("%s/ahh.c3", d);
		test::eq(@c3c_args_for(d, d, stray, sources), string::tformat("compile -C %s --lsp --warn-builtin=no", stray));
	$endif
}

fn void test_c3c_run_closes_handles() => @pool()
{
	$if env::LINUX:
		Path dir = path::temp_directory(tmem)!!.tappend("c3_ls_handle_test")!!;
		(void)path::mkdir(dir, true);
		defer (void)path::rmtree(dir);
		String file = string::tformat("%s/lone.c3", (String)dir);
		sz before = path::ls(tmem, path::tnew("/proc/self/fd")!!)!!.len();
		for (int i = 0; i < 3; i++) (void)@c3c_args_for((String)dir, "", file);
		test::eq(path::ls(tmem, path::tnew("/proc/self/fd")!!)!!.len(), before);
	$endif
}

fn void test_stdlib_save_shows_project_build_errors() => @pool()
{
	$if env::POSIX:
		Path dir = path::temp_directory(tmem)!!.tappend("c3_ls_stdlib_save_test")!!;
		(void)path::rmtree(dir);
		(void)path::mkdir(dir.tappend("lib/std")!!, true);
		(void)path::mkdir(dir.tappend("proj/src")!!, true);
		defer (void)path::rmtree(dir);
		String d = (String)dir;
		String lib_file = string::tformat("%s/lib/std/set.c3", d);
		String main_file = string::tformat("%s/proj/src/main.c3", d);
		file::save(lib_file, "module std::set <Value>;\nstruct Set { Value v; }\n")!!;
		file::save(main_file, "module app;\nfn void main() {}\n")!!;
		file::save(string::tformat("%s/proj/project.json", d), `{ "sources": [ "src/**" ] }`)!!;

		// Only a project build reports the generic stdlib module, as c3c checks it only where used.
		String script = string::tformat("%s/fake_c3c", d);
		file::save(script, string::tformat("#!/bin/sh\necho '> BEGINLSP'\ncase \"$*\" in *--path*)\necho '> LSPERR|error|\"%s\"|2|21|\"Bad generic.\"'\necho '> LSPERR|note|\"%s\"|2|1|\"Instantiated here.\"';;\nesac\necho '> ENDLSP-OK'\n", lib_file, main_file))!!;
		file::chmod(script, USER_READ | USER_WRITE | USER_EXEC)!!;
		String old_compiler = server::compiler_path.copy(tmem);
		server::set_compiler_path(script);
		defer server::set_compiler_path(old_compiler);
		String old_std = server::std_path.copy(tmem);
		server::set_std_path(string::tformat("%s/lib/std", d));
		defer server::set_std_path(old_std);

		server::project_manager.init(mem);
		defer server::project_manager.free();
		server::project_manager.add_workspace_folder({ .uri = (LspUri)uri::from_file_path(tmem, string::tformat("%s/proj", d)).to_raw_string(tmem) });
		LspProject* lib_owner = &server::project_manager.default_project;
		String lib_uri = uri::from_file_path(tmem, lib_file).to_raw_string(tmem);
		lib_owner.open_file({ .uri = lib_uri, .language_id = "c3", .version = 1, .text = (String)file::load_temp(lib_file)!! });
		lib_owner.save_file(lib_uri);

		LspDiagnostic[] lib_diags = server::diagnostics_for_path(lib_file, &lib_owner.workspace);
		test::eq(lib_diags.len, 1);
		test::eq(lib_diags[0].message, "Bad generic.");
		LspDiagnostic[] main_diags = server::diagnostics_for_path(main_file, &lib_owner.workspace);
		test::eq(main_diags.len, 1);
		test::eq(main_diags[0].message, "Instantiated here.");

		// Editing the file drops c3c's errors on it, whichever project's build reported them.
		lib_owner.change_file({ .document = { .uri = lib_uri, .version = 2 }, .content_changes = { { .text = "module std::set <Value>;\nstruct Set { Value w; }\n" } } });
		test::eq(server::diagnostics_for_path(lib_file, &lib_owner.workspace).len, 0);
	$endif
}

fn void test_c3c_lsp2_span()
{
	LspWorkspace ws;
	ws.init(mem);
	defer ws.free();

	ws.parse_c3c_lsp_output(`> BEGINLSP
> LSPERR|error|"/home/mb/project/src/main.c3"|5|2|11|"'io::prinatn' could not be found."
> ENDLSP-ERROR
`, "/home/mb/project");

	LspDiagnostic[] diags = ws.get_diagnostics("/home/mb/project/src/main.c3");
	test::eq(diags.len, 1);
	test::eq(diags[0].message, "'io::prinatn' could not be found.");
	test::eq(diags[0].range.start.character, 1u);
	test::eq(diags[0].range.end.character, 12u);
}

fn void test_c3c_uses_lsp2_when_supported() => @pool()
{
	$if env::POSIX:
		Path dir = path::temp_directory(tmem)!!.tappend("c3_ls_lsp2_test")!!;
		(void)path::rmtree(dir);
		(void)path::mkdir(dir, true);
		defer (void)path::rmtree(dir);
		String file = string::tformat("%s/lone.c3", (String)dir);
		String script = string::tformat("%s/fake_c3c", (String)dir);
		file::save(script, string::tformat("#!/bin/sh\ncase \"$1\" in --help) echo '  --lsp2   Like --lsp.';; *) echo '> BEGINLSP'\necho \"> LSPERR|error|\\\"%s\\\"|1|1|\\\"$*\\\"\"\necho '> ENDLSP-OK';; esac\n", file))!!;
		file::chmod(script, USER_READ | USER_WRITE | USER_EXEC)!!;
		String old_compiler = server::compiler_path.copy(tmem);
		server::set_compiler_path(script);
		defer server::set_compiler_path(old_compiler);

		LspProject proj;
		proj.init(mem);
		defer proj.free();
		proj.run_c3c_diagnostics(file);
		LspDiagnostic[] diags = proj.workspace.get_diagnostics(file);
		test::eq(diags.len, 1);
		test::eq(diags[0].message, string::tformat("compile -C %s --lsp2 --warn-builtin=no", file));
	$endif
}

fn void test_trust_level_file() => @pool()
{
	Path dir = path::temp_directory(tmem)!!.tappend("c3_ls_trust_test")!!;
	(void)path::rmtree(dir);
	(void)path::mkdir(dir, true);
	defer (void)path::rmtree(dir);
	String root = (String)dir;

	test::eq(cache::trust_level(root), "");
	cache::save_trust_level(root, "full")!!;
	test::eq(cache::trust_level(root), "full");
	file::save(string::tformat("%s/build/.lsp-cache/.trust", root), "everything")!!;
	test::eq(cache::trust_level(root), "");
}

fn void test_trust_error_offers_quick_fix() => @pool()
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();
	proj.config.root_path = "/home/mb/project".copy(mem);
	Uri doc_uri = uri::from_file_path(tmem, "/home/mb/project/src/main.c3");

	LspDiagnostic[] diags = {
		{ .severity = 1, .source = "c3c", .message = "'$include' not permitted, trust level must be set to '--trust=include' or '--trust=full' to permit it." },
		{ .severity = 1, .source = "c3c", .message = "'$exec' not permitted, trust level must be set to '--trust=full' to permit it." },
	};
	CodeAction[] actions = code_actions::get_code_actions(&proj, doc_uri, { .context = { .diagnostics = diags } })!!;
	test::eq(actions.len, 2);
	test::eq(actions[0].command.command, code_actions::CMD_SET_TRUST);
	test::eq(actions[0].command.arguments[0], "/home/mb/project");
	test::eq(actions[0].command.arguments[1], "include");
	test::eq(actions[0].command.arguments[2], doc_uri.to_raw_string(tmem));
	test::eq(actions[1].command.arguments[1], "full");
}
