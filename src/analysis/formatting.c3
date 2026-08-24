// src/analysis/formatting.c3
module lsp::analysis::formatting;

import analyzer::core;
import analyzer::lexer;

import std::collections::list;
import std::io;

import lsp::core;
import lsp;
import lsp::analysis;
import uri;

enum BraceKind : char
{
	BLOCK,
	SWITCH_BLOCK,
	MULTILINE_INIT,
	INLINE_INIT
}

struct FormatterContext
{
	String buffer;
	sz[] line_offsets;
	FormattingOptions options;
	DString out;
	int indent_level;
	int paren_depth;
	int bracket_depth;
	int for_paren_depth;
	int foreach_paren_depth;
	int generic_depth;
	int decl_generic_depth;
	int ternary_depth;
	bool in_case_header;
	bool in_case_body;
	int ct_foreach_colons;
	bool last_rparen_was_cast;
	BraceKind[128] brace_stack;
	int brace_stack_len;
	bool at_line_start;
	bool is_decl_header;
	bool is_switch_header;
	bool in_ct_header;
	int consecutive_newlines;
	TokenKind prev_kind;
	TokenKind curr_kind;
	Token prev_prev_token;
	Token prev_token;
	Token curr_token;
	Token next_token;
}

fn void push_brace(FormatterContext* ctx, BraceKind kind)
{
	if (ctx.brace_stack_len < 128)
	{
		ctx.brace_stack[ctx.brace_stack_len++] = kind;
	}
}

fn BraceKind pop_brace(FormatterContext* ctx)
{
	if (ctx.brace_stack_len > 0)
	{
		return ctx.brace_stack[--ctx.brace_stack_len];
	}
	return INLINE_INIT;
}

fn bool is_word_token(TokenKind k)
{
	if (k.is_keyword() || k.is_base_type())
	{
		return true;
	}
	switch (k)
	{
		case IDENT:
		case TYPE_IDENT:
		case CONST_IDENT:
		case AT_IDENT:
		case AT_TYPE_IDENT:
		case AT_CONST_IDENT:
		case CT_IDENT:
		case CT_TYPE_IDENT:
		case CT_CONST_IDENT:
		case HASH_IDENT:
		case HASH_TYPE_IDENT:
		case HASH_CONST_IDENT:
		case CT_FOR:
		case CT_IF:
		case CT_ELSE:
		case CT_ENDIF:
		case CT_ENDFOR:
		case CT_FOREACH:
		case CT_ENDFOREACH:
		case CT_SWITCH:
		case CT_ENDSWITCH:
		case CT_CASE:
		case CT_DEFAULT:
		case CT_ASSERT:
		case CT_ECHO:
		case CT_ERROR:
		case CT_EVAL:
		case CT_STRINGIFY:
		case CT_TYPEOF:
		case CT_TYPEFROM:
		case CT_VAARG:
		case CT_FEATURE:
		case INT_DECIMAL_LITERAL:
		case INT_HEX_LITERAL:
		case INT_OCTAL_LITERAL:
		case INT_BIN_LITERAL:
		case FLOAT_DECIMAL_LITERAL:
		case FLOAT_HEX_LITERAL:
		case STRING_LITERAL:
		case CHAR_LITERAL:
		case BYTES_LITERAL:
		case TRUE:
		case FALSE:
		case NULL:
			return true;
		default:
			return false;
	}
}

fn bool is_strictly_binary_operator(TokenKind kind)
{
	switch (kind)
	{
		case DIV:
		case MOD:
		case BIT_OR:
		case BIT_XOR:
		case EQ:
		case EQEQ:
		case NOT_EQUAL:
		case LESS_EQ:
		case GREATER_EQ:
		case OR:
		case AND:
		case PLUS_ASSIGN:
		case MINUS_ASSIGN:
		case MULT_ASSIGN:
		case DIV_ASSIGN:
		case MOD_ASSIGN:
		case BIT_AND_ASSIGN:
		case BIT_OR_ASSIGN:
		case BIT_XOR_ASSIGN:
		case LSHIFT_ASSIGN:
		case RSHIFT_ASSIGN:
		case LSHIFT:
		case RSHIFT:
		case IMPLIES:
		case ARROW:
		case ELVIS:
		case QUESTQUEST:
		case CT_CONCAT_OP:
		case CT_CONCAT_ASSIGN:
		case CT_AND_OP:
		case CT_OR_OP:
		case CT_TERNARY:
			return true;
		default:
			return false;
	}
}

fn bool is_type_name_token(TokenKind k)
{
	if (k.is_base_type()) return true;
	switch (k)
	{
		case TYPE_IDENT:
		case CT_TYPE_IDENT:
		case CT_TYPEOF:
		case CT_TYPEFROM:
			return true;
		default:
			return false;
	}
}

fn bool is_type_ending_token(TokenKind k)
{
	if (is_type_name_token(k)) return true;
	switch (k)
	{
		case RBRACKET:
		case RVEC:
		case ASTERISK:
			return true;
		default:
			return false;
	}
}

