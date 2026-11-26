module orelse_precedence_test;

import analyzer;

macro BinaryExpr* init_of(String statement)
{
	AnalyzerContext* context = context::create(tmem);
	String src = string::tformat("module t;\nfn int f(int b, int c)\n{\n\tint? a = b;\n\t%s\n\treturn 0;\n}\n", statement);
	assert(context::process(context, src, "p.c3"));
	SourceFile* sf = context.files.get("p.c3")!!;
	foreach (stmt : sf.ast.statements)
	{
		if (!stmt || stmt.kind != FN_DECL) continue;
		Node* decl = stmt.as(FnDecl).body.get()!!.as(CompoundStmt).statements[1];
		assert(decl.kind == VAR_DECL, "statement: %s", decl.kind);
		return decl.as(VarDecl).init_expr.get()!!.as(BinaryExpr);
	}
	unreachable("no fn");
}

fn void orelse_binds_tighter_than_additive() @test
{
	BinaryExpr* e = init_of("int x = a ?? b - c;");
	assert(e.op == OP_SUB, "top: %s", e.op);
	assert(e.left.kind == BINARY_EXPR && e.left.as(BinaryExpr).op == OP_ELSE);
}

fn void orelse_binds_looser_than_multiplicative() @test
{
	BinaryExpr* e = init_of("int y = a ?? b * c;");
	assert(e.op == OP_ELSE, "top: %s", e.op);
	assert(e.right.kind == BINARY_EXPR && e.right.as(BinaryExpr).op == OP_MULT);
}
