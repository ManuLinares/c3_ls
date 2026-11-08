module lsp::analysis_scaling_test;

import lsp, uri, std::io, std::time;

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
	stdlib_fixture::@with_stdlib_project(; LspProject* proj)
	{
		NanoDuration small = time_processing(proj, generate_source(150));
		NanoDuration large = time_processing(proj, generate_source(600));

		// 4x the input: linear work gives a ratio near 4, quadratic near 16.
		double ratio = (double)large / (double)small;
		assert(ratio < 8.0, "4x input took %.1fx time (%s -> %s)", ratio, small, large);
	};
}

<* Valid C3 declaring `Item` and using it as a type `n` times. *>
fn String generate_item_uses(int n)
{
	DString out = dstring::temp();
	out.append("module refs;\nstruct Item { int x; }\n");
	for (int i = 0; i < n; i++)
	{
		out.appendf("fn Item f%d(Item a) { Item b = a; return b; }\n", i);
	}
	return out.str_view();
}

<* Best of 3 timings of find_references on `Item`; asserts every use is found. *>
fn NanoDuration time_references(int n)
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();
	String path = "/virtual/refs.c3";
	proj.workspace.process_file(path, generate_item_uses(n));
	Uri u = uri::from_file_path(tmem, path);

	NanoDuration best = (NanoDuration)long::max;
	for (int r = 0; r < 3; r++)
	{
		Clock start = clock::now();
		LspLocation[] locs = references::find_references(&proj, u, { .line = 1, .character = 8 }, { .includeDeclaration = true })!!;
		NanoDuration elapsed = start.mark();
		assert(locs.len == (sz)3 * n + 1, "%d references for n=%d", locs.len, n);
		if (elapsed < best) best = elapsed;
	}
	return best;
}

fn void references_time_grows_linearly() @test
{
	NanoDuration small = time_references(150);
	NanoDuration large = time_references(600);
	double ratio = (double)large / (double)small;
	assert(ratio < 8.0, "4x uses took %.1fx time (%s -> %s)", ratio, small, large);
}

<* Best of 3 timings of find_references on `Item` with `others` files that never mention it. *>
fn NanoDuration time_references_with_unrelated_files(int others)
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();
	String path = "/virtual/refs.c3";
	proj.workspace.process_file(path, generate_item_uses(150));
	for (int i = 0; i < others; i++)
	{
		DString src = dstring::temp();
		src.appendf("module other%d;\n", i);
		for (int j = 0; j < 40; j++) src.appendf("struct Thing%d { int x; }\nfn Thing%d g%d(Thing%d t) { return t; }\n", j, j, j, j);
		proj.workspace.process_file(string::tformat("/virtual/other%d.c3", i), src.str_view());
	}
	Uri u = uri::from_file_path(tmem, path);

	NanoDuration best = (NanoDuration)long::max;
	for (int r = 0; r < 3; r++)
	{
		Clock start = clock::now();
		LspLocation[] locs = references::find_references(&proj, u, { .line = 1, .character = 8 }, { .includeDeclaration = true })!!;
		NanoDuration elapsed = start.mark();
		assert(locs.len == 451, "%d references", locs.len);
		if (elapsed < best) best = elapsed;
	}
	return best;
}

fn void references_time_ignores_unrelated_files() @test
{
	NanoDuration small = time_references_with_unrelated_files(50);
	NanoDuration large = time_references_with_unrelated_files(200);
	double ratio = (double)large / (double)small;
	assert(ratio < 2.5, "4x unrelated files took %.1fx time (%s -> %s)", ratio, small, large);
}
