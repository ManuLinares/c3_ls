module analyzer::parser;

import std::io;
import std::collections::list;
import analyzer::core;
import analyzer::lexer;

fn bool is_keyword_ident(TokenKind type)
{
	return type.is_keyword();
}

fn bool is_base_type(TokenKind kind)
{
	return kind.is_base_type();
}

fn bool is_non_type_ident(TokenKind k)
{
	return k == IDENT || k == HASH_IDENT || k == CT_IDENT;
}

fn bool is_type(ParseContext* ctx)
{
	TokenKind kind = ctx.current.kind;

	if (is_type_primitive(kind)) return true;
	if (kind == TYPE_IDENT) return true;

	if (kind == IDENT && ctx.peek(1).kind == SCOPE)
	{
		int i = 2;
		while (ctx.peek(i).kind == IDENT && ctx.peek(i + 1).kind == SCOPE)
		{
			i += 2;
		}
		if (ctx.peek(i).kind == TYPE_IDENT) return true;
	}

	return false;
}

<*
 Index of the token after the group opened by `open` at `ctx.peek(i)`.
*>
fn int skip_group(ParseContext* ctx, int i, TokenKind open, TokenKind close) @local
{
	int depth = 0;
	for (; !ctx.peek(i).is_eof(); i++)
	{
		TokenKind k = ctx.peek(i).kind;
		if (k == open) depth++;
		if (k == close && --depth == 0) return i + 1;
	}
	return i;
}

<*
 Whether the tokens at the cursor are a type followed by a name, which
 starts a declaration and never continues an expression.
*>
fn bool starts_declaration(ParseContext* ctx)
{
	if (!is_type(ctx)) return false;
	int i;
	switch (ctx.current.kind)
	{
		case CT_TYPEOF:
		case CT_TYPEFROM:
			i = skip_group(ctx, 1, LPAREN, RPAREN);
		default:
			if (is_type_primitive(ctx.current.kind))
			{
				i = 1;
				break;
			}
			while (ctx.peek(i).kind == IDENT && ctx.peek(i + 1).kind == SCOPE) i += 2;
			i++;
	}
	while (true)
	{
		switch (ctx.peek(i).kind)
		{
			case QUESTION:
			case ASTERISK:
				i++;
			case LBRACKET:
				i = skip_group(ctx, i, LBRACKET, RBRACKET);
			case LVEC:
				i = skip_group(ctx, i, LVEC, RVEC);
			case LBRACE:
				i = skip_group(ctx, i, LBRACE, RBRACE);
			case IDENT:
			case CT_IDENT:
				return true;
			default:
				return false;
		}
	}
}

<*
 Append an arena-owned node slice into a temporary node list.
 @param [&inout] list : "Destination list."
 @param nodes : "Nodes to append."
*>
fn void append_node_array(List{Node*} * list, NodeArray nodes)
{
	foreach (node : nodes)
	{
		list.push(node);
	}
}

<*
 Parse attributes at the current token and append them into an existing list.
 @require(scope.ctx != null) : "Parser context to consume attributes from."
 @param [&inout] parent_node : "Node receiving visibility and has-attributes side effects."
 @param [&inout] list : "Destination list for parsed ATTRIBUTE_DECL nodes."
*>
fn void parse_attributes_into(ContextScope scope, Node* parent_node, List{Node*} * list, AttributeParseFlags flags = {})
{
	ParseContext* ctx = scope.ctx;
	if (ctx.is(AT_IDENT) || ctx.is(AT_TYPE_IDENT))
	{
		append_node_array(list, parse_attributes(scope, parent_node, flags));
	}
}

fn bool is_type_primitive(TokenKind kind)
{
	return kind.is_base_type() || kind == CT_TYPE_IDENT || kind == CT_TYPEOF || kind == CT_TYPEFROM;
}

fn bool can_start_expression(TokenKind kind)
{
	diagnostics::log_debug("can_start_expr: %s", kind.description);

	if (is_keyword_ident(kind) || is_base_type(kind) || is_type_primitive(kind))
	{
		return true;
	}

	switch (kind)
	{
		case IDENT:
		case AT_IDENT:
		case TYPE_IDENT:
		case CT_TYPE_IDENT:
		case CT_IDENT:
		case CONST_IDENT:
		case HASH_IDENT:
		case HASH_TYPE_IDENT:
		case HASH_CONST_IDENT:
		case BUILTIN:
		case CT_EVAL:
		case CT_EMBED:
		case CT_DEFINED:
		case CT_FEATURE:
		case CT_STRINGIFY:
		case CT_VAARG:
		case CT_REFLECT:
		case LENGTHOF:
		case FN:
		case ELLIPSIS:
		case FLOAT_DECIMAL_LITERAL:
		case FLOAT_HEX_LITERAL:
		case INT_DECIMAL_LITERAL:
		case INT_HEX_LITERAL:
		case INT_OCTAL_LITERAL:
		case INT_BIN_LITERAL:
		case STRING_LITERAL:
		case CHAR_LITERAL:
		case BYTES_LITERAL:
		case TRUE:
		case FALSE:
		case NULL:
		case LPAREN:
		case PLUS:
		case PLUSPLUS:
		case MINUS:
		case MINUSMINUS:
		case BANG:
		case BANGBANG:
		case BIT_NOT:
		case AMP:
		case AND:
		case ASTERISK:
		case LBRACE:
			return true;
		default:
			return false;
	}
}

fn bool token_type_ends_case(TokenKind kind)
{
	return kind == CASE || kind == DEFAULT || kind == CT_DEFAULT || kind == RBRACE || kind == CT_CASE
	|| kind == CT_ENDSWITCH;
}

fn bool check_if_typed_parameter(ParseContext* ctx)
{
	TokenKind first = ctx.current.kind;

	if (first == CT_TYPE_IDENT)
	{
		TokenKind next = ctx.peek(1).kind;
		if (next == COMMA || next == RPAREN || next == EQ || next == EOS)
		{
			return false;
		}
		return true;
	}

	return is_type(ctx) || first == FN;
}

fn Node* alloc_any_type_expr(ParseContext* ctx)
{
	TypeExpr* type_node = ctx.ast.alloc_node(TypeExpr, ctx.current.range);

	type_node.type_kind = TYPE_IDENTIFIER;
	type_node.unresolved.name = ctx.ident_string("any");
	type_node.unresolved.name.range = ctx.current.range;

	return type_node;
}
