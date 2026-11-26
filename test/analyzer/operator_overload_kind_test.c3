module operator_overload_kind_test;

import analyzer, diag_capture;

macro OverloadKind overload_of(String params, String attribute)
{
	AnalyzerContext* context = context::create(tmem);
	String src = string::tformat("module t;\nstruct Vec { int x; }\nfn int Vec.op(%s) %s => 0;\n", params, attribute);
	assert(context::process(context, src, "ov.c3"));
	SourceFile* sf = context.files.get("ov.c3")!!;
	foreach (stmt : sf.ast.statements)
	{
		if (!stmt || stmt.kind != FN_DECL) continue;
		Node* expr = stmt.as(FnDecl).attributes[0].as(AttributeDecl).exprs[0];
		return expr.kind == OVERLOAD_EXPR ? expr.as(OverloadExpr).overload_kind : OverloadKind.UNKNOWN;
	}
	unreachable("no fn");
}

fn void divide_assign_overload() @test
{
	assert(overload_of("&self, int y", "@operator(/=)") == OV_DIVIDE_ASSIGN);
}

fn void len_overload() @test
{
	assert(overload_of("&self", "@operator(len)") == OV_LEN);
}


fn void derived_comparison_operator_reports_one_error() @test
{
	String src = "module t;\nstruct Foo { int a; }\nfn bool Foo.ne(self, Foo o) @operator(!=) => self.a != o.a;\n";
	Diag[] errs = diag_capture::errors_for(src);
	assert(errs.len == 1, "%s", errs);
}
