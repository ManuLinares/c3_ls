module lsp::feat_expression_test;
import lsp, analyzer::core, analyzer::sema::query;

<*
 Whether the function `name` declared in `source` is compiled with `features`.
*>
macro bool enabled(String source, String name, String[] features)
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();
	proj.workspace.process_file("/virtual/feat.c3", source);
	SourceFile* sf = proj.workspace.get_source_file_by_path("/virtual/feat.c3");
	foreach (stmt : sf.ast.statements)
	{
		if (stmt && stmt.kind == FN_DECL && stmt.as(FnDecl).name.text == name) return query::feat_enabled_with(proj.workspace.ctx, features, null, stmt);
	}
	unreachable("no function %s", name);
}

const String[2] LINUX = { "LINUX", "POSIX" };

fn void feature_operators_c3c_accepts() @test
{
	assert(enabled("module m;\nfn void f() @feat(LINUX & POSIX) {}\n", "f", &LINUX));
	assert(enabled("module m;\nfn void f() @feat(WIN32 | LINUX) {}\n", "f", &LINUX));
	assert(enabled("module m;\nfn void f() @feat(WIN32, LINUX) {}\n", "f", &LINUX));
	assert(enabled("module m;\nfn void f() @feat(!WIN32 & (LINUX)) {}\n", "f", &LINUX));
	assert(enabled("module m;\nfn void f() @feat(~WIN32) {}\n", "f", &LINUX), "c3c negates with any unary operator");
}

fn void expressions_c3c_rejects_never_hold() @test
{
	assert(!enabled("module m;\nfn void f() @feat(LINUX && POSIX) {}\n", "f", &LINUX), "&&");
	assert(!enabled("module m;\nfn void f() @feat(WIN32 || LINUX) {}\n", "f", &LINUX), "||");
	assert(!enabled("module m;\nfn void f() @feat(!(LINUX ^ WIN32)) {}\n", "f", &LINUX), "^");
	assert(!enabled("module m;\nfn void f() @feat(!linux) {}\n", "f", &LINUX), "lowercase name");
}
