module faultdef_syntax_tests;

import analyzer::core;
import diag_capture;

fn void valid_fault_forms_not_reported() @test
{
	Diag[] errs = diag_capture::errors_for(`module t;
faultdef ONE, TWO;
excuse THREE, FOUR;
excuse { FIVE, SIX }
excuse
{
	SEVEN,
	EIGHT,
}
`);
	assert(errs.len == 0, "%s", errs);
}

fn void named_fault_block_reported() @test
{
	Diag[] errs = diag_capture::errors_for("module t;\nexcuse NamedSet { NAMED_ONE, NAMED_TWO }\n");
	assert(errs.len == 1, "%s", errs);
}

fn void semicolon_after_fault_block_reported() @test
{
	Diag[] errs = diag_capture::errors_for("module t;\nexcuse { NAMED_ONE, NAMED_TWO };\n");
	assert(errs.len == 1, "%s", errs);
}
