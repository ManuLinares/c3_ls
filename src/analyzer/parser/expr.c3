<*
 Pratt parsing using Binding power

	Resources for Binding power pratt parsing:
	- https://matklad.github.io/2020/04/13/simple-but-powerful-pratt-parsing.html
*>
module analyzer::parser;

import std::core::ascii;

import std::io;
import std::collections::list;
import std::encoding;
import analyzer::core;
import analyzer::lexer;
<*
 Parse an alias-only C3 function pointer type.

 Function pointer syntax is formed from a function declaration with the name
 omitted, and C3 exposes it through alias declarations.
 @require scope.ctx.current.kind == FN
*>
fn Node* parse_fn_type_expr(ContextScope scope) => @pool()
{
	ParseContext* ctx = scope.ctx;
	Range start = ctx.current.range;
	advance(ctx);
	TypeExpr* node = ctx.ast.alloc_node(TypeExpr, start);
	defer node.range.end = ctx.peek(-1).range.end;
	node.type_kind = TYPE_FUNCTION;
	node.func.ret_type = parse_type_expr(scope);
	node.func.params = parse_parameter_list(scope);
	node.func.attributes = parse_attributes(scope, node);
	return (Node*)node;
}

<*
 Parse a type target for a TYPE_IDENT alias.

 C3 function pointer types are alias-only, so this helper accepts `fn` syntax
 for aliases without making `fn` a general type-expression start.
 @require(scope.ctx != null) : "Parser context positioned at the alias target."
*>
fn Node* parse_alias_type_target(ContextScope scope) => @pool()
{
	ParseContext* ctx = scope.ctx;
	switch (ctx.current.kind)
	{
		case FN:
			return parse_fn_type_expr(scope);
		default:
			return parse_expr(scope);
	}
}

<*
 Parse a C3 type expression.

 Handles primitive and named type identifiers plus postfix pointer, array,
 slice, vector, and generic type forms.
 @require(scope.ctx != null) : "Parser context positioned at the first type token."
*>
fn Node* parse_type_expr(ContextScope scope, Node* path_expr = null)
{
	ParseContext* ctx = scope.ctx;
	ParseFlags flags = scope.flags;
	Range start = ctx.current.range;

	diagnostics::log_debug("parse_type_expr");

	switch (ctx.current.kind)
	{
		case FN:
			return parse_fn_type_expr(scope);
		default:
			break;
	}

	TypeExpr* current_type = ctx.ast.alloc_node(TypeExpr, start);
	defer current_type.range.end = ctx.peek(-1).range.end;

	switch (true)
	{
		case consume(ctx, CT_TYPEFROM):
			{
				current_type.type_kind = TYPE_TYPEFROM;
				expect(ctx, current_type, LPAREN);
				current_type.expr = parse_expr(scope);
				expect(ctx, current_type, RPAREN);
				break;
			}
		case consume(ctx, CT_TYPEOF):
			{
				current_type.type_kind = TYPE_TYPEOF;
				expect(ctx, current_type, LPAREN);
				current_type.expr = parse_expr(scope);
				expect(ctx, current_type, RPAREN);
				break;
			}
		case is_type_primitive(ctx.current.kind):
			{
				Token t = ctx.current;
				advance(ctx);

				current_type.type_kind = TYPE_IDENTIFIER;
				current_type.unresolved.name = ctx.ident(t);
				current_type.unresolved.path = null;
				break;
			}
		default:
			{
				Node* path = path_expr ? path_expr : parse_path_expr(scope, {.as_prefix = true });

				switch (ctx.current.kind)
				{
				case TYPE_IDENT:
					current_type.type_kind = TYPE_IDENTIFIER;
					current_type.unresolved.name = ctx.ident(ctx.current);
					current_type.unresolved.path = path;
					advance(ctx);
				default:
					diagnostics::error(ctx.context, ctx.current.range, "Expected type identifier");
					current_type.flags.has_error = true;
					skip_until(ctx, { EOS, ASTERISK, LBRACE, QUESTION, LVEC, LBRACKET });
					break;
			}
			break;
		}
	}

	while (true)
	{
		Token t = ctx.current;

		switch (t.kind)
		{
			case QUESTION:
				if (flags.type_as_expression) return (Node*)current_type;
				advance(ctx);
				current_type.optional = true;
				continue;

			case ASTERISK:
				advance(ctx);

				TypeExpr* ptr_node = ctx.ast.alloc_node(TypeExpr, { start.start, ctx.current.range.end });
				ptr_node.type_kind = TYPE_POINTER;
				ptr_node.modify.base = current_type;

				current_type = ptr_node;
				continue;

			case LVEC:
				advance(ctx);

				TypeExpr* vec_node = ctx.ast.alloc_node(TypeExpr, { start.start, ctx.current.range.end });
				vec_node.type_kind = TYPE_VECTOR;
				vec_node.array.base = current_type;

				if (!consume(ctx, ASTERISK))
				{
					vec_node.array.len_expr = parse_expr(scope, ADDITIVE);
				}

				expect(ctx, vec_node, RVEC);
				vec_node.range.end = ctx.peek(-1).range.end;

				current_type = vec_node;
				continue;

			case LBRACKET:
				advance(ctx);

				TypeExpr* arr_node = ctx.ast.alloc_node(TypeExpr, { start.start, ctx.current.range.end });

				switch (ctx.current.kind)
				{
				case RBRACKET:
					advance(ctx);
					arr_node.type_kind = TYPE_SLICE;
					arr_node.modify.base = current_type;
				case ASTERISK:
					if (ctx.peek(1).kind == RBRACKET)
					{
						advance(ctx, 2);
						arr_node.type_kind = TYPE_ARRAY;
						arr_node.array.base = current_type;
						arr_node.array.len_expr = null;
						break;
					}
					nextcase
				default;
				default:
					arr_node.type_kind = TYPE_ARRAY;
					arr_node.array.base = current_type;
					arr_node.array.len_expr = parse_expr(scope);
					expect(ctx, arr_node, RBRACKET);
					break;
			}

			arr_node.range.end = ctx.peek(-1).range.end;
			current_type = arr_node;
			continue;

			case LBRACE:
				if (flags.no_generics) return (Node*)current_type;

				TypeExpr* gen_node = ctx.ast.alloc_node(TypeExpr, { start.start, ctx.current.range.end });
				gen_node.type_kind = TYPE_GENERIC;
				gen_node.generic.base = current_type;
				gen_node.generic.params = parse_generics_list(scope);
				gen_node.range.end = ctx.current.range.end;

				current_type = gen_node;
				continue;

			default:
				break;
		}

		break;
	}

	return (Node*)current_type;
}

