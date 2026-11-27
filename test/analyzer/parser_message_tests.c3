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

fn void unterminated_string_ends_at_line_end() @test
{
	String src = "module mytmp;\nfn void f(String s) {}\nfn void main()\n{\n\tf(\"Hello World!);\n\tString name = \"Stefanos\";\n\tf(name);\n}\n";
	Diag[] errs = diag_capture::errors_for(src);
	test::eq(errs[0].message, "The end of the line was reached while parsing the string. Did you forget (or accidentally add) a '\"' somewhere?");
	// Errors stay on the broken line; the lines after it are fine.
	foreach (err : errs) assert(err.range.start.line == 4, "%s", errs);
}

fn void unterminated_literals_report_c3c_messages() @test
{
	test::eq(first_error("module t;\nString s = \"abc"), "The end of the file was reached while parsing the string. Did you forget (or accidentally add) a '\"' somewhere?");
	test::eq(first_error("module t;\nchar c = 'a;\nint y = 1;\n"), "A line break is not allowed in a character literal.");
	test::eq(first_error("module t;\nchar c = 'a"), "The character literal did not terminate.");
	test::eq(first_error("module t;\nString s = `abc;\nint y = 1;\n"), "Reached the end of the file looking for the end of the raw string that starts here. Did you forget a '`' somewhere?");
	test::eq(first_error("module t;\nchar[] c = b64\"YWJj"), "The base64 string seems to be missing a terminating '\"'");
}

fn void missing_semicolon_reported_after_previous_token() @test
{
	// c3c: 5:11, right after `1`.
	Diag[] errs = diag_capture::errors_for("module t;\nfn void f(int a) {}\nfn void main()\n{\n\tint x = 1\n\tint y = 2;\n}\n");
	assert(errs.len >= 1, "no error");
	test::eq(errs[0].range.start.line, 4);
	test::eq(errs[0].range.start.column, 10);
}

fn void messages_show_source_spelling() @test
{
	test::eq(first_error("module t;\nfn void f(String s, int i) {}\nfn void main()\n{\n\tf(\"%s \", 1\n\tint[ a;\n}\n"), "Expected ')'.");
	test::eq(first_error("module t;\nfn void main()\n{\n\tint[ a;\n}\n"), "Expected ']'.");
	test::eq(first_error("module t;\nfn void main()\n{\n\tint x = );\n}\n"), "An expression was expected.");
	test::eq(first_error("module t;\nfn void main()\n{\n\tint x = 1\n}\n"), "Expected ';'.");
	test::eq(first_error("module t;\nfn void main()\n{\n\tint x = 1;\n"), "Expected '}'.");
	test::eq(first_error("module t;\ntypedef foo = int;\n"), "Names of types must start with an uppercase letter.");
}
