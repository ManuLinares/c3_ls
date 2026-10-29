module lsp::c3c_diagnostics_test @test;

import lsp::core;
import lsp::core::config;
import lsp;
import std::io;
import std::collections::list;
import std::collections::maybe;
import uri;

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
	proj.config.test_sources = maybe::value(test_srcs);

	test::eq(proj.is_test_source_file("/home/mb/project/src/app.c3"), false);
	test::eq(proj.is_test_source_file("/home/mb/project/test/app_test.c3"), true);

	test::eq(proj.get_c3c_target("/home/mb/project/src/app.c3"), "");

	proj.config.targets.init(mem);

	TargetConfig t1 = {};
	String[] t1_feats = alloc::alloc_array(mem, String, 1);
	t1_feats[0] = "OTHER_FEAT".copy(mem);
	t1.features = maybe::value(t1_feats);
	proj.config.targets["t1"] = t1;

	TargetConfig t2 = {};
	String[] t2_feats = alloc::alloc_array(mem, String, 1);
	t2_feats[0] = "LSP_TARGET".copy(mem);
	t2.features = maybe::value(t2_feats);
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
