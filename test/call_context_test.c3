module lsp::call_context_test;

import lsp;

macro bool is_call(String text) => utils::parse_call_context(text, text.len).is_valid;

fn void keywords_are_never_callees() @test
{
	assert(!is_call("\tif (a"));
	assert(!is_call("\tforeach_r (x"));
	assert(!is_call("\tassert(a"));
	assert(!is_call("\tint n = lengthof(a"));
	assert(!is_call("\tbool b = $defined(a"));
}

fn void functions_and_builtins_are_callees() @test
{
	assert(is_call("\tfoo(a"));
	assert(is_call("\tio::printn(a"));
	assert(is_call("\tint m = $$max(a"));
}