fn Node* parse_ident_expr(ContextScope scope)
{
	ParseContext* ctx = scope.ctx;
	Range start = ctx.current.range;
	Node* path_prefix;

	diagnostics::log_debug("parse_ident: %s", ctx.current.value);

	if (ctx.peek(1).kind == SCOPE)
	{
		path_prefix = parse_path_expr(scope, {.as_prefix = true });
	}
	Token t = ctx.current;
	switch (t.kind)
	{
		case TYPE_IDENT:
			return parse_type_expr(scope, path_prefix);
		case IDENT:
		case CONST_IDENT:
		case AT_IDENT:
		case CT_IDENT:
		case HASH_IDENT:
			{
				IdentExpr* ident = ctx.ast.alloc_node(IdentExpr, { start.start, t.range.end });
				ident.ident = ctx.ident(t);
				ident.path_expr = path_prefix;

				advance(ctx);
				ident.range.end = ctx.peek(-1).range.end;
				return (Node*)ident;
			}
		default:
			advance(ctx);
			diagnostics::error(ctx.context, t.range, "Expected type or identifier after path - got: %s", t.kind.description);
			return ctx.ast.error(t.range);
	}
}

fn void parse_join_strings(ContextScope scope, String* list)
{
	ParseContext* ctx = scope.ctx;

	if (ctx.eof() || !ctx.is(STRING_LITERAL)) return;

	Token first_tok = ctx.current;
	String current_str = first_tok.value[1 : ^ 2];
	advance(ctx);

	while (!ctx.eof() && ctx.is(STRING_LITERAL))
	{
		Token next_tok = ctx.current;
		String next_str = next_tok.value[1 : ^ 2];

		current_str = current_str.tconcat(next_str);

		advance(ctx);
	}

	* list = current_str.copy(ctx.allocator);
}

