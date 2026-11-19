module analyzer::parser;
import std::io, std::io::path, std::collections::list;
import analyzer::core, analyzer::lexer;

struct ContextScope
{
	ParseContext* ctx;
	ParseFlags flags;
}

fn ContextScope ContextScope.with_flags(&self, ParseFlags flags)
{
	return {
		.ctx = self.ctx,
		.flags = self.flags | flags
	};
}

fn ContextScope ContextScope.with_only_flags(&self, ParseFlags flags)
{
	return {
		.ctx = self.ctx,
		.flags = flags
	};
}

fn bool is_token_start_of_decl(TokenKind kind)
{
	switch (kind)
	{
		case DOCS_START:
		case INTERFACE:
		case MODULE:
		case IMPORT:
		case FAULTDEF:
		case FN:
		case MACRO:
		case ALIAS:
		case TYPEDEF:
		case ATTRDEF:
		case UNION:
		case STRUCT:
		case BITSTRUCT:
		case CONSTDEF:
		case ENUM:
		case CONST:
		case CT_EXPAND:
		case CT_ASSERT:
		case CT_ECHO:
		case CT_ERROR:
		case EXTERN:
		case TLOCAL:
		case INLINE:
		case STATIC:
			return true;
		default:
			return false;
	}
}

fn bool is_token_start_of_stmt(TokenKind kind)
{
	switch (kind)
	{
		case LBRACE:
		case SWITCH:
		case CONTINUE:
		case BREAK:
		case NEXTCASE:
		case RETURN:
		case DEFER:
		case CT_SWITCH:
		case IF:
		case CT_IF:
		case FOR:
		case CT_FOR:
		case WHILE:
		case DO:
		case FOREACH:
		case FOREACH_R:
		case CT_FOREACH:
		case CT_ASSERT:
		case CT_ERROR:
		case CT_ECHO:
		case VAR:
		case CONST:
		case STATIC:
		case TLOCAL:
		case ASSERT:
		case CT_EXPAND:
		case ASM:
		case HASH_IDENT:
		case IDENT:
		case CONST_IDENT:
		case AMP:
		case AT_CONST_IDENT:
		case AT_IDENT:
		case AT_TYPE_IDENT:
		case BANG:
		case BIT_NOT:
		case BIT_OR:
		case BIT_XOR:
		case BUILTIN:
		case BYTES_LITERAL:
		case CHAR_LITERAL:
		case CT_AND_OP:
		case CT_CONCAT_OP:
		case CT_CONCAT_ASSIGN:
		case CT_CONST_IDENT:
		case CT_DEFINED:
		case CT_EMBED:
		case CT_EVAL:
		case CT_FEATURE:
		case CT_IDENT:
		case CT_OR_OP:
		case CT_REFLECT:
		case CT_STRINGIFY:
		case CT_TERNARY:
		case CT_VAARG:
		case FALSE:
		case INT_DECIMAL_LITERAL:
		case INT_BIN_LITERAL:
		case INT_HEX_LITERAL:
		case INT_OCTAL_LITERAL:
		case LENGTHOF:
		case LPAREN:
		case MINUS:
		case MINUSMINUS:
		case NULL:
		case OR:
		case PLUS:
		case PLUSPLUS:
		case FLOAT_DECIMAL_LITERAL:
		case FLOAT_HEX_LITERAL:
		case ASTERISK:
		case STRING_LITERAL:
		case TRUE:
			return true;
		default:
			return false;
	}
}

fn void skip_until(ParseContext* ctx, TokenKind[] targets)
{
	int brace_depth = 0;
	while (!ctx.eof())
	{
		switch (ctx.current.kind)
		{
			case LBRACE:
				brace_depth++;
			case RBRACE:
				brace_depth--;
			default:
				break;
		}

		if (brace_depth <= 0)
		{
			foreach (TokenKind target : targets)
			{
				if (ctx.is(target)) return;
			}
			if (is_token_start_of_decl(ctx.current.kind)) return;
		}

		if (brace_depth < 0) return;

		advance(ctx);
	}
}

enum SyncTarget
{
	DECLARATION,
	STATEMENT
}