fn bool is_control_or_statement_keyword(TokenKind k)
{
	switch (k)
	{
		case IF:
		case WHILE:
		case FOR:
		case FOREACH:
		case FOREACH_R:
		case SWITCH:
		case RETURN:
		case CASE:
		case DEFAULT:
		case CATCH:
		case TRY:
		case DEFER:
		case CT_IF:
		case CT_FOR:
		case CT_FOREACH:
		case CT_SWITCH:
		case CT_CASE:
		case CT_DEFAULT:
		case CT_ELSE:
			return true;
		default:
			return false;
	}
}

fn bool is_assignment_operator(TokenKind k)
{
	switch (k)
	{
		case EQ:
		case PLUS_ASSIGN:
		case MINUS_ASSIGN:
		case MULT_ASSIGN:
		case DIV_ASSIGN:
		case MOD_ASSIGN:
		case BIT_AND_ASSIGN:
		case BIT_OR_ASSIGN:
		case BIT_XOR_ASSIGN:
		case LSHIFT_ASSIGN:
		case RSHIFT_ASSIGN:
		case CT_CONCAT_ASSIGN:
			return true;
		default:
			return false;
	}
}

fn bool is_prefix_unary_context(TokenKind prev)
{
	switch (prev)
	{
		case ERROR:
		case LPAREN:
		case LBRACKET:
		case LBRACE:
		case COMMA:
		case COLON:
		case EOS:
		case IF:
		case WHILE:
		case CASE:
		case DEFAULT:
		case QUESTION:
		case CT_TERNARY:
		case EQ:
		case PLUS_ASSIGN:
		case MINUS_ASSIGN:
		case MULT_ASSIGN:
		case DIV_ASSIGN:
		case MOD_ASSIGN:
		case BIT_AND_ASSIGN:
		case BIT_OR_ASSIGN:
		case BIT_XOR_ASSIGN:
		case LSHIFT_ASSIGN:
		case RSHIFT_ASSIGN:
		case PLUS:
		case MINUS:
		case ASTERISK:
		case DIV:
		case MOD:
		case AND:
		case OR:
		case NOT_EQUAL:
		case EQEQ:
		case LESS:
		case LESS_EQ:
		case GREATER:
		case GREATER_EQ:
		case IMPLIES:
		case QUESTQUEST:
		case ELVIS:
			return true;
		default:
			return false;
	}
}

fn bool is_expr_operand_end(TokenKind k)
{
	if (is_word_token(k)) return true;
	switch (k)
	{
		case RPAREN:
		case RBRACKET:
		case RVEC:
		case RBRACE:
			return true;
		default:
			return false;
	}
}

fn void indent(FormatterContext* ctx)
{
	if (!ctx.at_line_start) return;

	for (int i = 0; i < ctx.indent_level; i++)
	{
		if (ctx.options.insert_spaces)
		{
			for (uint s = 0; s < ctx.options.tab_size; s++)
			{
				ctx.out.append_char(' ');
			}
		}
		else
		{
			ctx.out.append_char('\t');
		}
	}
	ctx.at_line_start = false;
}

fn void newline(FormatterContext* ctx, int count = 1)
{
	int to_emit = count;
	if (ctx.consecutive_newlines + count > 2)
	{
		to_emit = 2 - ctx.consecutive_newlines;
	}
	if (to_emit <= 0) return;

	for (int i = 0; i < to_emit; i++)
	{
		ctx.out.append_char('\n');
		ctx.consecutive_newlines++;
	}
	ctx.at_line_start = true;
}

fn bool is_initializer_context(TokenKind prev)
{
	switch (prev)
	{
		case EQ:
		case COMMA:
		case COLON:
		case LBRACKET:
		case RETURN:
		case CONST_IDENT:
			return true;
		default:
			return false;
	}
}

fn bool is_decl_block_start(TokenKind prev, TokenKind prev_prev)
{
	if (prev_prev == STRUCT || prev_prev == UNION || prev_prev == BITSTRUCT ||
		prev_prev == INTERFACE || prev_prev == ENUM || prev_prev == CONSTDEF)
	{
		return true;
	}
	return false;
}

