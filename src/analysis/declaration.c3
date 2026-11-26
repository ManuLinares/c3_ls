module lsp::analysis::declaration;
import analyzer, lsp, std::collections::list;

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
			return string::tformat("module %s", pe.path.text.strip_suffix("::"));
		case TYPE_EXPR:
			return string::tformat("type %s", name);
		case TRY_EXPR:
			String vtype = type_text(ctx, node.as(TryExpr).type);
			if (!vtype.len) vtype = node.resolved_type.get().name ?? "";
			return string::tformat("try %s %s", vtype ?: "var", name);
		case CATCH_EXPR:
			return string::tformat("catch %s %s", type_text(ctx, node.as(CatchExpr).type) ?: "fault", name);
		case ATTRIBUTE_DECL:
			AttributeDecl* attr = node.as(AttributeDecl);
			if (!attr.exprs.len) return string::tformat("attribute %s", name);
			DString out;
			out.tinit();
			out.appendf("attribute %s(", name);
			foreach (i, expr : attr.exprs)
			{
				if (i > 0) out.append(", ");
				out.append(node_text(ctx, expr));
			}
			out.append(")");
			return out.str_view();
		case VAR_DECL:
			VarDecl* vd = node.as(VarDecl);
			if (vd.var_flags.is_self) return string::tformat("%s %s", type_text(ctx, vd.type), name);
			// `b` in `int a, b;` shares the type written before `a`.
			if (try type = vd.type.get() && !node.range.contains(type.range.start)) return string::tformat("%s %s", node_text(ctx, type), text(ctx, node, single_line) ?: name);
			if (try sf = source_file::file_of(ctx, node) && vd.var_kind == VAR_LOCAL)
			{
				List{Node*} stack = query::ancestors_of(sf, node);
				sz n = stack.len();
				ForeachStmt* fst = n >= 2 && stack[n - 2].kind == FOREACH_STMT ? stack[n - 2].as(ForeachStmt) : null;
				if (fst && (fst.variable == node || fst.index.is(node)))
				{
					String type = query::foreach_binding_type(ctx, sf, fst, node);
					if (type.len) return string::tformat("%s %s", type, vd.name.get().text ?? name);
				}
			}
			if (try owner = owner_enum_name(ctx, node)) return string::tformat("%s.%s", owner.text, text(ctx, node, single_line) ?: name);
		case FAULT_DECL:
			return string::tformat("fault %s", text(ctx, node, single_line) ?: name);
		default:
			break;
	}
	return text(ctx, node, single_line) ?: name;
}

<*
 Markdown block with the signature of `node`, its generic parameters bound by
 `binding`, followed by its module when it is not local.
*>
fn String header(AnalyzerContext* ctx, Node* node, String name, GenericBinding binding = {})
{
	String sig = query::substitute(signature(ctx, node, name), binding.params, binding.args);
	if (@ok(query::label_of(node))) return string::tformat("```c3\n%s\n```\nline %d", sig, node.range.start.line + 1);
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
 Name of the enum or constdef declaring the value `node`.
*>
fn Ident*? owner_enum_name(AnalyzerContext* ctx, Node* node) @local
{
	SourceFile* sf = source_file::file_of(ctx, node)!;
	foreach (stmt : sf.ast.statements)
	{
		if (!stmt || stmt.kind != ENUM_DECL || !stmt.range.contains_range(node.range)) continue;
		EnumDecl* ed = stmt.as(EnumDecl);
		foreach (v : ed.variants) if (v == node) return ed.name.get();
	}
	return NOT_FOUND~;
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
	SourceFile*? sf = source_file::file_of(ctx, node);
	if (catch sf) return "";
	return query::get_module_name_at_location(sf, node.range.start);
}

<*
 Type as written in its file, on one line; its spelling when the parser made it. Empty when there is none.
*>
fn String type_text(AnalyzerContext* ctx, NullableNode type) => node_text(ctx, type.get()) ?? "";

<*
 `node` as written in its file, on one line; its spelling when the parser made it.
*>
fn String node_text(AnalyzerContext* ctx, Node* node)
{
	if (node.flags.is_synthetic) return cursor::spelling(node);
	SourceFile*? sf = source_file::file_of(ctx, node);
	if (catch sf) return cursor::spelling(node);
	if (!sf.lexer) return cursor::spelling(node);
	Token[] tokens = sf.lexer.tokens.array_view();
	sz first = sf.lexer.first_token_at(node.range.start);
	if (first >= tokens.len) return cursor::spelling(node);
	sz last = first;
	while (last + 1 < tokens.len && tokens[last + 1].range.start.before(node.range.end)) last++;
	FormattingOptions options = { .tab_size = 4, .insert_spaces = true };
	return formatting::format_tokens_range(tmem, sf.content, tokens, first, last, 0, options, true).trim();
}

<*
 Declaration of `decl` as written in its file, without body or terminator:
 attributes, modifiers and initializers included, contract and comments dropped.
 Empty when the node has no source file.
*>
fn String text(AnalyzerContext* ctx, Node* decl, bool single_line = false)
{
	SourceFile*? sf = source_file::file_of(ctx, decl);
	if (catch sf) return "";
	if (!sf.lexer) return "";
	Token[] tokens = sf.lexer.tokens.array_view();

	Location start = decl.range.start;
	if (try contract = cursor::contract(decl) && start.before(contract.range.end)) start = contract.range.end;
	sz first = sf.lexer.first_token_at(start);
	if (first >= tokens.len) return "";
	sz last = last_header_token(tokens, first, decl);
	while (last > first && (tokens[last].kind == EOS || tokens[last].kind == IMPLIES)) last--;
	if (last < first) return "";

	FormattingOptions options = { .tab_size = 4, .insert_spaces = true };
	return formatting::format_tokens_range(tmem, sf.content, tokens, first, last, 0, options, single_line).trim();
}

<*
 Index of the last token before the body of `decl`, or of its last token when it has no body.
*>
fn sz last_header_token(Token[] tokens, sz first, Node* decl) @local
{
	Location end = decl.range.end;
	switch (decl.kind)
	{
		case FN_DECL:
			if (try body = decl.as(FnDecl).body.get()) end = body.range.start;
		case MACRO_DECL:
			if (try body = decl.as(MacroDecl).body.get()) end = body.range.start;
		case IF_STMT:
			end = decl.as(IfStmt).then_body.range.start;
		case FOR_STMT:
			end = decl.as(ForStmt).body.range.start;
		case WHILE_STMT:
			end = decl.as(WhileStmt).body.range.start;
		case DO_WHILE_STMT:
			end = decl.as(DoWhileStmt).body.range.start;
		case FOREACH_STMT:
			end = decl.as(ForeachStmt).body.range.start;
		case SWITCH_STMT:
		case STRUCT_DECL:
		case ENUM_DECL:
		case INTERFACE_DECL:
			int depth = 0;
			for (sz i = first; i < tokens.len && tokens[i].range.start.before(end); i++)
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
	while (i + 1 < tokens.len && tokens[i + 1].range.start.before(end)) i++;
	return i;
}