fn Node* parse_literal_expr(ContextScope scope) => @pool()
{
	ParseContext* ctx = scope.ctx;
	Token token = ctx.current;
	Range start   = token.range;

	LiteralExpr* literal = ctx.ast.alloc_node(LiteralExpr, start);
	defer literal.range.end = ctx.peek(-1).range.end;
	String token_text    = token.value;

	diagnostics::log_debug("literal_expr: %s", token.kind.description);

	switch (token.kind)
	{
		case NULL:
			literal.literal_kind = NULL_LITERAL;
			advance(ctx);
			break;
		case TRUE:
			literal.literal_kind = BOOL_LITERAL;
			literal.boolean = true;
			advance(ctx);
			break;
		case FALSE:
			literal.literal_kind = BOOL_LITERAL;
			literal.boolean = false;
			advance(ctx);
			break;
		case INT_DECIMAL_LITERAL:
		case INT_HEX_LITERAL:
		case INT_OCTAL_LITERAL:
		case INT_BIN_LITERAL:
			literal.literal_kind = INT_LITERAL;
			String clean_string = token_text.treplace("_", "");
			int base = 10;
			usz start_idx = 0;
			switch (token.kind)
			{
			case INT_HEX_LITERAL:
				base = 16;
				start_idx = 2;
			case INT_BIN_LITERAL:
				base = 2;
				start_idx = 2;
			case INT_OCTAL_LITERAL:
				base = 8;
				start_idx = 2;
			default:
				base = 10;
				start_idx = 0;
		}

		String body = clean_string[start_idx..];
		sz end_idx = body.len;
		while DIGIT_LOOP: (end_idx > 0)
		{
			char last_char = body[end_idx - 1];
			if (ascii::is_alpha(last_char))
			{
				switch (base)
				{
					case 16:
						if (ascii::is_xdigit(last_char)) break DIGIT_LOOP;
					case 10:
						if (ascii::is_digit(last_char)) break DIGIT_LOOP;
					case 8:
						if (ascii::is_odigit(last_char)) break DIGIT_LOOP;
					case 2:
						if (ascii::is_bdigit(last_char)) break DIGIT_LOOP;
					default:
						break;
				}

				end_idx--;
			}
			else
			{
				break DIGIT_LOOP;
			}
		}

		String pure_digits = body[0 : end_idx];
		uint128? value = pure_digits.to_uint128(base);
		if (catch err = value)
		{
			diagnostics::error(ctx.context, token.range, "Failed to parse int literal (%s)", err);
			advance(ctx);
			return ctx.ast.error(start);
		}
		literal.integer = value;
		advance(ctx);
		break;
		case FLOAT_DECIMAL_LITERAL:
		case FLOAT_HEX_LITERAL:
			{
				literal.literal_kind = REAL_LITERAL;
				String clean_string = token_text.treplace("_", "");
				sz len              = clean_string.len;
				if (len > 0)
				{
					if (clean_string.ends_with("f32") || clean_string.ends_with("f64"))
					{
						clean_string = clean_string[:^ 3];
					}
					if (clean_string.ends_with("f") || clean_string.ends_with("F") || clean_string.ends_with("d") || clean_string.ends_with("D"))
					{
						switch (token.kind)
						{
						case FLOAT_HEX_LITERAL:
							if (clean_string.contains("p") || clean_string.contains("P"))
							{
								clean_string = clean_string[:^ 1];
							}
						default:
							clean_string = clean_string[:^ 1];
					}
				}
			}
			double? real = clean_string.to_double();
			if (catch err = real)
			{
				diagnostics::error(ctx.context, token.range, "Failed to decode float literal (%s)", err);
				advance(ctx);
				return ctx.ast.error(start);
			}
			literal.real = real;
			advance(ctx);
			break;
		}
		case STRING_LITERAL:
			literal.literal_kind = STRING_LITERAL;
			literal.string = "";
			parse_join_strings(scope, &literal.string);
			break;
		case BYTES_LITERAL:
			literal.literal_kind = BYTES_LITERAL;
			switch (true)
			{
			case token_text.starts_with("b64"):
				String payload = token_text[4 : ^ 5];
				String clean = payload.treplace(" ", "")
				.treplace("\t", "")
				.treplace("\n", "")
				.treplace("\r", "");
				diagnostics::log_debug(clean);
				char[]? b64 = base64::decode(tmem, clean);
				if (catch err = b64)
				{
					diagnostics::error(ctx.context, token.range, "Failed to decode Base64(%s)", err);
					advance(ctx);
					return ctx.ast.error(start);
				}
				literal.bytes = alloc::clone_slice(ctx.allocator, b64);
				advance(ctx);
			case token_text.starts_with("x"):
				String payload = token_text[2 : ^ 3];
				String clean = payload.treplace(" ", "")
				.treplace("\t", "")
				.treplace("\n", "")
				.treplace("\r", "");
				diagnostics::log_debug("%s", clean);
				if (clean.len % 2 != 0)
				{
					diagnostics::error(ctx.context, token.range,
					"Hex literal payload must have an even number of digits (got %s chars in '%s')",
					clean.len,
					clean);
					advance(ctx);
					return ctx.ast.error(start);
				}
				char[]? hex = hex::decode(tmem, clean);
				if (catch err = hex)
				{
					diagnostics::error(ctx.context, token.range, "Failed to decode hex(%s): %s", clean, err);
					advance(ctx);
					return ctx.ast.error(start);
				}
				literal.bytes = alloc::clone_slice(ctx.allocator, hex);
				advance(ctx);
			default:
				break;
		}
		break;
		case CHAR_LITERAL:
			literal.literal_kind = INT_LITERAL;

			String clean_char = token_text[1 : ^ 2];

			if (clean_char.len == 0)
			{
				diagnostics::error(ctx.context, token.range, "Empty character literal encountered");
				advance(ctx);
				return ctx.ast.error(start);
			}

			switch (clean_char[0])
			{
			case '\\':
				if (clean_char.len < 2)
				{
					diagnostics::error(ctx.context, token.range, "Malformed escape sequence in character literal");
					advance(ctx);
					return ctx.ast.error(start);
				}

				switch (clean_char[1])
				{
				case 'n': literal.integer = (uint128)'\n'; break;
				case 'r': literal.integer = (uint128)'\r'; break;
				case 't': literal.integer = (uint128)'\t'; break;
				case '\\': literal.integer = (uint128)'\\'; break;
				case '\'': literal.integer = (uint128)'\''; break;
				case '"': literal.integer = (uint128)'"'; break;
				case '0': literal.integer = (uint128)'\0'; break;
				case 'a':  literal.integer = (uint128)0x07; break;
				case 'b':  literal.integer = (uint128)0x08; break;
				case 'e':  literal.integer = (uint128)0x1B; break;
				case 'f':  literal.integer = (uint128)0x0C; break;
				case 'v':  literal.integer = (uint128)0x0B; break;
				case 'x':
					if (clean_char.len < 4)
					{
						diagnostics::error(ctx.context, token.range, "Malformed hex escape sequence");
						return ctx.ast.error(start);
					}

					char hi = clean_char[2];
					char lo = clean_char[3];

					literal.integer = (uint128)((char.from_hex(hi) << 4) | char.from_hex(lo));
					break;
				default:
					diagnostics::error(ctx.context, token.range, "Unsupported escape sequence '\\%c'", clean_char[1]);
					advance(ctx);
					return ctx.ast.error(start);
			}
			default:
				literal.integer = (uint128)clean_char[0];
		}
		advance(ctx);
		break;
		default:
			unreachable("Not implemented! (%s)", token.kind.description);
	}

	return (Node*)literal;
}

<*
 Parse a full path e.g. foo::bar::baz;
*>
fn Node* parse_path_expr(ContextScope scope, PathExprOptions options = {}) => @pool()
{
	ParseContext* ctx = scope.ctx;
	Range start = ctx.current.range;
	diagnostics::log_debug("parse_path_expr");

	if (!ctx.is(IDENT))
	{
		if (options.as_prefix) return null;
		diagnostics::error(ctx.context, ctx.current.range, "Expected a path identifier");
		return ctx.ast.error(start);
	}

	PathExpr* node = ctx.ast.alloc_node(PathExpr, start);
	defer node.range.end = ctx.peek(-1).range.end;
	DString sb; sb.tinit();

	while LOOP: (ctx.is(IDENT))
	{
		switch (options.as_prefix)
		{
			case true:
				if (ctx.peek(1).kind == SCOPE)
				{
					sb.append(ctx.current.value);
					sb.append("::");
					advance(ctx, 2);
				}
				else
				{
					break LOOP;
				}
			case false:
				sb.append(ctx.current.value);
				advance(ctx);

				if (consume(ctx, SCOPE))
				{
					sb.append("::");
					switch (ctx.current.kind)
					{
					case IDENT:
						continue;
					default:
						diagnostics::error(ctx.context, ctx.current.range, "Expected an identifier after '::'");
						node.flags.has_error = true;
						break LOOP;
				}
			}
			break LOOP;
		}
	}

	node.path = ctx.ident_string(sb.str_view());
	return (Node*)node;
}

