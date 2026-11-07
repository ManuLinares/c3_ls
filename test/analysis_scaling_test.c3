module lsp::analysis_scaling_test;

import lsp, std::io, std::time;

<*
 Valid C3 with `n` declarations per kind: struct and function type
 references, stdlib types reached through an import and through std::core,
 and generic parameters of a module section.
*>
fn String generate_source(int n)
{
	DString out = dstring::temp();
	out.append("module perf;\nimport std::collections::list;\n");
	out.append("struct Item0 { int x; }\n");
	for (int i = 1; i < n; i++)
	{
		out.appendf("struct Item%d { Item%d inner; String name; }\n", i, i - 1);
	}
	for (int i = 0; i < n; i++)
	{
		out.appendf("fn void f%d(Item%d s, String str, List{int}* l, Allocator a) {}\n", i, i);
	}
	out.append("module perf::gen <Type>;\n");
	for (int i = 0; i < n; i++)
	{
		out.appendf("fn Type g%d(Type t, String s) => t;\n", i);
	}
	return out.str_view();
}

<* Best of `runs` timings of processing `src`; asserts it produces no diagnostics. *>
fn NanoDuration time_processing(LspProject* proj, String src, int runs = 3)
{
	String path = "/virtual/perf.c3";
	NanoDuration best = (NanoDuration)long::max;
	for (int r = 0; r < runs; r++)
	{
		Clock start = clock::now();
		proj.workspace.process_file(path, src);
		NanoDuration elapsed = start.mark();
		if (elapsed < best) best = elapsed;
	}
	LspDiagnostic[] diags = proj.workspace.get_diagnostics(path);
	assert(diags.len == 0, "%d diagnostics, first: %s", diags.len, diags.len ? diags[0].message : "");
	return best;
}

fn void analysis_time_grows_linearly() @test
{
	if (server::std_path.len == 0) server::setup_stdlib_path();
	defer
	{
		if (server::is_std_path_alloc)
		{
			server::std_path.free(mem);
			server::is_std_path_alloc = false;
			server::std_path = "";
		}
	};
	assert(server::std_path.len > 0, "stdlib path not found");

	LspProject proj;
	proj.init(mem);
	defer proj.free();
	proj.process_stdlib();
	proj.update();

	NanoDuration small = time_processing(&proj, generate_source(150));
	NanoDuration large = time_processing(&proj, generate_source(600));

	// 4x the input: linear work gives a ratio near 4, quadratic near 16.
	double ratio = (double)large / (double)small;
	assert(ratio < 8.0, "4x input took %.1fx time (%s -> %s)", ratio, small, large);
}