fn bool should_space_between(FormatterContext* ctx, TokenKind prev, TokenKind curr)
{
	if (ctx.at_line_start) return false;

	// 1. Delimiters that NEVER have a leading space
	switch (curr)
	{
		case COMMA:
		case EOS:
		case RPAREN:
		case RBRACKET:
		case RVEC:
		case DOT:
		case SCOPE:
			return false;
		default:
			break;
	}

	// 2. Delimiters that NEVER have a trailing space
	switch (prev)
	{
		case DOT:
		case SCOPE:
		case LPAREN:
		case LBRACKET:
		case LVEC:
			return false;
		default:
			break;
	}

	// 3. Control keywords always have a space before any operand, even if operand is unary (!, ~, $, etc.)
	if (is_control_or_statement_keyword(prev))
	{
		if (curr == EOS) return false;
		if (curr == COLON && (prev == DEFAULT || prev == CT_DEFAULT || prev == CASE || prev == CT_CASE)) return false;
		return true;
	}

	// 4. Strictly binary and assignment operators always have a space after them
	if (is_strictly_binary_operator(prev) || is_assignment_operator(prev))
	{
		return true;
	}

	// 5. Declaration Generic parameter brackets: <Type> in module foo <Type>; struct Bar <Type>, typedef Baz <Type>
	if (curr == LESS && ctx.is_decl_header)
	{
		return true;
	}
	if (prev == LESS && ctx.decl_generic_depth > 0)
	{
		return false; // <Type
	}
	if (curr == GREATER && ctx.decl_generic_depth > 0)
	{
		return false; // Type>
	}
	if (prev == GREATER && ctx.decl_generic_depth > 0)
	{
		if (is_word_token(curr) || is_assignment_operator(curr) || curr == LBRACE || curr == LPAREN)
		{
			return true;
		}
	}

	// 6. Binary Comparison Operators < and > (outside declaration headers)
	if (curr == LESS || curr == GREATER)
	{
		if (is_expr_operand_end(prev))
		{
			return true;
		}
	}
	if (prev == LESS || prev == GREATER)
	{
		if (ctx.decl_generic_depth == 0)
		{
			return true;
		}
	}

	// 7. Builtin Prefix ($$): $$atomic_load -> no space after $$; => $$reduce, return $$atomic_load -> space before $$
	if (prev == BUILTIN) return false;
	if (curr == BUILTIN)
	{
		if (prev == RETURN || is_word_token(prev) || is_strictly_binary_operator(prev) || prev == COMMA) return true;
		return false;
	}

	// 8. Space before designated initializer member (.field) after { or ,
	if (curr == DOT && (prev == LBRACE || prev == COMMA))
	{
		return true;
	}

	// 9. Operator overload attribute syntax: @operator([]=) -> no space between ] and = only when immediately after [
	if (prev == RBRACKET && curr == EQ && ctx.prev_prev_token.kind == LBRACKET)
	{
		return false;
	}

	// 10. Fault suffix (~) and Rethrow (!) tight bonding
	if (curr == BIT_NOT)
	{
		if (prev == CONST_IDENT || prev == IDENT || prev == SCOPE || prev == RBRACE || prev == RPAREN || prev == RBRACKET)
		{
			return false;
		}
	}
	if (prev == BIT_NOT)
	{
		if (curr == BANG || curr == BANGBANG || curr == EOS || curr == COMMA || curr == RPAREN || curr == RBRACKET || curr == RBRACE)
		{
			return false;
		}
	}
	if (curr == BANG || curr == BANGBANG)
	{
		if (prev == BIT_NOT || prev == IDENT || prev == CONST_IDENT || prev == RPAREN || prev == RBRACKET)
		{
			return false;
		}
	}

	// 11. Optional Type Modifier (?) - never a space before ?, e.g. int?, char[]?, Type*?, List{int}?
	if (curr == QUESTION)
	{
		if (prev == ASTERISK || is_type_ending_token(prev) || prev == RBRACE)
		{
			return false;
		}
		return true;
	}

	if (prev == QUESTION)
	{
		if ((is_type_ending_token(ctx.prev_prev_token.kind) || ctx.prev_prev_token.kind == RBRACE) && is_word_token(curr))
		{
			return true;
		}
		if (is_type_ending_token(ctx.prev_prev_token.kind) || ctx.prev_prev_token.kind == RBRACE)
		{
			return false;
		}
		return true;
	}

	// 12. Closing parenthesis of casts vs expressions: (Type)x, (Allocator)&dummy vs (a + b) & (c + d)
	if (prev == RPAREN)
	{
		bool prev_was_cast = is_type_name_token(ctx.prev_prev_token.kind) || ctx.prev_prev_token.kind == ASTERISK || ctx.prev_prev_token.kind == RBRACKET;

		if (prev_was_cast)
		{
			if (curr == AMP || curr == AND || curr == ASTERISK || curr == MINUS || curr == PLUS || curr == BANG || curr == BIT_NOT)
			{
				return false;
			}
			if (curr == LBRACE)
			{
				return false; // ($Type[]){ ... } compound literal
			}
			if (is_word_token(curr))
			{
				return false;
			}
		}
		else
		{
			if (is_word_token(curr) || is_strictly_binary_operator(curr) || curr == AMP || curr == AND || curr == PLUS || curr == MINUS || curr == ASTERISK)
			{
				return true;
			}
		}
	}

	// 13. Pointer star (*) and address-of (&) spacing
	if (prev == ASTERISK)
	{
		if (curr == LBRACKET || curr == LVEC || curr == RPAREN || curr == ASTERISK || curr == QUESTION || curr == COMMA || curr == EOS)
		{
			return false;
		}
		if (is_type_name_token(ctx.prev_prev_token.kind) || (ctx.prev_prev_token.kind == RBRACE && ctx.generic_depth > 0))
		{
			if (is_word_token(curr)) return true;
			return false;
		}
		if (is_prefix_unary_context(ctx.prev_prev_token.kind) || (ctx.prev_prev_token.kind == RPAREN && ctx.last_rparen_was_cast) || ctx.prev_prev_token.kind == RETURN || is_control_or_statement_keyword(ctx.prev_prev_token.kind))
		{
			return false;
		}
		if (is_word_token(curr) || curr == LPAREN)
		{
			return true;
		}
	}

	if (prev == AMP || prev == AND || prev == BANG || prev == BANGBANG || prev == BIT_NOT)
	{
		if (curr == LPAREN && (prev == BANG || prev == BANGBANG || prev == BIT_NOT))
		{
			return false;
		}
		if (is_prefix_unary_context(ctx.prev_prev_token.kind) || (ctx.prev_prev_token.kind == RPAREN && ctx.last_rparen_was_cast) || ctx.prev_prev_token.kind == RETURN || is_control_or_statement_keyword(ctx.prev_prev_token.kind))
		{
			return false;
		}
	}

	if (prev == MINUS)
	{
		if (is_prefix_unary_context(ctx.prev_prev_token.kind) || (ctx.prev_prev_token.kind == RPAREN && ctx.last_rparen_was_cast) || is_control_or_statement_keyword(ctx.prev_prev_token.kind))
		{
			return false;
		}
	}

	if (curr == ASTERISK || curr == AMP)
	{
		if (prev == LPAREN || prev == LBRACKET || prev == LBRACE)
		{
			return false;
		}
		if (prev == RPAREN && (is_type_name_token(ctx.prev_prev_token.kind) || ctx.prev_prev_token.kind == ASTERISK || ctx.prev_prev_token.kind == RBRACKET))
		{
			return false; // (Type)*ptr or (Type)&val
		}
		if (is_type_name_token(prev) || (prev == RBRACE && ctx.generic_depth > 0))
		{
			return false; // Type* ptr
		}
		if (prev == COMMA || prev == COLON || prev == RETURN || is_strictly_binary_operator(prev) || is_assignment_operator(prev) || is_control_or_statement_keyword(prev))
		{
			return true;
		}
		if (is_expr_operand_end(prev))
		{
			return true; // binary * or &
		}
		return true;
	}

	// Dual-use binary operators in operand context: x + y, x - y, x & y, x * y
	if (curr == PLUS || curr == MINUS)
	{
		if (is_expr_operand_end(prev))
		{
			return true;
		}
	}
	if (prev == PLUS || prev == MINUS || prev == ASTERISK || prev == AMP)
	{
		bool prev_was_cast = (ctx.prev_prev_token.kind == RPAREN && ctx.last_rparen_was_cast);
		if (!is_prefix_unary_context(ctx.prev_prev_token.kind) &&
			!prev_was_cast &&
			ctx.prev_prev_token.kind != RETURN &&
			!is_control_or_statement_keyword(ctx.prev_prev_token.kind) &&
			!is_type_name_token(ctx.prev_prev_token.kind))
		{
			return true; // binary +, -, *, &
		}
	}

	// 14. Implemented interface list & Enum param list: struct HashSet (Printable), enum MimeType : int (String ext)
	if ((prev == TYPE_IDENT || is_type_name_token(prev)) && curr == LPAREN && ctx.is_decl_header)
	{
		return true;
	}

	// 15. Generic instantiation braces: List{int} or clamp_length{$Typeof(self)}
	if (curr == LBRACE)
	{
		if (prev == RPAREN && (is_type_ending_token(ctx.prev_prev_token.kind) || ctx.prev_prev_token.kind == RBRACE))
		{
			return false; // ($Type[]){...}
		}
		bool is_decl_block = is_decl_block_start(prev, ctx.prev_prev_token.kind);
		if ((prev == TYPE_IDENT || prev == IDENT) && !is_decl_block && !is_initializer_context(prev)) return false;
		if (prev == RBRACE && ctx.generic_depth > 0) return false;
		return true;
	}

	if (curr == RBRACE)
	{
		if (ctx.generic_depth > 0) return false;
		if (prev == LBRACE) return false;
		return true;
	}

	if (prev == LBRACE && ctx.generic_depth == 0)
	{
		return true;
	}

	// 16. Parenthesis after control keywords, return, binary operators, labels, or generic calls
	if (curr == LPAREN)
	{
		if (prev == RBRACE) return false;
		if (prev == COMMA) return true;
		if (prev == RETURN) return true;
		if (prev == COLON) return true;
		if (is_strictly_binary_operator(prev)) return true;
		if (is_control_or_statement_keyword(prev)) return true;
		return false;
	}

	// 17. Colon spacing: ternary vs foreach vs slice range vs decl header vs label/switch
	if (curr == COLON)
	{
		if (prev == DEFAULT || prev == CT_DEFAULT || prev == CASE || prev == CT_CASE) return false;
		if (ctx.in_ct_header) return false;
		if (ctx.in_case_header) return false;
		if (ctx.is_decl_header) return true;
		if (ctx.ct_foreach_colons == 1 && (prev == CT_IDENT || prev == CT_TYPE_IDENT || prev == IDENT)) return true;
		if (ctx.bracket_depth > 0)
		{
			if (prev == LBRACKET) return false;
			return true;
		}
		if (ctx.foreach_paren_depth > 0 || ctx.ternary_depth > 0)
		{
			return true;
		}
		return false;
	}

	if (prev == COLON)
	{
		if (curr == COLON || curr == SCOPE) return false;
		if (ctx.bracket_depth > 0 && ctx.prev_prev_token.kind == LBRACKET)
		{
			return false;
		}
		return true;
	}

	if (prev == COMMA) return true;

	if (curr == LBRACKET || curr == LVEC) return false;

	// 18. Splat operator inside initializers: { ...v, 1 }
	if (curr == ELLIPSIS && (prev == LBRACE || prev == COMMA))
	{
		return true;
	}

	// 19. Word touching Word (fn int, int x, return x, etc.)
	if (is_word_token(prev) && is_word_token(curr)) return true;

	// 20. Brackets touching word: int[1] x, List{int} items
	if ((prev == RBRACE || prev == RBRACKET || prev == RVEC) && is_word_token(curr))
	{
		return true;
	}

	if (prev == EOS && (ctx.paren_depth > 0 || curr != EOF)) return true;

	if (is_strictly_binary_operator(curr)) return true;
	if (prev == DOCS_END) return true;

	return false;
}