fn Node* parse_binary_expr(ContextScope scope, Node* left, Precedence prec)
{
	ParseContext* ctx = scope.ctx;
	Range start  = ctx.current.range;
	TokenKind kind = ctx.current.kind;
	advance(ctx);
	Node* right = parse_expr(scope.with_flags(
	{
		.type_as_expression = true
	}
	), prec);

	BinaryExpr* node = ctx.ast.alloc_node(BinaryExpr, { left.range.start, right.range.end });
	node.left = left;
	node.right = right;
	node.op = core::binaryop_from_token(kind);
	return (Node*)node;
}

fn Node* parse_unary_expr(ContextScope scope)
{
	ParseContext* ctx = scope.ctx;
	diagnostics::log_debug("parse_unary_expr");
	Range start = ctx.current.range;
	if (ctx.is(MINUS))
	{
		if (ctx.peek(1).kind.is_int_literal())
		{
			advance(ctx);
			return parse_expr(scope);
		}
	}
	bool is_bang_bang = ctx.is(BANGBANG);
	UnaryExpr* node = ctx.ast.alloc_node(UnaryExpr, start);
	defer node.range.end = ctx.peek(-1).range.end;
	UnaryOpKind? op  = core::unaryop_from_token(ctx.current.kind);
	if (catch op)
	{
		diagnostics::error(ctx.context, ctx.current.range, "Not a unary operator (%s)", ctx.current.kind);
		error_node(ctx, node);
	}
	else
	{
		node.operator = op;
	}
	advance(ctx);
	node.expr = parse_expr(scope, UNARY);
	if (is_bang_bang)
	{
		UnaryExpr* outer = ctx.ast.alloc_node(UnaryExpr, { start.start, ctx.current.range.end });
		outer.expr = node;
		outer.operator = UNARYOP_NOT;
		return (Node*)outer;
	}
	return (Node*)node;
}

fn Node* parse_post_unary_expr(ContextScope scope, Node* left, Precedence bp)
{
	ParseContext* ctx = scope.ctx;
	Range start = ctx.current.range;
	PostUnaryExpr* node = ctx.ast.alloc_node(PostUnaryExpr, start);
	defer node.range.end = ctx.peek(-1).range.end;
	UnaryOpKind? op = core::unaryop_from_token(ctx.current.kind);
	if (catch op)
	{
		diagnostics::error(ctx.context, ctx.current.range, "Not a unary operator (%s)", ctx.current.kind);
		error_node(ctx, node);
	}
	else
	{
		node.operator = op;
	}
	node.expr = left;
	advance(ctx);
	return (Node*)node;
}

fn Node* parse_expr_list(ContextScope scope) => @pool()
{
	ParseContext* ctx = scope.ctx;
	ExprList* node = ctx.ast.alloc_node(ExprList, ctx.current.range);
	defer node.range.end = ctx.peek(-1).range.end;
	List{Node*} exprs;
	exprs.tinit();
	while (!ctx.eof())
	{
		exprs.push(parse_decl_or_expr(scope));
		if (ctx.eof() || !consume(ctx, COMMA)) break;
	}

	node.exprs = alloc::clone_slice(ctx.allocator, exprs.array_view());
	return (Node*)node;
}

fn Node* parse_contract_expr(ContextScope scope)
{
	ParseContext* ctx = scope.ctx;
	Range start = ctx.current.range;
	ContractExpr* node = ctx.ast.alloc_node(ContractExpr, start);
	defer node.range.end = ctx.peek(-1).range.end;

	if (ctx.is(LBRACKET))
	{
		advance(ctx);
		if (ctx.is(IDENT) || ctx.is(CT_IDENT) || ctx.is(HASH_IDENT) || ctx.is(TYPE_IDENT))
		{
			advance(ctx);
		}
		(void)consume(ctx, RBRACKET);
	}

	node.exprs = parse_expr_list(scope.with_only_flags(
	{
		.is_contract = true
	}
	));

	if (!ctx.eof() && consume(ctx, COLON))
	{
		if (!ctx.is(STRING_LITERAL))
		{
			diagnostics::error(ctx.context, ctx.current.range, "Expected a string after ':'");
			error_node(ctx, node);
		}

		node.expr_string = parse_expr(scope);
	}

	return (Node*)node;
}

fn Node* parse_call_expr(ContextScope scope, Node* callee)
{
	ParseContext* ctx = scope.ctx;
	Range start = callee.range;
	CallExpr* node = ctx.ast.alloc_node(CallExpr, callee.range);
	defer node.range.end = ctx.peek(-1).range.end;
	expect(ctx, node, LPAREN);
	node.callee = callee;

	diagnostics::log_debug("call_expr: %s", ctx.current.value);

	if (!ctx.is(RPAREN) && !ctx.is(EOS) && !ctx.eof())
	{
		diagnostics::log_debug("call_expr - args");
		node.args = parse_arg_list(scope);
	}

	NodeArray body_args;
	if (consume(ctx, EOS))
	{
		body_args = parse_parameter_list(scope.with_only_flags(
		{
			.is_call = true
		}
		));
	}

	expect(ctx, node, RPAREN);

	if (ctx.is(AT_IDENT) && !scope.flags.is_contract)
	{
		Token t = ctx.current;
		node.attributes = parse_attributes(scope, node);

		foreach (attr : node.attributes)
		{
			AttributeDecl* attr_decl = attr.as(AttributeDecl);
			switch (attr_decl.attribute_kind)
			{
				case AttributeKind.INLINE:
				case AttributeKind.PURE:
				case AttributeKind.NOINLINE:
					break;
				default:
					diagnostics::error(ctx.context, t.range, "Only '@pure', '@inline' and '@noinline' are valid attributes for calls");
					error_node(ctx, attr);
			}
		}
	}
	Node* body = null;
	if (ctx.is(LBRACE))
	{
		body = parse_compound_stmt(scope);
	}

	if (body || body_args)
	{
		MacroBodyExpr* body_node = ctx.ast.alloc_node(MacroBodyExpr, body ? body.range : start);
		body_node.args = body_args;
		body_node.body = body;
		if (body)
		{
			body_node.range.end = body.range.end;
		}
		node.macro_body_expr = body_node;
	}

	return (Node*)node;
}

