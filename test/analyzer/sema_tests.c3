module sema_tests @test;

import analyzer::parser;
import analyzer::core;
import analyzer::sema;
import std::io;

alias BinaryOp = fn int(int, int);

fn void test_variable_shadowing_valid()
{
	String source_code = `
		module test_shadow;

		int a = 10;

		fn void foo(int a)
		{
			int b = a;
			{
				int a = 20;
				int c = a;
			}
		}
	`;

	AnalyzerContext* context = context::create(tmem);
	bool success = context::process(context, source_code, "test_shadow.c3");
	test::eq(success, true);
}

fn void test_variable_redefinition_in_same_scope()
{
	String source_code = `
		module test_redef;

		fn void foo()
		{
			int a = 10;
			int a = 20;
		}
	`;

	AnalyzerContext* context = context::create(tmem);
	bool success = context::process(context, source_code, "test_redef.c3");
	test::eq(success, true);
}

fn void test_multiple_sections_same_import()
{
	String source_code = `
		module test_mod;
		import std::math;

		fn double foo(double x) { return math::sin(x); }

		module test_mod @test;
		import std::math;

		fn void test_foo() { assert(foo(0.0) == 0.0); }
	`;

	AnalyzerContext* context = context::create(tmem);
	bool success = context::process(context, source_code, "test_sections.c3");
	test::eq(success, true);
}

fn void test_multiple_module_sections_independent_variable_scopes()
{
	String source_code = `
		module std::collections::set <Value>;
		const int DEFAULT_INITIAL_CAPACITY = 16;
		const int MAXIMUM_CAPACITY = 1 << 30;

		module std::collections::map <Key, Value>;
		const int DEFAULT_INITIAL_CAPACITY = 16;
		const int MAXIMUM_CAPACITY = 1 << 30;
	`;

	AnalyzerContext* context = context::create(tmem);
	bool success = context::process(context, source_code, "test_multimod.c3");
	test::eq(success, true);
}

fn void test_local_variables_across_sections_no_conflict()
{
	String source_code = `
		module std::collections::set <Value>;
		int dummy @local;

		module std::collections::ringbuffer <Type, CAPACITY>;
		int dummy @local;

		module std::collections::map <Key, Value>;
		int dummy @local;
	`;

	AnalyzerContext* context = context::create(tmem);
	bool success = context::process(context, source_code, "test_local_vars.c3");
	test::eq(success, true);
}

fn void test_conditional_feat_opposing_declarations_no_conflict()
{
	String source_code = `
		module alloc_mod;
		bool auto_create_temp @feat(EMSCRIPTEN) = false;
		tlocal bool auto_create_temp @feat(!EMSCRIPTEN) = false;
	`;

	AnalyzerContext* context = context::create(tmem);
	bool success = context::process(context, source_code, "test_feat_vars.c3");
	test::eq(success, true);
}

fn void test_multi_platform_module_sections_no_conflict()
{
	String source_code = `
		module libc @feat(DARWIN);
		const SCHED_OTHER = 1;
		const SCHED_FIFO  = 4;

		module libc @feat(FREEBSD);
		const SCHED_OTHER = 2;
		const SCHED_FIFO  = 1;

		module libc @feat(LINUX, ANDROID);
		const SCHED_OTHER = 0;
		const SCHED_FIFO  = 1;
	`;

	AnalyzerContext* context = context::create(tmem);
	bool success = context::process(context, source_code, "test_platform_sections.c3");
	test::eq(success, true);
}

fn void test_lambdas_in_same_function_isolated_parameter_scopes()
{
	String source_code = `
		module lambda_mod;
		alias BinaryOp = fn int(int, int);
		fn void run()
		{
			BinaryOp f1 = fn (a, b) => a ^ b;
			BinaryOp f2 = fn (a, b) => a ^ b;
		}
	`;

	AnalyzerContext* context = context::create(tmem);
	bool success = context::process(context, source_code, "test_lambda_scope.c3");
	test::eq(success, true);
}

fn void test_trailing_block_macro_repeated_argument_scoping()
{
	String source_code = `
		module trailing_block_mod;
		macro void @stack_mem(sz size; @body(void* smem)) { @body(null); }
		fn void run()
		{
			@stack_mem(64; void* smem) {};
			@stack_mem(128; void* smem) {};
		}
	`;

	AnalyzerContext* context = context::create(tmem);
	bool success = context::process(context, source_code, "test_trailing_block_scope.c3");
	test::eq(success, true);
}

fn void test_macro_decl_body_param_isolation()
{
	String source_code = `
		module macro_decl_mod;
		macro void @loop_over(int ai; @body(int fd, int ai)) {}
	`;

	AnalyzerContext* context = context::create(tmem);
	bool success = context::process(context, source_code, "test_macro_decl_body_params.c3");
	test::eq(success, true);
}

fn void test_distinct_generic_module_sections_no_conflict()
{
	String source_code = `
		module std::sort <Type> @private;
		const bool IS_SLICE = false;

		module std::sort <Type, CmpFn, Context> @private;
		const bool IS_SLICE = true;
	`;

	AnalyzerContext* context = context::create(tmem);
	bool success = context::process(context, source_code, "test_distinct_generics.c3");
	test::eq(success, true);
}

fn void test_typeid_member_access_in_ct_if()
{
	String source_code = `
		module path_mod;
		fn void check()
		{
			$if Path::typeid == PathWin:
				int a = 1;
			$else
				int a = 2;
			$endif
		}
	`;

	AnalyzerContext* context = context::create(tmem);
	bool success = context::process(context, source_code, "test_typeid.c3");
	test::eq(success, true);
}