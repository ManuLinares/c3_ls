module faultdef_syntax_tests;

import analyzer::core;
import std::collections::list;

List{String} fault_errors;

fn void record(SourceFile* file, Range range, DiagnosticLevel level, String message)
{
	if (level == ERROR) fault_errors.push(message.copy(tmem));
}

fn sz errors_for(String src)
{
	fault_errors.tinit();
	diagnostics::callback = &record;
	defer diagnostics::callback = null;
	AnalyzerContext* context = context::create(tmem);
	context::process(context, src, "faults.c3");
	return fault_errors.len();
}

fn void valid_fault_forms_not_reported() @test
{
	sz n = errors_for(`module t;
faultdef ONE, TWO;
excuse THREE, FOUR;
excuse { FIVE, SIX }
excuse
{
	SEVEN,
	EIGHT,
}
`);
	assert(n == 0, "%s", fault_errors);
}

fn void named_fault_block_reported() @test
{
	sz n = errors_for("module t;\nexcuse NamedSet { NAMED_ONE, NAMED_TWO }\n");
	assert(n == 1, "%s", fault_errors);
}

fn void semicolon_after_fault_block_reported() @test
{
	sz n = errors_for("module t;\nexcuse { NAMED_ONE, NAMED_TWO };\n");
	assert(n == 1, "%s", fault_errors);
}
