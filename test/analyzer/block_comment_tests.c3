module block_comment_tests;

import diag_capture;

fn void unterminated_block_comment_runs_to_eof() @test
{
	Diag[] errs = diag_capture::errors_for(`module t;
fn void main() {}
/* open
foo bar
`);
	assert(errs.len == 0, "%s", errs);
}

fn void unterminated_nested_block_comment_runs_to_eof() @test
{
	Diag[] errs = diag_capture::errors_for(`module t;
fn void main() {}
/* open
/* nested */
foo bar
`);
	assert(errs.len == 0, "%s", errs);
}
