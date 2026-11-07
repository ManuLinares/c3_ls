module literal_suffix_tests;

import analyzer::core;
import std::collections::list;

List{Range} lit_errors;

fn void record(SourceFile* file, Range range, DiagnosticLevel level, String message)
{
	if (level == ERROR && message.contains("valid literal")) lit_errors.push(range);
}

<* Number of invalid-literal errors reported for `src`. *>
fn sz literal_errors(String src)
{
	lit_errors.tinit();
	diagnostics::callback = &record;
	defer diagnostics::callback = null;
	AnalyzerContext* context = context::create(tmem);
	context::process(context, src, "lit.c3");
	return lit_errors.len();
}

fn void valid_suffixes_not_reported() @test
{
	sz n = literal_errors(`module t;
ulong a = 1u;
ulong b = 1UL;
ulong c = 1ull;
long d = 1l;
long e = 1LL;
uint f = 0xFFu;
uint g = 0b1u;
long h = 0o7l;
float i = 1f;
double j = 1d;
float k = 3.14f;
double l = 2e+10d;
float m = 0x1.Ap-2F;
double o = 1e5;
`);
	assert(n == 0, "%d", n);
}

fn void invalid_suffixes_reported() @test
{
	String[*] bad = { "3.14f32", "2e+10f64", "1.0f16", "1i32", "1u8", "1uz", "1fx", "1ulll" };
	foreach (lit : bad)
	{
		sz n = literal_errors(string::tformat("module t;\ndouble v = (double)%s;\n", lit));
		assert(n == 1, "%s: %d errors", lit, n);
		Range r = lit_errors[0];
		assert(r.start.line == 1 && r.start.column == 19 && r.end.column == 19 + lit.len,
			"%s: range %s", lit, r);
	}
}