fn String format_tokens_range(
	Allocator output_allocator,
	String full_buffer,
	Token[] tokens,
	sz start_idx,
	sz end_idx,
	int base_indent,
	FormattingOptions options
)
{
	DString final_out;
	final_out.init(output_allocator);

	@pool()
	{
		sz[] line_offsets = analysis::build_line_offsets(tmem, full_buffer);

		FormatterContext ctx = {
			.buffer = full_buffer,
			.line_offsets = line_offsets,
			.options = options,
			.indent_level = base_indent,
			.paren_depth = 0,
			.bracket_depth = 0,
			.for_paren_depth = 0,
			.foreach_paren_depth = 0,
			.generic_depth = 0,
			.decl_generic_depth = 0,
			.ternary_depth = 0,
			.in_case_header = false,
			.in_case_body = false,
			.ct_foreach_colons = 0,
			.last_rparen_was_cast = false,
			.brace_stack_len = 0,
			.at_line_start = true,
			.is_decl_header = false,
			.is_switch_header = false,
			.in_ct_header = false,
			.consecutive_newlines = 0,
			.prev_kind = ERROR,
			.curr_kind = ERROR
		};
		ctx.out.tinit();

		for (sz i = start_idx; i <= end_idx && i < tokens.len; i++)
		{
			Token tok = tokens[i];
			if (tok.kind == EOF) break;

			Token next_tok = (i + 1 < tokens.len) ? tokens[i + 1] : (Token){ .kind = EOF };

			ctx.curr_token = tok;
			ctx.curr_kind = tok.kind;
			ctx.next_token = next_tok;

			// Top-level module declarations reset indent baseline to 0
			if (tok.kind == MODULE && ctx.brace_stack_len == 0)
			{
				ctx.indent_level = 0;
			}

			// 1. Verbatim Preservation of Doc Contracts (<* ... *>)
			if (tok.kind == DOCS_START)
			{
				if (ctx.at_line_start) indent(&ctx);

				sz end_doc_idx = i;
				while (end_doc_idx < tokens.len && tokens[end_doc_idx].kind != DOCS_END && tokens[end_doc_idx].kind != EOF)
				{
					end_doc_idx++;
				}

				sz start_off = analysis::offset_from_line_table(ctx.line_offsets, ctx.buffer, (uint)tok.range.start.line, (uint)tok.range.start.column);
				sz end_off = analysis::offset_from_line_table(ctx.line_offsets, ctx.buffer, (uint)tokens[end_doc_idx].range.end.line, (uint)tokens[end_doc_idx].range.end.column);

				if (start_off < end_off && end_off <= ctx.buffer.len)
				{
					ctx.out.append(ctx.buffer[start_off : end_off - start_off].trim());
				}
				else
				{
					ctx.out.append("<* ... *>");
				}

				ctx.consecutive_newlines = 0;
				newline(&ctx, 1);
				i = end_doc_idx;
				ctx.prev_prev_token = ctx.prev_token;
				ctx.prev_kind = DOCS_END;
				ctx.prev_token = tokens[end_doc_idx];
				continue;
			}

			if (tok.kind == STRUCT || tok.kind == ENUM || tok.kind == UNION ||
				tok.kind == BITSTRUCT || tok.kind == INTERFACE || tok.kind == CONSTDEF ||
				tok.kind == TYPEDEF || tok.kind == ALIAS ||
				tok.kind == FN || tok.kind == MACRO || tok.kind == MODULE)
			{
				ctx.is_decl_header = true;
			}

			if (tok.kind == SWITCH || tok.kind == CT_SWITCH)
			{
				ctx.is_switch_header = true;
			}

			if (tok.kind == IMPLIES || tok.kind == EQ)
			{
				ctx.is_decl_header = false;
			}

			if (tok.kind == CT_IF || tok.kind == CT_FOR || tok.kind == CT_SWITCH)
			{
				ctx.in_ct_header = true;
			}

			if (tok.kind == CT_FOREACH)
			{
				ctx.ct_foreach_colons = 1;
			}

			// 2. Line Comments and Block Comments
			if (tok.kind == LINE_COMMENT)
			{
				if (ctx.at_line_start)
				{
					indent(&ctx);
				}
				else
				{
					ctx.out.append("  ");
				}
				ctx.out.append(tok.value.trim_right("\r\n"));
				ctx.consecutive_newlines = 0;
				newline(&ctx, 1);
				ctx.prev_prev_token = ctx.prev_token;
				ctx.prev_kind = tok.kind;
				ctx.prev_token = tok;
				continue;
			}

			if (tok.kind == BLOCK_COMMENT)
			{
				if (ctx.at_line_start)
				{
					indent(&ctx);
				}
				else
				{
					ctx.out.append_char(' ');
				}
				ctx.out.append(tok.value);
				ctx.consecutive_newlines = 0;

				if (next_tok.kind != EOF && next_tok.range.start.line > tok.range.end.line)
				{
					int line_diff = next_tok.range.start.line - tok.range.end.line;
					newline(&ctx, line_diff >= 2 ? 2 : 1);
				}

				ctx.prev_prev_token = ctx.prev_token;
				ctx.prev_kind = tok.kind;
				ctx.prev_token = tok;
				continue;
			}

			// 3. Compile-Time Blocks ($else, $endif, $endfor, etc.) Dedent
			if (tok.kind == CT_ELSE)
			{
				if (ctx.indent_level > 0) ctx.indent_level--;
				if (!ctx.at_line_start) newline(&ctx);
			}
			if (tok.kind == CT_ENDIF || tok.kind == CT_ENDFOR || tok.kind == CT_ENDFOREACH)
			{
				if (ctx.indent_level > 0) ctx.indent_level--;
				if (!ctx.at_line_start) newline(&ctx);
			}
			if (tok.kind == CT_ENDSWITCH)
			{
				if (ctx.in_case_body)
				{
					if (ctx.indent_level > 0) ctx.indent_level--;
					ctx.in_case_body = false;
				}
				if (ctx.indent_level > 0) ctx.indent_level--;
				if (!ctx.at_line_start) newline(&ctx);
			}

			// 4. Track Declaration Generics: module foo <Type>; struct Bar <Type>
			if (tok.kind == LESS && ctx.is_decl_header)
			{
				ctx.decl_generic_depth++;
			}

			// 5. Dedent Closures with Stack
			BraceKind closed_bk = INLINE_INIT;
			bool just_closed_brace = false;

			if (tok.kind == RBRACE)
			{
				if (ctx.generic_depth == 0)
				{
					closed_bk = pop_brace(&ctx);
					just_closed_brace = true;

					if (closed_bk == SWITCH_BLOCK)
					{
						if (ctx.in_case_body)
						{
							if (ctx.indent_level > 0) ctx.indent_level--;
							ctx.in_case_body = false;
						}
						if (ctx.indent_level > 0)
						{
							ctx.indent_level--;
						}
						if (!ctx.at_line_start)
						{
							newline(&ctx);
						}
					}
					else if (closed_bk == BLOCK || closed_bk == MULTILINE_INIT)
					{
						if (ctx.indent_level > 0)
						{
							ctx.indent_level--;
						}
						if (!ctx.at_line_start)
						{
							newline(&ctx);
						}
					}
				}
			}

			if (tok.kind == RPAREN)
			{
				if (ctx.paren_depth > 0) ctx.paren_depth--;
				if (ctx.for_paren_depth > 0 && ctx.paren_depth < ctx.for_paren_depth)
				{
					ctx.for_paren_depth = 0;
				}
				if (ctx.foreach_paren_depth > 0 && ctx.paren_depth < ctx.foreach_paren_depth)
				{
					ctx.foreach_paren_depth = 0;
				}

				bool was_cast = is_type_name_token(ctx.prev_kind) || ctx.prev_kind == ASTERISK || ctx.prev_kind == RBRACKET;
				ctx.last_rparen_was_cast = was_cast;
			}

			if (tok.kind == RBRACKET || tok.kind == RVEC)
			{
				if (ctx.bracket_depth > 0) ctx.bracket_depth--;
			}

			if (tok.kind == QUESTION && !is_type_ending_token(ctx.prev_kind) && ctx.prev_kind != RBRACE)
			{
				ctx.ternary_depth++;
			}

			// 6. Preserve Blank Lines (Skip if preceded by comment to prevent duplicate newlines)
			if (tok.kind != RBRACE && i > start_idx && ctx.prev_kind != ERROR &&
				ctx.prev_kind != LINE_COMMENT && ctx.prev_kind != BLOCK_COMMENT && ctx.prev_kind != DOCS_END)
			{
				int line_diff = tok.range.start.line - ctx.prev_token.range.end.line;
				if (line_diff >= 2)
				{
					if (ctx.at_line_start)
					{
						newline(&ctx, 1);
					}
					else
					{
						newline(&ctx, 2);
					}
				}
				else if (line_diff == 1 && !ctx.at_line_start)
				{
					newline(&ctx, 1);
				}
			}

			// 7. Block Opening Brace (Allman Newline)
			if (tok.kind == LBRACE)
			{
				bool is_decl_block = is_decl_block_start(ctx.prev_kind, ctx.prev_prev_token.kind);
				bool is_generic = ((ctx.prev_kind == TYPE_IDENT || ctx.prev_kind == IDENT) && !is_decl_block) ||
					(ctx.prev_kind == RBRACE && ctx.generic_depth > 0);

				bool is_compound_literal = (ctx.prev_kind == RPAREN && (is_type_ending_token(ctx.prev_prev_token.kind) || ctx.prev_prev_token.kind == RBRACE));
				bool is_init = (is_initializer_context(ctx.prev_kind) || is_compound_literal || next_tok.kind == RBRACE) && !ctx.is_switch_header;

				if (!is_generic && !is_init && next_tok.kind != RBRACE && !ctx.at_line_start)
				{
					newline(&ctx);
				}
			}

			// 8. Switch Case Label Alignment (Dedent Previous Case Statements back to Case Level)
			if (tok.kind == CASE || tok.kind == DEFAULT || tok.kind == CT_CASE || tok.kind == CT_DEFAULT)
			{
				if (ctx.in_case_body)
				{
					if (ctx.indent_level > 0) ctx.indent_level--;
					ctx.in_case_body = false;
				}
				ctx.in_case_header = true;
				if (!ctx.at_line_start) newline(&ctx);
			}

			// 9. Indent at Line Start or Space/Alignment Between
			if (ctx.at_line_start)
			{
				indent(&ctx);
			}
			else if (should_space_between(&ctx, ctx.prev_kind, tok.kind))
			{
				int col_diff = (i > start_idx && tok.range.start.line == ctx.prev_token.range.end.line)
					? (tok.range.start.column - ctx.prev_token.range.end.column)
					: 1;

				if (col_diff > 1 && col_diff <= 32)
				{
					for (int s = 0; s < col_diff; s++)
					{
						ctx.out.append_char(' ');
					}
				}
				else
				{
					ctx.out.append_char(' ');
				}
			}

			// 10. Emit Token Content
			ctx.out.append(tok.value);
			ctx.consecutive_newlines = 0;

			// 11. Blank lines after top-level block closing brace
			if (just_closed_brace && (closed_bk == BLOCK || closed_bk == SWITCH_BLOCK))
			{
				if (next_tok.kind != ELSE && next_tok.kind != WHILE && next_tok.kind != EOS && next_tok.kind != EOF)
				{
					if (ctx.brace_stack_len == 0)
					{
						ctx.is_decl_header = false;
						newline(&ctx, 2);
					}
					else
					{
						newline(&ctx, 1);
					}
				}
			}

			// 12. Compile-Time Block Opening Colon and Switch Case Colon
			if (tok.kind == COLON)
			{
				if (ctx.ternary_depth > 0)
				{
					ctx.ternary_depth--;
				}
				if (ctx.in_ct_header)
				{
					ctx.in_ct_header = false;
					ctx.indent_level++;
					newline(&ctx, 1);
				}
				else if (ctx.ct_foreach_colons == 1)
				{
					// First colon in `$foreach $var : $collection:` -> stays inline
					ctx.ct_foreach_colons = 2;
				}
				else if (ctx.ct_foreach_colons == 2)
				{
					// Second colon in `$foreach $var : $collection:` -> opens block
					ctx.ct_foreach_colons = 0;
					ctx.indent_level++;
					newline(&ctx, 1);
				}
				else if (ctx.in_case_header)
				{
					ctx.in_case_header = false;
					if (next_tok.kind != EOF && next_tok.kind != CASE && next_tok.kind != DEFAULT &&
						next_tok.kind != CT_CASE && next_tok.kind != CT_DEFAULT &&
						next_tok.range.start.line > tok.range.end.line)
					{
						ctx.indent_level++;
						ctx.in_case_body = true;
						newline(&ctx, 1);
					}
				}
			}
			if (tok.kind == CT_ELSE)
			{
				ctx.indent_level++;
				newline(&ctx, 1);
			}
			if (tok.kind == CT_ENDIF || tok.kind == CT_ENDFOR || tok.kind == CT_ENDFOREACH || tok.kind == CT_ENDSWITCH)
			{
				newline(&ctx, 1);
			}

			// 13. Track Depths & Openers
			if (tok.kind == LPAREN)
			{
				ctx.paren_depth++;
				if (ctx.prev_kind == FOR || ctx.prev_kind == CT_FOR)
				{
					ctx.for_paren_depth = ctx.paren_depth;
				}
				if (ctx.prev_kind == FOREACH || ctx.prev_kind == FOREACH_R || ctx.prev_kind == CT_FOREACH)
				{
					ctx.foreach_paren_depth = ctx.paren_depth;
				}
			}

			if (tok.kind == LBRACKET || tok.kind == LVEC)
			{
				ctx.bracket_depth++;
			}

			if (tok.kind == LBRACE)
			{
				bool is_decl_block = is_decl_block_start(ctx.prev_kind, ctx.prev_prev_token.kind);
				bool is_generic = ((ctx.prev_kind == TYPE_IDENT || ctx.prev_kind == IDENT) && !is_decl_block) ||
					(ctx.prev_kind == RBRACE && ctx.generic_depth > 0);

				bool is_compound_literal = (ctx.prev_kind == RPAREN && (is_type_ending_token(ctx.prev_prev_token.kind) || ctx.prev_prev_token.kind == RBRACE));
				bool is_init = (is_initializer_context(ctx.prev_kind) || is_compound_literal) && !ctx.is_switch_header;

				if (is_generic)
				{
					ctx.generic_depth++;
				}
				else if (next_tok.kind == RBRACE)
				{
					push_brace(&ctx, INLINE_INIT);
				}
				else if (is_init)
				{
					if (next_tok.kind != EOF && next_tok.range.start.line > tok.range.end.line)
					{
						push_brace(&ctx, MULTILINE_INIT);
						ctx.indent_level++;
						newline(&ctx);
					}
					else
					{
						push_brace(&ctx, INLINE_INIT);
					}
				}
				else if (ctx.is_switch_header)
				{
					push_brace(&ctx, SWITCH_BLOCK);
					ctx.indent_level++;
					newline(&ctx);
					ctx.is_switch_header = false;
				}
				else
				{
					push_brace(&ctx, BLOCK);
					ctx.indent_level++;
					newline(&ctx);
					ctx.is_decl_header = false;
				}
			}

			if (tok.kind == RBRACE)
			{
				if (ctx.generic_depth > 0)
				{
					ctx.generic_depth--;
				}
			}

			if (tok.kind == GREATER && ctx.decl_generic_depth > 0)
			{
				ctx.decl_generic_depth--;
			}

			// 14. Semicolon Statement Endings
			if (tok.kind == EOS)
			{
				ctx.is_decl_header = false;
				if (ctx.for_paren_depth == 0 && ctx.paren_depth == 0)
				{
					if (next_tok.kind == LINE_COMMENT && next_tok.range.start.line == tok.range.end.line)
					{
						// Keep inline for trailing line comment
					}
					else if (next_tok.kind == BLOCK_COMMENT && next_tok.range.start.line == tok.range.end.line)
					{
						// Keep inline for trailing block comment
					}
					else if (ctx.brace_stack_len > 0 && next_tok.kind != EOF && next_tok.kind != RBRACE && next_tok.range.start.line == tok.range.end.line)
					{
						// Keep inline for compact same-line statements
					}
					else
					{
						newline(&ctx, 1);
					}
				}
			}

			ctx.prev_prev_token = ctx.prev_token;
			ctx.prev_kind = tok.kind;
			ctx.prev_token = tok;
		}

		if (options.insert_final_newline && !ctx.at_line_start)
		{
			newline(&ctx);
		}

		final_out.append(ctx.out.str_view());
	};

	return final_out.str_view();
}

