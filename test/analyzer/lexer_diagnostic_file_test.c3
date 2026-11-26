module lexer_diagnostic_file_test;
import analyzer::core;

String reported_path @local;

fn void record(SourceFile* file, Range range, DiagnosticLevel level, String message) @local
{
	if (message != "This doesn't seem to be a valid literal.") return;
	reported_path = (file ? file.path : "").copy(mem);
}

fn void lexer_error_reports_its_own_file() @test
{
	AnalyzerContext* context = context::create(tmem);
	context::process(context, "module a;\nint y = 1;\n", "a.c3");

	diagnostics::callback = &record;
	defer diagnostics::callback = null;
	defer reported_path.free(mem);
	context::process(context, "module b;\nint x = 1abc;\n", "b.c3");

	test::eq(reported_path, "b.c3");
}

fn void lexer_error_on_reparsed_file() @test
{
	AnalyzerContext* context = context::create(tmem);
	context::process(context, "module b;\nint y = 1;\n", "b.c3");

	diagnostics::callback = &record;
	defer diagnostics::callback = null;
	defer reported_path.free(mem);
	context::process(context, "module b;\nint x = 1abc;\n", "b.c3");

	test::eq(reported_path, "b.c3");
}