fn Node* parse_catch_expr(ContextScope scope) => @pool()
{
	ParseContext* ctx = scope.ctx;
	CatchExpr* node = ctx.ast.alloc_node(CatchExpr, ctx.current.range);
	advance(ctx);
	defer node.range.end = ctx.current.range.end;

	Node* sub_expr = parse_try_chain_expr(scope);

	List{Node*} exprs;
	exprs.tinit();

	if (consume(ctx, COMMA))
	{
		exprs.push(sub_expr);
		do
		{
			int pos_start = ctx.pos;
			sub_expr = parse_try_chain_expr(scope);

			if (ctx.pos == pos_start)
			{
				diagnostics::error(ctx.context, ctx.current.range, "Parser failed to advance");
				skip_until(ctx, { COMMA });
			}

			exprs.push(sub_expr);
		}
		while (consume(ctx, COMMA));

		node.exprs = alloc::clone_slice(ctx.allocator, exprs.array_view());
		return node;
	}

	switch (sub_expr.kind)
	{
		case TYPE_EXPR:
			node.type = sub_expr;
			node.variable = parse_try_chain_expr(scope);

			if (node.variable.kind != IDENT_EXPR)
			{
				diagnostics::error(ctx.context, node.variable.range, "Expected variable name");
				node.flags.has_error = true;
			}
		default:
			node.variable = sub_expr;
	}

	if (!consume(ctx, EQ))
	{
		if (node.type)
		{
			diagnostics::error(ctx.context, ctx.current.range, "Expected '=' in catch-unwrap");
			node.flags.has_error = true;
		}

		exprs.push(node.variable);
		node.variable = null;
		return node;
	}

	while (!ctx.eof())
	{
		exprs.push(parse_try_chain_expr(scope));
		if (!consume(ctx, COMMA)) break;
	}

	node.exprs = alloc::clone_slice(ctx.allocator, exprs.array_view());

	return (Node*)node;
}

fn Node* parse_cond_expr(ContextScope scope) => @pool()
{
	ParseContext* ctx = scope.ctx;
	CondExpr* node = ctx.ast.alloc_node(CondExpr, ctx.current.range);
	defer node.range.end = ctx.peek(-1).range.end;

	List{Node*} exprs;
	exprs.tinit();

	while (!ctx.eof())
	{
		switch (ctx.current.kind)
		{
			case TRY:
				exprs.push(parse_try_unwrap_chain_expr(scope));
				if (ctx.is(COMMA))
				{
					diagnostics::error(ctx.context, ctx.current.range, "'catch' must be placed last");
					error_node(ctx, node);
				}
				break;
			case CATCH:
				exprs.push(parse_catch_expr(scope));
				if (ctx.is(COMMA))
				{
					diagnostics::error(ctx.context, ctx.current.range, "'catch' must be placed last");
					error_node(ctx, node);
				}
				break;
			default:
				exprs.push(parse_decl_or_expr(scope));
				if (!consume(ctx, COMMA)) break;
				continue;
		}
		break;
	}

	node.exprs = alloc::clone_slice(ctx.allocator, exprs.array_view());
	return (Node*)node;
}

fn Node* parse_try_expr(ContextScope scope)
{
	ParseContext* ctx = scope.ctx;
	TryExpr* node = ctx.ast.alloc_node(TryExpr, ctx.current.range);
	advance(ctx);
	defer node.range.end = ctx.peek(-1).range.end;

	Node* lhs = parse_try_chain_expr(scope);

	switch (lhs.kind)
	{
		case TYPE_EXPR:
			node.type = lhs;
			node.variable = parse_try_chain_expr(scope);

			if (node.variable.kind != IDENT_EXPR)
			{
				diagnostics::error(ctx.context, node.variable.range, "Expected identifier after type in try-expression");
				node.flags.has_error = true;
			}
		default:
			node.variable = lhs;
	}

	if (consume(ctx, EQ))
	{
		node.init = parse_try_chain_expr(scope);
	}

	return (Node*)node;
}

fn Node* parse_try_unwrap_chain_expr(ContextScope scope)
{
	ParseContext* ctx = scope.ctx;
	Node* first_try      = parse_try_expr(scope);
	Node* current        = first_try;
	TryExpr* current_try = current.as(TryExpr);

	while (consume(ctx, AND))
	{
		Node* next_expr = null;

		switch (ctx.current.kind)
		{
			case TRY:
				next_expr = parse_try_expr(scope);
			default:
				next_expr = parse_try_chain_expr(scope);
		}

		switch (current.kind)
		{
			case TRY_EXPR:
				current.as(TryExpr).next = next_expr;
			default:
				Node* walker = first_try;
				while (walker.kind == TRY_EXPR && walker.as(TryExpr).next != null)
				{
					walker = walker.as(TryExpr).next;
				}
				if (walker.kind == TRY_EXPR)
				{
					walker.as(TryExpr).next = next_expr;
				}
		}

		current = next_expr;
	}

	return first_try;
}

fn Node* parse_ternary_expr(ContextScope scope, Node* left)
{
	ParseContext* ctx = scope.ctx;
	TernaryExpr* node = ctx.ast.alloc_node(TernaryExpr, ctx.current.range);
	defer node.range.end = ctx.peek(-1).range.end;

	node.is_const = ctx.is(CT_TERNARY);
	advance(ctx);
	node.cond = left;

	node.then_expr = parse_expr(scope);

	expect(ctx, node, COLON);

	node.else_expr = parse_expr(scope, TERNARY);

	return (Node*)node;
}

