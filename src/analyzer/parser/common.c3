module analyzer::parser;

import analyzer::core;

import std::collections::list;

bitstruct ParseFlags : ulong
{
	bool is_contract;
	bool is_interface;  // Skip function bodies, disallow fields
	bool is_struct;
	bool is_macro;
	bool is_function;
	bool is_global;  // Top-level declarations
	bool is_local;  // Inside a function/block
	bool is_var;  // has a 'var'
	bool is_tlocal;  // has a 'tlocal'
	bool is_inline;
	bool is_static;
	bool is_extern;  // C-linkage handling
	bool is_thread_local;
	bool is_attribute;  // Special parsing for @attr(...)
	bool is_type_only;  // Used for casts or sizeof where names aren't expected
	bool is_const;  // Context requires constant expressions
	bool is_constdef;
	bool is_call;
	bool is_expr;
	bool is_stmt;
	bool is_lamda;
	bool is_comptime;
	bool type_as_expression;
	bool no_generics;  // dont allow type parsing to check for generics
	bool skip_eos;
}

bitstruct ParamParseFlags : uint
{
	bool is_attrdef;
	bool is_call;
	bool is_macro;
}

bitstruct AttributeParseFlags : uint
{
	bool use_comma;
	bool allow_type_ident;
}

<*
 Options for path parsing.

 Fields:
 - as_prefix: Parse as an optional prefix before another syntax node.
*>
struct PathExprOptions
{
	bool as_prefix;
}
