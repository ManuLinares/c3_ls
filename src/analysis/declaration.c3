module lsp::analysis::declaration;
import analyzer, lsp, std::sort;

<*
 Signature of `node` for hover, completion and signature help.
 Declarations render as written; other nodes, such as attribute uses, as `name` with what is known of them.
*>
fn String signature(AnalyzerContext* ctx, Node* node, String name, bool single_line = false)
{
	switch (node.kind)
	{
		case PATH_EXPR:
			PathExpr* pe = node.as(PathExpr);
			return string::tformat("module %s", pe.path ? pe.path.text.strip_suffix("::") : name);
		case TYPE_EXPR:
			return string::tformat("type %s", name);
		case TRY_EXPR:
			String vtype = cursor::spelling(node.as(TryExpr).type, tmem);
			if (!vtype.len && node.resolved_type) vtype = node.resolved_type.name;
			return string::tformat("try %s %s", vtype ?: "var", name);
		case CATCH_EXPR:
			return string::tformat("catch %s %s", cursor::spelling(node.as(CatchExpr).type, tmem) ?: "fault", name);
		case ATTRIBUTE_DECL:
			AttributeDecl* attr = node.as(AttributeDecl);
			if (!attr.exprs.len) return string::tformat("attribute %s", name);
			DString out;
			out.tinit();
			out.appendf("attribute %s(", name);
			foreach (i, expr : attr.exprs)
			{
				if (i > 0) out.append(", ");
				out.append(cursor::spelling(expr, tmem) ?: "...");
			}
			out.append(")");
			return out.str_view();
		case VAR_DECL:
			VarDecl* vd = node.as(VarDecl);
			if (vd.var_flags.is_self) return string::tformat("%s %s", cursor::spelling(vd.type, tmem), name);
			if (EnumDecl* owner = owner_enum(ctx, node)) return string::tformat("%s.%s", owner.name.text, text(ctx, node, single_line) ?: name);
		case FAULT_DECL:
			return string::tformat("fault %s", text(ctx, node, single_line) ?: name);
		default:
			break;
	}
	return text(ctx, node, single_line) ?: name;
}

<*
 Markdown block with the signature of `node`, followed by its module when it is not local.
*>
fn String header(AnalyzerContext* ctx, Node* node, String name)
{
	String sig = signature(ctx, node, name);
	String mod = module_name(ctx, node);
	if (!mod.len) return string::tformat("```c3\n%s\n```", sig);
	return string::tformat("```c3\n%s\n```\nmodule `%s`", sig, mod);
}

<*
 Doc comment of `node` ready for display, or empty.
*>
fn String docs(Node* node)
{
	String doc = cursor::docs(node) ?? "";
	return doc.trim().treplace("\"", "");
}

<*
 Enum or constdef declaring the value `node`, or null.
*>
fn EnumDecl* owner_enum(AnalyzerContext* ctx, Node* node) @local
{
	SourceFile* sf = source_file::file_of(ctx, node);
	if (!sf) return null;
	foreach (stmt : sf.ast.statements)
	{
		if (!stmt || stmt.kind != ENUM_DECL || !stmt.range.contains_range(node.range)) continue;
		EnumDecl* ed = stmt.as(EnumDecl);
		foreach (v : ed.variants) if (v == node) return ed.name ? ed : null;
	}
	return null;
}

<*
 Module declaring `node`, or empty for locals, parameters and nodes without a source file.
*>
fn String module_name(AnalyzerContext* ctx, Node* node) @local
{
	switch (node.kind)
	{
		case PATH_EXPR:
		case MODULE_DECL:
		case TYPE_EXPR:
		case TRY_EXPR:
		case CATCH_EXPR:
			return "";
		case VAR_DECL:
			VarDeclKind kind = node.as(VarDecl).var_kind;
			if (kind == VAR_LOCAL || kind >= VAR_PARAM) return "";
		default:
			break;
	}
	SourceFile* sf = source_file::file_of(ctx, node);
	if (!sf) return "";
	return query::get_module_name_at_location(sf, node.range.start);
}

<*
 Declaration of `decl` as written in its file, without body or terminator:
 attributes, modifiers and initializers included, contract and comments dropped.
 Empty when the node has no source file.
*>
fn String text(AnalyzerContext* ctx, Node* decl, bool single_line = false)
{
	SourceFile* sf = source_file::file_of(ctx, decl);
	if (!sf || !sf.lexer) return "";
	Token[] tokens = sf.lexer.tokens.array_view();

	Location start = decl.range.start;
	Node* contract = cursor::contract(decl) ?? null;
	if (contract && before(start, contract.range.end)) start = contract.range.end;
	sz first = sort::binarysearch(tokens, (Token){}, &starts_before, &start);
	if (first >= tokens.len) return "";
	sz last = last_header_token(tokens, first, decl);
	while (last > first && (tokens[last].kind == EOS || tokens[last].kind == IMPLIES)) last--;
	if (last < first) return "";

	FormattingOptions options = { .tab_size = 4, .insert_spaces = true };
	return formatting::format_tokens_range(tmem, sf.content, tokens, first, last, 0, options, single_line).trim();
}

fn bool before(Location a, Location b) @local => a.line < b.line || (a.line == b.line && a.column < b.column);

<*
 Never equal, so a binary search ends at the first token starting at or after `start`.
*>
fn int starts_before(Token token, Token unused, Location* start) @local => before(token.range.start, *start) ? -1 : 1;

<*
 Index of the last token before the body of `decl`, or of its last token when it has no body.
*>
fn sz last_header_token(Token[] tokens, sz first, Node* decl) @local
{
	Location end = decl.range.end;
	switch (decl.kind)
	{
		case FN_DECL:
			if (Node* body = decl.as(FnDecl).body) end = body.range.start;
		case MACRO_DECL:
			if (Node* body = decl.as(MacroDecl).body) end = body.range.start;
		case STRUCT_DECL:
		case ENUM_DECL:
		case INTERFACE_DECL:
			int depth = 0;
			for (sz i = first; i < tokens.len && before(tokens[i].range.start, end); i++)
			{
				switch (tokens[i].kind)
				{
					case LPAREN: depth++;
					case RPAREN: depth--;
					case LBRACE:
						if (depth == 0) return i - 1;
					default:
						break;
				}
			}
		default:
			break;
	}
	sz i = first;
	while (i + 1 < tokens.len && before(tokens[i + 1].range.start, end)) i++;
	return i;
}
