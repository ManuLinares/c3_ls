module lsp::macro_expansion_test;

import lsp, uri;

const String LIB = `
module lib;
macro int scale(int x, int factor = 10) => x * factor;
`;

const String APP = `
module app;
import lib;
macro float float[<*>].prod(float[<*>] x, float start = 1.0) => x[0] * start;
macro int Counter.bump(Counter* self, int by = 2) => self.n + by;
macro int square(x) => x * x;
macro int @sum(#list)
{
	int total;
	foreach (v : #list) total += v;
	return total;
}
macro void @twice(; @action)
{
	@action();
	@action();
}
struct Counter
{
	int n;
}
fn void main()
{
	float[<3>] v;
	Counter c;
	int[] nums;
	int x;
	float p = v.prod();
	int b = c.bump() + c.bump(by: 5);
	int s = lib::scale(3) + square(5 + 2) + @sum(nums);
	@twice()
	{
		x += 7;
	};
}
`;

<*
 Macro expansion shown when hovering the `nth` occurrence of `needle` in APP.
*>
fn String expansion_at(LspProject* proj, String needle, int nth = 0)
{
	sz index = APP.index_of(needle)!!;
	for (int i = 0; i < nth; i++) index += APP[index + 1..].index_of(needle)!! + 1;
	String before = APP[:index];
	sz line_start = (before.rindex_of_char('\n') ?? -1) + 1;
	LspPosition pos = { .line = (uint)before.count("\n"), .character = (uint)(index - line_start) };
	String h = hover::hover(proj, uri::from_file_path(tmem, "/virtual/app.c3"), pos) ?? "";
	return h[h.index_of("**Macro Expansion:**") ?? h.len..];
}

macro @with_project(; @body(LspProject* proj))
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();
	proj.workspace.process_file("/virtual/lib.c3", LIB);
	proj.workspace.process_file("/virtual/app.c3", APP);
	@body(&proj);
}

fn void expansion_passes_the_receiver_as_first_parameter() @test
{
	@with_project(; LspProject* proj)
	{
		assert(expansion_at(proj, "prod();").contains("v[0] * 1.0"));
		assert(expansion_at(proj, "bump() +").contains("c.n + 2"));
	};
}

fn void expansion_binds_named_and_default_arguments() @test
{
	@with_project(; LspProject* proj)
	{
		assert(expansion_at(proj, "bump(by: 5)").contains("c.n + 5"));
		assert(expansion_at(proj, "scale(3)").contains("3 * 10"));
	};
}

fn void expansion_keeps_argument_grouping() @test
{
	@with_project(; LspProject* proj)
	{
		assert(expansion_at(proj, "square(5 + 2)").contains("(5 + 2) * (5 + 2)"));
	};
}

fn void expansion_keeps_every_construct() @test
{
	@with_project(; LspProject* proj)
	{
		String e = expansion_at(proj, "@sum(nums)");
		assert(e.contains("foreach (v : nums)") && e.contains("total += v;"), "%s", e);
	};
}

fn void expansion_inserts_the_trailing_body() @test
{
	@with_project(; LspProject* proj)
	{
		String e = expansion_at(proj, "@twice()");
		assert(e.count("x += 7;") == 2, "%s", e);
		assert(!e.contains("};"), "%s", e);
	};
}