fn void synchronize(ParseContext* ctx, SyncTarget target)
{
	if (!ctx.eof()) advance(ctx);

	while (!ctx.eof())
	{
		if (ctx.is(EOS))
		{
			advance(ctx);
			return;
		}

		switch (target)
		{
			case DECLARATION:
				if (is_token_start_of_decl(ctx.current.kind)) return;
			case STATEMENT:
				if (is_token_start_of_decl(ctx.current.kind) || is_token_start_of_stmt(ctx.current.kind)) return;
		}

		advance(ctx);
	}
}

<*
 Expression the tokens of `sf` within `range` form, parsed on their own so
 that the code around them, complete or not, does not change how they
 parse. Null unless they form exactly one expression.
*>
fn Node* parse_expression(AnalyzerContext* context, SourceFile* sf, Range range)
{
	if (!sf.lexer) return null;
	Token[] tokens = sf.lexer.tokens.array_view();
	sz first = sf.lexer.first_token_at(range.start);
	sz end = first;
	while (end < tokens.len && tokens[end].range.start.before(range.end)) end++;
	if (end == first) return null;

	Lexer fragment = { .ctx = context, .buffer = sf.content };
	fragment.tokens.init(tmem, end - first + 1);
	fragment.tokens.push_all(tokens[first:end - first]);
	fragment.tokens.push({ .kind = EOF, .range = { range.end, range.end } });
	Ast ast = { .allocator = tmem };
	ast.nodes.init(tmem);
	ast.statements.init(tmem);
	ParseContext ctx = { .context = context, .sf = sf, .ast = &ast, .lexer = &fragment, .allocator = tmem, .current = fragment.tokens[0] };

	Node* expr = parse_expr({ .ctx = &ctx });
	if (!expr || expr.kind == ERROR || !ctx.current.is_eof()) return null;
	return expr;
}


fn bool ParseContext.eof(&self) @inline => self.pos >= self.lexer.tokens.len() || self.current.is_eof();

fn bool ParseContext.is(&self, TokenKind kind)
{
	return self.peek(0).kind == kind;
}

fn Token ParseContext.peek(&self, int pos) @inline
{
	if (self.pos + pos >= (int)self.lexer.tokens.len())
	{
		return self.lexer.tokens.last()!!;
	}
	if (self.pos + pos < 0)
	{
		return self.lexer.tokens.first()!!;
	}
	return self.lexer.tokens[(sz)self.pos + pos];
}

fn Ident* ParseContext.ident(&self, Token t) @inline
{
	Ident* ident = alloc::new(self.allocator, Ident);
	*ident = {
		.range = t.range,
		.text = t.value.copy(self.allocator)
	};

	return ident;
}

fn Ident* ParseContext.ident_string(&self, String str) @inline
{
	Ident* ident = alloc::new(self.allocator, Ident);
	*ident = {
		.text = str.copy(self.allocator)
	};
	return ident;
}

fn void advance(ParseContext* ctx, int len = 1)
{
	ctx.pos += len;

	if (ctx.pos >= ctx.lexer.tokens.len())
	{
		ctx.pos = (int)ctx.lexer.tokens.len() - 1;
	}

	ctx.current = ctx.lexer.tokens[ctx.pos];
}

macro Token expect(ParseContext* ctx, Node* node, TokenKind kind)
{
	if (ctx.is(kind))
	{
		advance(ctx);
		return ctx.peek(-1);
	}

	diagnostics::error(ctx.context, ctx.current.range,
	"Expected '%s' got '%s'", kind.description, ctx.current.kind.description);
	node.flags.has_error = true;
	ctx.error_count++;
	return {
		.kind = ERROR,
		.range = ctx.current.range,
		.value = "<error>"
	};
}

fn bool consume(ParseContext* ctx, TokenKind kind)
{
	if (ctx.is(kind))
	{
		advance(ctx);
		return true;
	}

	return false;
}