fn Node* parse_builtin_expr(ContextScope scope)
{
	ParseContext* ctx = scope.ctx;
	Range start = ctx.current.range;
	advance(ctx);
	BuiltinFunction builtin;
	bool had_error;

	diagnostics::log_debug("builtin");

	Token t = ctx.current;
	switch (t.kind)
	{
		case IDENT:
		case CONST_IDENT:
		case TYPE_IDENT:
			break;
		default:
			diagnostics::error(ctx.context, t.range, "Expected identifier after '$$'");
			had_error = true;
			break;
	}
	advance(ctx);
	Ident* name = ctx.ident(t);

	switch (t.kind)
	{
		case CONST_IDENT:
			{
				CompilerConstExpr* node = ctx.ast.alloc_node(CompilerConstExpr, ctx.current.range);
				if (had_error) error_node(ctx, node);
				node.name = name;
				return (Node*)node;
			}
		default:
			{
				BuiltinExpr* node = ctx.ast.alloc_node(BuiltinExpr, ctx.current.range);
				if (had_error) error_node(ctx, node);
				node.name = name;
				return (Node*)node;
			}
	}
}

fn Node* parse_splat_expr(ContextScope scope)
{
	ParseContext* ctx = scope.ctx;
	SplatExpr* node = ctx.ast.alloc_node(SplatExpr, ctx.current.range);
	defer node.range.end = ctx.peek(-1).range.end;

	expect(ctx, node, ELLIPSIS);

	node.inner = parse_expr(scope);

	return (Node*)node;
}

fn Node* parse_vasplat_expr(ContextScope scope)
{
	ParseContext* ctx = scope.ctx;
	Range start = ctx.current.range;
	VasplatExpr* node = ctx.ast.alloc_node(VasplatExpr, start);
	defer node.range.end = ctx.peek(-1).range.end;

	expect(ctx, node, ELLIPSIS);
	expect(ctx, node, CT_VAARG);

	if (consume(ctx, LBRACKET))
	{
		diagnostics::log_warn("This is not implemented!");
		advance(ctx);
	}

	return (Node*)node;
}

fn Node* parse_ct_eval_expr(ContextScope scope)
{
	ParseContext* ctx = scope.ctx;
	Range start = ctx.current.range;
	CtEvalExpr* node = ctx.ast.alloc_node(CtEvalExpr, start);
	defer node.range.end = ctx.peek(-1).range.end;

	expect(ctx, node, CT_EVAL);
	expect(ctx, node, LPAREN);
	node.inner_expr = parse_expr(scope);
	expect(ctx, node, RPAREN);

	return (Node*)node;
}

fn Node* parse_lambda_expr(ContextScope scope)
{
	ParseContext* ctx = scope.ctx;
	Range start = ctx.current.range;
	LambdaExpr* node = ctx.ast.alloc_node(LambdaExpr, start);
	defer node.range.end = ctx.peek(-1).range.end;

	node.visibility = LOCAL;
	advance(ctx);
	if (!ctx.is(LPAREN))
	{
		node.return_type = parse_type_expr(scope.with_only_flags(
		{
			.no_generics = true
		}
		), null);
	}
	node.params = parse_parameter_list(scope);
	if (ctx.is(AT_IDENT))
	{
		node.attributes = parse_attributes(scope, node);
	}

	switch (true)
	{
		case consume(ctx, IMPLIES):
			node.body = parse_expr(scope);
		case ctx.is(LBRACE):
			node.body = parse_compound_stmt(scope);
		default:
			diagnostics::error(ctx.context, ctx.current.range, "Expected the beginning of a block or a shortbody");
			error_node(ctx, node);
	}

	return (Node*)node;
}

fn Node* parse_generic_expr(ContextScope scope) => @pool()
{
	ParseContext* ctx = scope.ctx;
	Range start = ctx.current.range;
	GenericIdentExpr* node = ctx.ast.alloc_node(GenericIdentExpr, start);
	defer node.range.end = ctx.peek(-1).range.end;
	expect(ctx, node, LBRACE);
	List{Node*} exprs;
	exprs.tinit();
	do
	{
		exprs.push(parse_expr(scope));
		if (!consume(ctx, COMMA))
		{
			expect(ctx, node, RBRACE);
			break;
		}
	}
	while (!ctx.eof() && !consume(ctx, RBRACE));

	node.exprs = alloc::clone_slice(ctx.allocator, exprs.array_view());
	return (Node*)node;
}

fn Node* parse_group_expr(ContextScope scope)
{
	diagnostics::log_debug("parse_group_expr");
	ParseContext* ctx = scope.ctx;
	Range start = ctx.current.range;

	bool had_error;
	if (!consume(ctx, LPAREN))
	{
		diagnostics::error(ctx.context, ctx.current.range, "Expected '%s' got '%s'", ctx.current.kind.description, ctx.current.kind.description);
		had_error = true;
	}
	Node* inner = parse_expr(scope);
	if (!consume(ctx, RPAREN))
	{
		diagnostics::error(ctx.context, ctx.current.range, "Expected '%s' got '%s'", ctx.current.kind.description, ctx.current.kind.description);
		had_error = true;
	}

	if ((inner.kind == TYPE_EXPR || inner.kind == COMPOUND_LITERAL_EXPR) && can_start_expression(ctx.current.kind))
	{
		diagnostics::log_debug("parse_cast_expr");
		Node* operand = parse_expr(scope, UNARY);

		CastExpr* cast = ctx.ast.alloc_node(CastExpr, { start.start, ctx.peek(-1).range.end });
		cast.inner = inner;
		cast.operand = operand;
		if (had_error) error_node(ctx, cast);
		return (Node*)cast;
	}

	GroupExpr* group = ctx.ast.alloc_node(GroupExpr, { start.start, ctx.peek(-1).range.end });
	if (had_error) error_node(ctx, group);
	group.inner = inner;
	return (Node*)group;
}

