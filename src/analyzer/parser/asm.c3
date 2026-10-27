module analyzer::parser;

import analyzer::core;

import std::collections::list;
<*
 @require scope.ctx.current.kind == ASM
*>
fn Node* parse_asm_block_stmt(ContextScope scope)
{
	ParseContext* ctx = scope.ctx;
	ParseFlags flags = scope.flags;
	Range start = ctx.current.range;
	advance(ctx);
	diagnostics::log_debug("parse_macro");
	AsmBlockStmt* node = ctx.ast.alloc_node(AsmBlockStmt, start);

	if (consume(ctx, LPAREN))
	{
		node.is_string = true;
		parse_expr(scope);
		(void)expect(ctx, (Node*)node, RPAREN);
		(void)expect(ctx, (Node*)node, EOS);
	}
	else if (ctx.current.kind == LBRACE)
	{
		skip_until(ctx, { RBRACE, EOF });
		consume(ctx, RBRACE);
	}
	else
	{
		skip_until(ctx, { RBRACE, EOS, EOF });
		if (ctx.current.kind == RBRACE || ctx.current.kind == EOS)
		{
			advance(ctx);
		}
	}

	return node;
}
