module bytes_literal_tests;

import analyzer::core;
import analyzer::core::ast;
import diag_capture;

fn char[] bytes_of(Module* mod, int node)
{
	LiteralExpr* lit = mod.nodes[node].as(VarDecl).init_expr.as(LiteralExpr);
	assert(lit.literal_kind == LiteralKind.BYTES_LITERAL);
	return lit.bytes;
}

fn void mixed_and_multiple_chunks_decode_separately() @test
{
	String src = `module test_bytes;
const char[] A = b64"SGVs" b64"bG8=" b64"IQ==";
const char[] B = x"48" b64"ZWxsbw==";
const char[] C = b64"SGVsbA" x"6f";
`;
	assert(diag_capture::errors_for(src).len == 0, "%s", diag_capture::errors_for(src));

	AnalyzerContext* context = context::create(tmem);
	context::process(context, src, "bytes.c3");
	Module* mod = context.modules.get("test_bytes")!!;
	assert((String)bytes_of(mod, 1) == "Hello!", "%s", bytes_of(mod, 1));
	assert((String)bytes_of(mod, 2) == "Hello", "%s", bytes_of(mod, 2));
	assert((String)bytes_of(mod, 3) == "Hello", "%s", bytes_of(mod, 3));
}

fn void invalid_chunk_reported_at_its_token() @test
{
	String[2] srcs = {
		"module t;\nchar[*] a = b64\"SGV\" b64\"sbG8=\";\n",
		"module t;\nchar[*] a = x\"12\" x\"345\";\n",
	};
	sz[2] second_chunk_col = { 21, 18 };
	foreach (i, src : srcs)
	{
		Diag[] errs = diag_capture::errors_for(src);
		assert(errs.len == 1, "%s", errs);
		assert(errs[0].range.start.line == 1 && errs[0].range.start.column == second_chunk_col[i], "%s", errs);
	}
}

fn void invalid_digit_reported_once() @test
{
	String[2] srcs = {
		"module t;\nchar[*] a = x\"1g\";\nint b = 1;\n",
		"module t;\nchar[*] a = b64\"S!Vs\";\nint b = 1;\n",
	};
	foreach (src : srcs)
	{
		Diag[] errs = diag_capture::errors_for(src);
		assert(errs.len == 1, "%s", errs);
		assert(errs[0].range.start.line == 1 && errs[0].range.start.column == 12, "%s", errs);
	}
}