fn Node* parse_designator_expr(ContextScope scope)
{
	ParseContext* ctx = scope.ctx;
	Node* path;

	while (true)
	{
		switch (ctx.current.kind)
		{
			case DOT:
				{
					Range start = ctx.current.range;
					advance(ctx);

					Node* field = parse_expr(scope, HIGHEST);

					DesignatorExpr* node = ctx.ast.alloc_node(DesignatorExpr, start);
					node.range.end = ctx.current.range.end;

					node.designator_kind = DesignatorKind.PERIOD;
					node.path = path;
					node.data.field = field;

					path = (Node*)node;
					continue;
				}
			case LBRACKET:
				{
					Range start = ctx.current.range;
					advance(ctx);
					Node* designator_node = parse_range_expr(scope, path, path ? path.range : start);
					path = designator_node;
					continue;
				}
			default:
				break;
		}

		break;
	}

	return path;
}

fn Node* parse_initializer_list_expr(ContextScope scope) => @pool()
{
	ParseContext* ctx = scope.ctx;
	Range start = ctx.current.range;
	InitializerListExpr* node = ctx.ast.alloc_node(InitializerListExpr, start);
	defer node.range.end = ctx.peek(-1).range.end;

	expect(ctx, node, LBRACE);

	if (consume(ctx, RBRACE))
	{
		return node;
	}

	List{Node*} exprs;
	exprs.tinit();

	while (!ctx.eof())
	{
		Node* expr;

		switch (true)
		{
			case ctx.is(ELLIPSIS):
				switch (ctx.peek(1).kind)
				{
				case CT_VAARG:
					expr = parse_vasplat_expr(scope);
				default:
					expr = parse_prefix_expr_only(scope);
			}
			case ctx.is(DOT) || ctx.is(LBRACKET):
				Token path_token = ctx.current;
				Node* des_expr   = parse_designator_expr(scope);

				switch (consume(ctx, EQ))
				{
				case true:
					Node* val = parse_expr(scope);
					DesignatedInitializerExpr* des_init_node = ctx.ast.alloc_node(DesignatedInitializerExpr, path_token.range);
					des_init_node.range.end = ctx.current.range.end;

					des_init_node.path = des_expr;
					des_init_node.value = val;

					expr = (Node*)des_init_node;
				case false:
					expr = des_expr;
			}
			case ctx.is(LBRACE):
				expr = parse_initializer_list_expr(scope);
			default:
				expr = parse_expr(scope);
		}

		exprs.push(expr);

		if (consume(ctx, RBRACE)) break;
		expect(ctx, node, COMMA);
		if (ctx.is(RBRACE))
		{
			advance(ctx);
			break;
		}
	}

	node.exprs = alloc::clone_slice(ctx.allocator, exprs.array_view());

	return (Node*)node;
}

fn Node* parse_access_expr(ContextScope scope, Node* left)
{
	ParseContext* ctx = scope.ctx;
	Range start = left.range;
	TokenKind op_kind      = ctx.current.kind;
	AccessKind access_kind = (op_kind == TokenKind.SCOPE) ? AccessKind.STATIC : AccessKind.INSTANCE;
	advance(ctx);
	Token member_token = ctx.current;

	diagnostics::log_debug("parse_access_expr");

	if (member_token.kind == LBRACKET)
	{
		advance(ctx);
		MaybeDerefExpr* deref_node = ctx.ast.alloc_node(MaybeDerefExpr, { start.start, ctx.current.range.end });
		deref_node.left = left;
		return parse_range_expr(scope, (Node*)deref_node, deref_node.range);
	}

	AccessExpr* node = ctx.ast.alloc_node(AccessExpr, start);
	defer node.range.end = ctx.peek(-1).range.end;

	node.access_kind = access_kind;
	node.left = left;

	switch (member_token.kind)
	{
		case CT_EVAL:
			advance(ctx);
			expect(ctx, (Node*)node, LPAREN);
			node.member = parse_expr(scope.with_only_flags(
			{
				.type_as_expression = true
			}
			));
			expect(ctx, (Node*)node, RPAREN);
			break;
		case IDENT:
		case CONST_IDENT:
		case TYPE_IDENT:
		case CT_IDENT:
		case AT_IDENT:
		case TYPEID_TYPE:
		case FAULT_TYPE:
		case LENGTHOF:
		case VOID_TYPE:
		case ANY_TYPE:
		case BOOL_TYPE:
		case CHAR_TYPE:
		case INT_TYPE:
		case UINT_TYPE:
		case LONG_TYPE:
		case ULONG_TYPE:
		case FLOAT_TYPE:
		case DOUBLE_TYPE:
		case SZ_TYPE:
		case USZ_TYPE:
		case IPTR_TYPE:
		case UPTR_TYPE:
			{
				IdentExpr* ident = ctx.ast.alloc_node(IdentExpr, member_token.range);
				ident.ident = ctx.ident(member_token);
				advance(ctx);
				node.member = (Node*)ident;
				break;
			}
		default:
			diagnostics::error(ctx.context, member_token.range, "Expected member identifier after '.'");
			node.member = ctx.ast.error(member_token.range);
			break;
	}

	return (Node*)node;
}