<*
 Formats the entire document buffer.
*>
fn TextEdit[]? format_document(LspProject* project, Uri uri, FormattingOptions options)
{
	SourceFile* sf = project.workspace.get_source_file_by_path(uri.path);
	if (!sf || sf.content.len == 0) return {};

	Lexer* lexer = lexer::create(project.workspace.ctx, sf.content, true);
	defer lexer::free(project.workspace.ctx, lexer);
	lexer::tokenize(lexer);

	if (lexer.tokens.len() == 0) return {};

	String formatted = format_tokens_range(tmem, sf.content, lexer.tokens.array_view(), 0, lexer.tokens.len() - 1, 0, options);

	Token last_tok = lexer.tokens[lexer.tokens.len() - 1];
	uint last_line = last_tok.range.end.line >= 0 ? (uint)last_tok.range.end.line : 0;
	uint last_char = last_tok.range.end.column >= 0 ? (uint)last_tok.range.end.column : 0;

	TextEdit[] edits = alloc::alloc_array(tmem, TextEdit, 1);
	edits[0] = {
		.range = {
			.start = { .line = 0, .character = 0 },
			.end = { .line = last_line, .character = last_char }
		},
		.newText = formatted
	};

	return edits;
}

<*
 Formats a specific line range within the document buffer without line-shifting bugs.
