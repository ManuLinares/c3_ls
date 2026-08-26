module analyzer::parser;

import analyzer::core;
import analyzer::lexer;
<*
 fn_decl ::= fn type_expr (type_expr '.')? ident '(' parameter_list? ')' attributes?
 fn_body ::= ('=>' short_body) | compound_stmt
 @require scope.ctx.current.kind == FN
*>
fn Node* parse_fn_decl(ContextScope scope)
{
	ParseContext* ctx = scope.ctx;
	ParseFlags flags = scope.flags;
	Range start = ctx.current.range;

	advance(ctx);  // Consume 'fn'
	diagnostics::log_debug("parse_fn");

	FnDecl* node = scope.ctx.ast.alloc_node(FnDecl, start);
	defer node.range.end = ctx.peek(-1).range.end;

	if (!parse_fn_name_and_type(scope, node))
	{
		node.flags.has_error = true;
		synchronize(ctx, DECLARATION);
		return (Node*)node;
	}

	node.params = parse_parameter_list(scope.with_flags(
	{
		.is_function = true
	}
	));

	switch (ctx.peek(-1).kind)
	{
		case RPAREN:
			break;
		default:
			node.flags.has_error = true;
			synchronize(ctx, DECLARATION);
			return (Node*)node;
	}
	// C3 spec Section 5.3.2: First parameter of a method implicitly has the associated type if omitted
	if (node.associated_type != null && node.params.len > 0)
	{
		Node* first_param = node.params[0];
		if (first_param && first_param.kind == VAR_DECL)
		{
			VarDecl* vd = first_param.as(VarDecl);
			if (vd.type == null)
			{
				vd.type = node.associated_type;
				vd.var_flags.is_self = true;
			}
		}
	}

	if (ctx.is(LESS))
	{
		node.generics = parse_generic_decl(scope);
	}

	switch (ctx.current.kind)
	{
		case AT_IDENT:
		case AT_TYPE_IDENT:
			node.attributes = parse_attributes(scope, node, {.allow_type_ident = true });
		default:
			break;
	}

	if (!parse_fn_body(scope, node))
	{
		node.flags.has_error = true;
		synchronize(ctx, DECLARATION);
	}

	return node;
}

fn bool parse_fn_name_and_type(ContextScope scope, FnDecl* func) @local
{
	ParseContext* ctx = scope.ctx;
	ParseFlags flags = scope.flags;

	func.ret_type = parse_type_expr(scope);
	if (!func.ret_type)
	{
		diagnostics::error(ctx.context, ctx.current.range, "Expected return type");
		return false;
	}

	switch (is_type(ctx))
	{
		case true:
			if (flags.is_interface)
			{
				diagnostics::error(ctx.context, ctx.current.range, "Interfaces cannot be methods");
				return false;
			}

			diagnostics::log_debug("parse_fn - set associated: %s", ctx.current.value);

			func.associated_type = parse_type_expr(scope);
			if (!func.associated_type) return false;

			if (expect(ctx, func, DOT).kind == ERROR) return false;

			Token t = expect(ctx, func, IDENT);
			if (t.kind == ERROR) return false;
			func.name = ctx.ident(t);
		case false:
			Token t = expect(ctx, func, IDENT);
			if (t.kind == ERROR) return false;
			func.name = ctx.ident(t);
	}

	return true;
}

fn bool parse_fn_body(ContextScope scope, FnDecl* func)
{
	ParseContext* ctx = scope.ctx;
	ParseFlags flags = scope.flags;
	Range start = ctx.current.range;

	switch (ctx.current.kind)
	{
		case LBRACE:
			if (flags.is_extern)
			{
				diagnostics::error(ctx.context, start, "Extern functions cannot have a structural block body");
				ctx.ast.error(start);
				return false;
			}
			if (flags.is_interface)
			{
				diagnostics::error(ctx.context, start, "Interface methods cannot have a body");
				ctx.ast.error(start);
				return false;
			}
			func.body = parse_compound_stmt(scope);
			if (func.body)
			{
				func.range.end = func.body.range.end;
			}
		case IMPLIES:
			advance(ctx);
			if (flags.is_extern)
			{
				diagnostics::error(ctx.context, start, "Extern functions cannot have an expression body");
				ctx.ast.error(start);
				return false;
			}
			func.body = parse_short_body(scope, true);
			if (func.body)
			{
				func.range.end = func.body.range.end;
			}
		case EOS:
			func.range.end = ctx.current.range.end;
			advance(ctx);
		default:
			if (is_token_start_of_decl(ctx.current.kind))
			{
				diagnostics::error(ctx.context, ctx.current.range, "Expected function body or ';'");
				return false;
			}
			func.range.end = ctx.current.range.end;
			expect(ctx, func, EOS);
	}

	return true;
}