fn bool parse(ParseContext* ctx, SourceFile* source_file) => @pool()
{
	ctx.allocator = &source_file.arena;
	ctx.lexer = source_file.lexer;
	ctx.ast = &source_file.ast;
	ctx.context.current_source_file = source_file;
	ctx.current_section_visibility = Visibility.PUBLIC;

	if (ctx.lexer.tokens.last()!!.kind != EOF)
	{
		return false;
	}

	ctx.current = ctx.lexer.tokens[0];

	while (!ctx.eof())
	{
		int pos = ctx.pos;
		Node* node = parse_top_level_statement(ctx);
		if (ctx.pos == pos)
		{
			advance(ctx);
			continue;
		}
		if (!node) continue;
		ctx.ast.statements.push(node);
		if (ctx.contract && node.kind != CONTRACT_DECL)
		{
			// An attached contract belongs to its declaration: it is reached
			// through the declaration, whose range covers it.
			if (attach_contract(ctx, node, ctx.contract))
			{
				ctx.ast.statements.remove_last_item(ctx.contract);
				node.range.start = ctx.contract.range.start;
			}
			ctx.contract = null;
		}
	}
	foreach (i, stmt : ctx.ast.statements)
	{
		if (stmt.kind == MODULE_DECL) ctx.ast.module_decls.push(i);
	}

	return ctx.error_count == 0;
}

fn void update_section_visibility(ParseContext* ctx, ModuleDecl* md)
{
	Visibility sec_vis = Visibility.PUBLIC;
	foreach (attr : md.attributes)
	{
		if (attr && attr.kind == ATTRIBUTE_DECL)
		{
			AttributeDecl* ad = attr.as(AttributeDecl);
			switch (ad.attribute_kind)
			{
				case PRIVATE: sec_vis = PRIVATE;
				case LOCAL:   sec_vis = LOCAL;
				case PUBLIC:  sec_vis = PUBLIC;
				default:
			}
		}
	}
	ctx.current_section_visibility = sec_vis;
}

fn void apply_section_visibility_default(ParseContext* ctx, Node* node)
{
	if (!node || ctx.current_section_visibility == Visibility.PUBLIC) return;

	NodeArray attrs;
	switch (node.kind)
	{
		case FN_DECL: attrs = node.as(FnDecl).attributes;
		case MACRO_DECL: attrs = node.as(MacroDecl).attributes;
		case STRUCT_DECL: attrs = node.as(StructDecl).attributes;
		case ENUM_DECL: attrs = node.as(EnumDecl).attributes;
		case VAR_DECL: attrs = node.as(VarDecl).attributes;
		case TYPEDEF_DECL: attrs = node.as(TypedefDecl).attributes;
		case ALIAS_DECL: attrs = node.as(AliasDecl).attributes;
		case INTERFACE_DECL: attrs = node.as(InterfaceDecl).attributes;
		case ATTRDEF_DECL: attrs = node.as(AttrdefDecl).attributes;
		default: break;
	}

	bool has_explicit_vis = false;
	foreach (attr : attrs)
	{
		if (!attr || attr.kind != ATTRIBUTE_DECL) continue;
		AttributeDecl* ad = attr.as(AttributeDecl);
		if (ad.attribute_kind == AttributeKind.PUBLIC || ad.attribute_kind == AttributeKind.PRIVATE || ad.attribute_kind == AttributeKind.LOCAL)
		{
			has_explicit_vis = true;
			break;
		}
	}

	if (!has_explicit_vis)
	{
		node.visibility = ctx.current_section_visibility;
	}
}

<*
 Moves the start of `node` back to `start`, the first of the modifiers parsed before it.
*>
fn Node* starting_at(Node* node, Location start) @inline
{
	if (node) node.range.start = start;
	return node;
}

