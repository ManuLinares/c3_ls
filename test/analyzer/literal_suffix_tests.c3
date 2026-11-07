module literal_suffix_tests;

import analyzer::core;
import std::collections::list;
import diag_capture;

<* Invalid-literal errors reported for `src`. *>
fn Diag[] literal_errors(String src)
{
	List{Diag} out;
	out.tinit();
	foreach (d : diag_capture::errors_for(src))
	{
		if (d.message.contains("valid literal")) out.push(d);
	}
	return out.array_view();
}

fn void valid_suffixes_not_reported() @test
{
	Diag[] errs = literal_errors(`module t;
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
	assert(errs.len == 0, "%s", errs);
}

fn void invalid_suffixes_reported() @test
{
	String[*] bad = { "3.14f32", "2e+10f64", "1.0f16", "1i32", "1u8", "1uz", "1fx", "1ulll" };
	foreach (lit : bad)
	{
		Diag[] errs = literal_errors(string::tformat("module t;\ndouble v = (double)%s;\n", lit));
		assert(errs.len == 1, "%s: %s", lit, errs);
		Range r = errs[0].range;
		assert(r.start.line == 1 && r.start.column == 19 && r.end.column == 19 + lit.len,
			"%s: range %s", lit, r);
	}
}