*>
fn TextEdit[]? format_range(LspProject* project, Uri uri, LspRange range, FormattingOptions options)
{
	SourceFile* sf = project.workspace.get_source_file_by_path(uri.path);
	if (!sf || sf.content.len == 0) return {};

	Lexer* lexer = lexer::create(project.workspace.ctx, sf.content, true);
	defer lexer::free(project.workspace.ctx, lexer);
	lexer::tokenize(lexer);

	if (lexer.tokens.len() == 0) return {};

	sz start_tok_idx = 0;
	sz end_tok_idx = lexer.tokens.len() - 1;
	bool found_start = false;

	for (sz i = 0; i < lexer.tokens.len(); i++)
	{
		Token tok = lexer.tokens[i];
		if (tok.kind == EOF) break;

		if (!found_start && tok.range.start.line >= (int)range.start.line)
		{
			start_tok_idx = i;
			found_start = true;
		}

		if (tok.range.end.line <= (int)range.end.line)
		{
			end_tok_idx = i;
		}
	}

	if (start_tok_idx > end_tok_idx) return {};

	Token first_tok = lexer.tokens[start_tok_idx];
	Token last_tok = lexer.tokens[end_tok_idx];

	String[] orig_lines = sf.content.tsplit("\n");
	int base_indent = 0;
	if (first_tok.range.start.line < orig_lines.len)
	{
		String line_str = orig_lines[first_tok.range.start.line];
		for (sz c = 0; c < line_str.len; c++)
		{
			if (line_str[c] == '\t')
			{
				base_indent++;
			}
			else if (line_str[c] == ' ')
			{
				uint spaces = 1;
				while (c + 1 < line_str.len && line_str[c + 1] == ' ' && spaces < options.tab_size)
				{
					spaces++;
					c++;
				}
				base_indent++;
			}
			else
			{
				break;
			}
		}
	}

	String formatted_range = format_tokens_range(
		tmem,
		sf.content,
		lexer.tokens.array_view(),
		start_tok_idx,
		end_tok_idx,
		base_indent,
		options
	);

	TextEdit[] edits = alloc::alloc_array(tmem, TextEdit, 1);
	edits[0] = {
		.range = {
			.start = {
				.line = (uint)first_tok.range.start.line,
				.character = (uint)first_tok.range.start.column
			},
			.end = {
				.line = (uint)last_tok.range.end.line,
				.character = (uint)last_tok.range.end.column
			}
		},
		.newText = formatted_range.trim_right("\n")
	};

	return edits;
}