module parser_message_tests;
import diag_capture;

macro String first_error(String src) => diag_capture::errors_for(src)[0].message;

fn void short_body_missing_semicolon() @test
{
	test::eq(first_error("module t;\nfn int f() => 1 2;\n"), "Expected ';'");
}

fn void group_missing_rparen() @test
{
	test::eq(first_error("module t;\nint x = (1 2);\n"), "Expected ')'");
}

fn void expand_missing_lparen() @test
{
	test::eq(first_error("module t;\n$expand 1);\n"), "Expected '('");
}

fn void ct_if_missing_colon() @test
{
	test::eq(first_error("module t;\nfn void f()\n{\n\t$if true\n\t$endif\n}\n"), "Expected ':' after $if expression");
}

fn void label_missing_colon() @test
{
	foreach (stmt : (String[]){ "switch FOO (x) { default: }", "if FOO (x) {}", "while FOO (x) {}", "for FOO (;;) {}", "do FOO {} while (false);", "foreach FOO (y : z) {}" })
	{
		String src = string::tformat("module t;\nfn void f(int x, int[] z)\n{\n\t%s\n}\n", stmt);
		test::eq(first_error(src), "The name must be followed by a ':', did you forget it?");
	}
}