fn Node* parse_range_expr(ContextScope scope, Node* left, Range start)
{
	ParseContext* ctx = scope.ctx;

	DesignatorExpr* designator_node = ctx.ast.alloc_node(DesignatorExpr, start);
	defer designator_node.range.end = ctx.peek(-1).range.end;

	RangeExpr* range_node = ctx.ast.alloc_node(RangeExpr, start);

	designator_node.path = left;
	designator_node.data.range = range_node;

	bool is_slice = false;
	TokenKind op_kind = TokenKind.EOS;

	if (ctx.is(COLON) || ctx.is(DOTDOT))
	{
		is_slice = true;
		op_kind = ctx.current.kind;
		advance(ctx);
	}
	else
	{
		if (consume(ctx, BIT_XOR))
		{
			range_node.start_from_end = true;
		}

		range_node.start = parse_expr(scope, LOWEST);

		if (ctx.is(COLON) || ctx.is(DOTDOT))
		{
			is_slice = true;
			op_kind = ctx.current.kind;
			advance(ctx);
		}
	}

	if (is_slice && !ctx.is(RBRACKET))
	{
		if (consume(ctx, BIT_XOR))
		{
			range_node.end_from_end = true;
		}

		range_node.end = parse_expr(scope, LOWEST);
	}

	expect(ctx, designator_node, RBRACKET);
	range_node.range.end = ctx.peek(-1).range.end;

	switch (is_slice)
	{
		case true:
			designator_node.designator_kind = DesignatorKind.RANGE;

			switch (op_kind)
			{
			case COLON:
				range_node.range_kind = RangeKind.CONST_LEN;
			default:
				switch (true)
				{
				case range_node.start != null && range_node.end != null:
					range_node.range_kind = RangeKind.CONST_RANGE;
				case range_node.end != null:
					range_node.range_kind = RangeKind.CONST_END;
				default:
					range_node.range_kind = RangeKind.DYNAMIC;
			}
		}
		case false:
			designator_node.designator_kind = DesignatorKind.INDEX;
			range_node.range_kind = RangeKind.SINGLE_ELEMENT;
	}

	return (Node*)designator_node;
}

fn Node* parse_raise_suffix_expr(ContextScope scope, Node* left, Token left_token)
{
	ParseContext* ctx = scope.ctx;
	switch (left.kind)
	{
		case TYPE_EXPR:
			advance(ctx);
			diagnostics::error(ctx.context, left_token.range, "Expected a fault before '~'");
			return ctx.ast.error(ctx.current.range);
		default:
			break;
	}
	Range start = ctx.current.range;
	OptionalExpr* node = ctx.ast.alloc_node(OptionalExpr, start);
	defer node.range.end = ctx.peek(-1).range.end;
	expect(ctx, node, BIT_NOT);
	node.inner_expr = left;
	return (Node*)node;
}

fn Node* parse_ct_defined_expr(ContextScope scope) => @pool()
{
	ParseContext* ctx = scope.ctx;
	Range start = ctx.current.range;
	advance(ctx);
	CtDefinedExpr* node = ctx.ast.alloc_node(CtDefinedExpr, start);
	defer node.range.end = ctx.peek(-1).range.end;

	expect(ctx, node, LPAREN);

	List{Node*} exprs;
	exprs.tinit();
	while (!ctx.eof() && !consume(ctx, RPAREN))
	{
		exprs.push(parse_decl_or_expr(scope));
		if (!consume(ctx, COMMA))
		{
			expect(ctx, node, RPAREN);
			break;
		}
	}

	node.expr_list = alloc::clone_slice(ctx.allocator, exprs.array_view());

	return (Node*)node;
}

fn Node* parse_ct_feature(ContextScope scope)
{
	ParseContext* ctx = scope.ctx;
	Range start = ctx.current.range;
	advance(ctx);
	CtFeatureExpr* node = ctx.ast.alloc_node(CtFeatureExpr, start);
	defer node.range.end = ctx.peek(-1).range.end;

	expect(ctx, node, LPAREN);
	node.inner_expr = parse_expr(scope);
	expect(ctx, node, RPAREN);

	return (Node*)node;
}

fn Node* parse_lengthof_expr(ContextScope scope)
{
	ParseContext* ctx = scope.ctx;
	Range start = ctx.current.range;
	advance(ctx);
	LengthofExpr* node = ctx.ast.alloc_node(LengthofExpr, start);
	defer node.range.end = ctx.peek(-1).range.end;

	expect(ctx, node, LPAREN);
	node.inner_expr = parse_expr(scope);
	expect(ctx, node, RPAREN);

	return (Node*)node;
}

fn Node* parse_ct_stringify_expr(ContextScope scope)
{
	ParseContext* ctx = scope.ctx;
	Range start = ctx.current.range;
	advance(ctx);
	CtStringifyExpr* node = ctx.ast.alloc_node(CtStringifyExpr, start);
	defer node.range.end = ctx.peek(-1).range.end;

	expect(ctx, node, LPAREN);
	node.inner_expr = parse_expr(scope);
	expect(ctx, node, RPAREN);
	return (Node*)node;
}

fn Node* parse_vaarg_expr(ContextScope scope)
{
	ParseContext* ctx = scope.ctx;
	Range start = ctx.current.range;
	advance(ctx);
	VaargExpr* node = ctx.ast.alloc_node(VaargExpr, start);
	defer node.range.end = ctx.peek(-1).range.end;

	if (consume(ctx, DOT))
	{
		String token_text = ctx.current.value;
		if (!ctx.is(IDENT) || token_text != constants::KW_LEN)
		{
			diagnostics::error(ctx.context, ctx.current.range, "Expected '.%s' after '$vaarg'", constants::KW_LEN);
			error_node(ctx, node);
		}
		advance(ctx);
		node.vaarg_kind = VACOUNT;
		return node;
	}

	expect(ctx, node, LBRACKET);
	node.start_from_end = consume(ctx, BIT_XOR);
	node.expr = parse_expr(scope);
	expect(ctx, node, RBRACKET);
	return (Node*)node;
}

fn Node* parse_ct_reflect_expr(ContextScope scope)
{
	ParseContext* ctx = scope.ctx;
	Range start = ctx.current.range;
	advance(ctx);
	CtReflectExpr* node = ctx.ast.alloc_node(CtReflectExpr, start);
	defer node.range.end = ctx.peek(-1).range.end;

	expect(ctx, node, LPAREN);
	node.inner_expr = parse_expr(scope);
	expect(ctx, node, RPAREN);
	return node;
}