fn Node* parse_top_level_statement(ParseContext* ctx)
{
	Node* node = null;
	ContextScope scope = {
		.ctx = ctx
	};
	Location decl_start = ctx.current.range.start;

	while (true)
	{
		Token t = ctx.current;

		switch (t.kind)
		{
			case EXTERN:
				scope.flags.is_extern = true;
				advance(ctx);
				continue;
			case TLOCAL:
				scope.flags.is_thread_local = true;
				advance(ctx);
				continue;
			case INLINE:
				scope.flags.is_inline = true;
				advance(ctx);
				continue;
			case STATIC:
				scope.flags.is_static = true;
				advance(ctx);
				continue;
			default:
				break;
		}
		break;
	}

	if (is_type(ctx))
	{
		node = starting_at(parse_var_decl(scope, null), decl_start);
		apply_section_visibility_default(ctx, node);
		return node;
	}

	switch (ctx.current.kind)
	{
		case DOCS_START:
			if (ctx.contract)
			{
				diagnostics::error(ctx.context, ctx.current.range, "Multiple doc comments in sequence are not allowed.");
				node = ctx.ast.error(ctx.current.range);
				ctx.error_count++;
				skip_until(ctx, { DOCS_END, EOF });
				advance(ctx);
				break;
			}
			node = parse_contract_decl(scope);
			ctx.contract = node;
		case INTERFACE:
			node = parse_interface_decl(scope);
		case MODULE:
			node = parse_module_decl(scope);
			if (node && node.kind == MODULE_DECL)
			{
				update_section_visibility(ctx, node.as(ModuleDecl));
			}
		case IMPORT:
			node = parse_import_decl(scope);
		case FAULTDEF:
			node = parse_faultdef_decl(scope);
		case FN:
			node = parse_fn_decl(scope);
		case MACRO:
			node = parse_macro_decl(scope);
		case ALIAS:
			node = parse_alias_decl(scope);
		case TYPEDEF:
			node = parse_typedef_decl(scope);
		case ATTRDEF:
			node = parse_attrdef_decl(scope);
		case UNION:
		case STRUCT:
			node = parse_struct_union_decl(scope);
		case BITSTRUCT:
			node = parse_bitstruct_decl(scope);
		case CONSTDEF:
			node = parse_enum_constdef_decl(scope.with_flags(
			{
				.is_constdef = true
			}
			));
		case ENUM:
			node = parse_enum_constdef_decl(scope);
		case CONST:
			advance(ctx);
			node = parse_var_decl(scope.with_flags(
			{
				.is_const = true
			}
			), null);
		case CT_EXPAND:
			node = parse_expand_decl(scope);
		case CT_ASSERT:
			Range start = ctx.peek(0).range;
			Node* stmt = parse_ct_assert_stmt(scope);
			node = (Node*)ctx.ast.alloc_node(CtAssertDecl, start);
			node.range.end = ctx.peek(-1).range.end;
			CtAssertDecl* ctassert = node.as(CtAssertDecl);
			ctassert.stmt = stmt;
		case CT_ECHO:
			node = parse_ct_echo_stmt(scope);
		case CT_ERROR:
			node = parse_ct_error_stmt(scope);
		default:
			diagnostics::error(ctx.context, ctx.current.range, "Expected the start of a global declaration here");
			ctx.error_count++;
			synchronize(ctx, DECLARATION);
			break;
	}

	starting_at(node, decl_start);
	apply_section_visibility_default(ctx, node);
	return node;
}

<*
 @return "false when `node` cannot carry a contract"
*>
fn bool attach_contract(ParseContext* ctx, Node* node, Node* contract)
{
	switch (node.kind)
	{
		case MODULE_DECL:
			ModuleDecl* mod = node.as(ModuleDecl);
			mod.contract.set(contract);
		case FN_DECL:
			FnDecl* func = node.as(FnDecl);
			func.contract.set(contract);
		case MACRO_DECL:
			MacroDecl* mac = node.as(MacroDecl);
			mac.contract.set(contract);
		case STRUCT_DECL:
			StructDecl* sd = node.as(StructDecl);
			sd.contract.set(contract);
		case INTERFACE_DECL:
			InterfaceDecl* id = node.as(InterfaceDecl);
			id.contract.set(contract);
		case FAULTDEF_DECL:
			FaultdefDecl* fd = node.as(FaultdefDecl);
			fd.contract.set(contract);
		case VAR_DECL:
			VarDecl* vd = node.as(VarDecl);
			vd.contract.set(contract);
		case ENUM_DECL:
			EnumDecl* ed = node.as(EnumDecl);
			ed.contract.set(contract);
		case ALIAS_DECL:
			AliasDecl* ad = node.as(AliasDecl);
			ad.contract.set(contract);
		case TYPEDEF_DECL:
			TypedefDecl* td = node.as(TypedefDecl);
			td.contract.set(contract);
		default:
			return false;
	}
	return true;
}

fn void error_node(ParseContext* ctx, Node* node)
{
	node.flags.has_error = true;
	ctx.error_count++;
}
