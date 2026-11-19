module lsp::primitive_table_test;

import analyzer, lsp::analysis::macro_expand, std::collections::list;

struct AccessFinder
{
	String text;
	Node* found;
}

fn ChildVisitResult find_access(Node* c, Node* p, void* data)
{
	AccessFinder* f = data;
	if (c && c.kind == ACCESS_EXPR && string::tformat("%s::%s", cursor::spelling(c.as(AccessExpr).left, tmem), cursor::spelling(c.as(AccessExpr).member, tmem)) == f.text) f.found = c;
	return RECURSE;
}

<*
 Compile-time value of `expr`, written as `<expr>;` statements of a function, for `target`.
*>
macro String eval_for(Target target, String expr)
{
	AnalyzerContext* context = context::create(tmem, target);
	String src = string::tformat("module t;\nmacro f()\n{\n\tvar x = %s;\n}\n", expr);
	assert(context::process(context, src, "prim.c3"));
	SourceFile* sf = context.files.get("prim.c3")!!;
	AccessFinder finder = { .text = expr };
	foreach (stmt : sf.ast.statements) if (stmt) cursor::visit(stmt, null, { .on_enter = &find_access }, &finder);
	assert(finder.found, "no access %s", expr);
	return macro_expand::evaluate_compile_time(context, sf, finder.found);
}

const Target X64 = { .os = LINUX, .arch = X86_64 };
const Target X32 = { .os = LINUX, .arch = X86 };

fn void pointer_sized_types_follow_the_target() @test
{
	test::eq(eval_for(X64, "sz::size"), "8 (bytes)");
	test::eq(eval_for(X32, "sz::size"), "4 (bytes)");
	test::eq(eval_for(X64, "usz::max"), "18446744073709551615");
	test::eq(eval_for(X32, "usz::max"), "4294967295");
	test::eq(eval_for(X32, "iptr::min"), "-2147483648");
}

fn void default_target_has_pointer_size() @test
{
	test::eq(eval_for({}, "uptr::size"), string::tformat("%d (bytes)", arch::ptr_size(arch::current())));
}

fn void limits_of_128_bit_integers() @test
{
	test::eq(eval_for(X64, "int128::min"), "-170141183460469231731687303715884105728");
	test::eq(eval_for(X64, "int128::max"), "170141183460469231731687303715884105727");
	test::eq(eval_for(X64, "uint128::max"), "340282366920938463463374607431768211455");
}

fn void every_primitive_type_has_a_size() @test
{
	test::eq(eval_for(X64, "float16::size"), "2 (bytes)");
	test::eq(eval_for(X64, "bfloat::size"), "2 (bytes)");
	test::eq(eval_for(X64, "float128::size"), "16 (bytes)");
	test::eq(eval_for(X64, "any::size"), "16 (bytes)");
	test::eq(eval_for(X32, "typeid::size"), "4 (bytes)");
}
