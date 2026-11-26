module lsp::analysis::hover;
import analyzer, lsp, uri, std::collections::list;

struct CallFinderContext
{
	Range target_range;
	CallExpr* found_call;
}

fn ChildVisitResult find_call_callback(Node* c, Node* p, void* user_data)
{
	if (!c || c.kind == ERROR) return CONTINUE;
	CallFinderContext* ctx = (CallFinderContext*)user_data;
	if (c.kind == CALL_EXPR && c.range.contains_range(ctx.target_range))
	{
		ctx.found_call = c.as(CallExpr);
		return RECURSE;
	}
	return RECURSE;
}

struct AccessFinderContext
{
	Range target_range;
	AccessExpr* found_access;
}

fn ChildVisitResult find_enclosing_access_callback(Node* c, Node* p, void* user_data)
{
	if (!c || c.kind == ERROR) return CONTINUE;
	AccessFinderContext* ctx = (AccessFinderContext*)user_data;
	if (c.kind == ACCESS_EXPR && c.range.contains_range(ctx.target_range))
	{
		ctx.found_access = c.as(AccessExpr);
		return RECURSE;
	}
	return RECURSE;
}

<*
 Hover for a compile-time property: its signature, its evaluated value when known, then `doc`.
*>
fn String property_hover(String signature, String ct_eval, String doc) @local
{
	DString text;
	text.tinit();
	text.appendf("```c3\n%s\n", signature);
	if (ct_eval.len > 0) text.appendf("// Compile-Time Evaluation:\n%s\n", ct_eval);
	text.append("```");
	if (doc.len > 0) text.appendf("\n\n%s", doc);
	return text.str_view();
}

<*
 Hover text at `pos`. On a documented keyword its doc follows whatever the code there shows,
 such as the declaration it starts or the value it evaluates to; alone it comes after the keyword's syntax.
*>
fn String? hover(LspProject* project, Uri uri, LspPosition pos)
{
	Location loc = {
		.line = (int)pos.line,
		.column = (int)pos.character
	};

	SourceFile* sf = project.workspace.get_source_file_by_path(uri.path)!;
	if (!project.workspace.ctx) return "";

	String shown = code_hover(project, sf, loc)!;
	if (!sf.lexer) return shown;
	sz i = sf.lexer.token_at(loc);
	if (i < 0) return shown;
	Keyword? kw = Keyword::lookup_field(name, sf.lexer.tokens[i].value);
	if (catch kw) return shown;
	if (!kw.docs.len) return shown;
	if (shown.len) return string::tformat("%s\n\n%s", shown, kw.docs);
	return string::tformat("```c3\n%s\n```\n\n%s", kw.syntax(), kw.docs);
}

struct TypeAtContext
{
	Location loc;
	TypeExpr* found;
}

fn ChildVisitResult find_type_at_callback(Node* c, Node* p, void* user_data)
{
	if (!c || c.kind == ERROR || !c.range.contains(((TypeAtContext*)user_data).loc)) return CONTINUE;
	if (c.kind == TYPE_EXPR) ((TypeAtContext*)user_data).found = c.as(TypeExpr);
	return RECURSE;
}

<*
 The type whose suffix, such as `*`, `[]`, `[N]`, a vector or `?`, is under the mouse at `loc`.
 Unlike the caret lookup, which gives the base type on the suffix's first character,
 it matches only the type that holds the character at `loc`.
*>
fn TypeExpr*? suffix_type_at(SourceFile* sf, Location loc) @local
{
	Node* top = query::enclosing_top_level(sf, loc)!;
	TypeAtContext ctx = { .loc = loc };
	cursor::visit(top, null, {.on_enter = &find_type_at_callback }, &ctx);
	TypeExpr* t = ctx.found;
	if (!t) return NOT_FOUND~;
	switch (t.type_kind)
	{
		case TYPE_POINTER:
		case TYPE_SLICE:
			return t;
		case TYPE_ARRAY:
		case TYPE_VECTOR:
			return t.array.len_expr.contains(loc) ? NOT_FOUND~ : t;
		default:
			return t.optional && on_question(sf, loc) ? t : NOT_FOUND~;
	}
}

fn bool on_question(SourceFile* sf, Location loc) @local
{
	if (!sf.lexer) return false;
	sz i = sf.lexer.token_at(loc);
	return i >= 0 && sf.lexer.tokens[i].kind == QUESTION;
}

<*
 Range of what is hovered at `pos`: a declared name, or the whole expression or type there,
 such as a vector type or `$$name`. Clients that get no range pick the hovered word themselves
 and split such names.
*>
fn LspRange? hover_range(LspProject* project, Uri uri, LspPosition pos)
{
	SourceFile* sf = project.workspace.get_source_file_by_path(uri.path)!;
	if (!sf.lexer) return NOT_FOUND~;
	Location loc = { .line = (int)pos.line, .column = (int)pos.character };
	if (try t = suffix_type_at(sf, loc)) return analysis::to_lsp_range(t.range);
	Node* n = query::node_at(sf, loc)!;
	if (n.kind == ERROR) return NOT_FOUND~;
	Ident*? name = references::declared_name(n);
	if (catch name) return analysis::to_lsp_range(n.range);
	if (name.range.touches(loc)) return analysis::to_lsp_range(name.range);
	sz i = sf.lexer.token_at(loc);
	if (i < 0) return NOT_FOUND~;
	return analysis::to_lsp_range(sf.lexer.tokens[i].range);
}

fn String? code_hover(LspProject* project, SourceFile* sf, Location loc) @local
{
	// A tag of a doc contract, such as `@param`.
	if (sf.lexer)
	{
		Token[] tokens = sf.lexer.tokens.array_view();
		sz i = sf.lexer.token_at(loc);
		if (i >= 0 && tokens[i].kind == AT_IDENT)
		{
			sz j = i - 1;
			while (j >= 0 && tokens[j].kind != DOCS_START && tokens[j].kind != DOCS_END) j--;
			if (j >= 0 && tokens[j].kind == DOCS_START)
			{
				String tag = tokens[i].value.strip_prefix("@");
				bool optional = i + 1 < tokens.len && tokens[i + 1].kind == QUESTION && tokens[i + 1].range.start == tokens[i].range.end;
				if (optional) tag = string::tformat("%s?", tag);
				if (try t = DocTag::lookup_field(name, tag)) return string::tformat("```c3\n%s\n```\n\n%s", t.syntax, t.doc);
			}
		}
	}

	Range target_range = {.start = loc,.end = loc };
	Node*? target_node = cursor::find_at(sf.ast.statements.array_view(), target_range);

	// `$$name` and `$$NAME`, defined by the compiler.
	Ident* builtin = null;
	if (try target_node && target_node.kind == BUILTIN_EXPR) builtin = target_node.as(BuiltinExpr).name;
	if (try target_node && target_node.kind == COMPILER_CONST_EXPR) builtin = target_node.as(CompilerConstExpr).expr.name;
	if (builtin)
	{
		String text = builtin.text;
		String label = string::tformat("$$%s", text);
		String doc;
		if (try target_node && target_node.kind == BUILTIN_EXPR)
		{
			if (try b = Builtin::lookup_field(name, text))
			{
				label = b.signature();
				doc = b.doc;
			}
		}
		else if (try c = BuiltinConstant::lookup_field(name, text))
		{
			doc = c.doc;
		}
		return doc.len ? string::tformat("```c3\n%s\n```\n\n%s", label, doc) : string::tformat("```c3\n%s\n```", label);
	}

	if (try t = suffix_type_at(sf, loc))
	{
		String full = cursor::spelling(t, tmem);
		String type = full.strip_suffix("?");
		if (t.optional && on_question(sf, loc)) return string::tformat("```c3\n%s\n```\n\nOptional `%s`.", full, type);
		String kind;
		Node* base;
		switch (t.type_kind)
		{
			case TYPE_POINTER: kind = "Pointer to"; base = t.modify.base;
			case TYPE_SLICE: kind = "Slice of"; base = t.modify.base;
			case TYPE_ARRAY: kind = "Array of"; base = t.array.base;
			case TYPE_VECTOR: kind = "Vector of"; base = t.array.base;
			default: break;
		}
		if (base) return string::tformat("```c3\n%s\n```\n\n%s `%s`.", type, kind, cursor::spelling(base, tmem));
	}

	// An overloaded operator shows the method it calls.
	List{OverloadCall} operators;
	operators.tinit();
	query::operator_overloads_at(project.workspace.ctx, sf, loc, &operators);

	AccessFinderContext acc_finder = {.target_range = target_range,.found_access = null };
	CallFinderContext call_finder = {.target_range = target_range,.found_call = null };
	foreach (stmt : sf.ast.statements)
	{
		if (!stmt || stmt.kind == ERROR) continue;
		cursor::visit(stmt, null, {.on_enter = &find_enclosing_access_callback }, &acc_finder);
		cursor::visit(stmt, null, {.on_enter = &find_call_callback }, &call_finder);
	}

	// An access describes its member only; its left side has hover of its own.
	AccessExpr* access = acc_finder.found_access;
	if (access && !access.member.contains(loc)) access = null;
	Node*? ct_node = access ? (Node*)access : (call_finder.found_call ? (Node*)call_finder.found_call : target_node);
	if (try ct_node && !operators.len())
	{
		if (ct_node.kind == ACCESS_EXPR)
		{
			AccessExpr* acc = ct_node.as(AccessExpr);
			String mem_name = acc.member.spelling();
			if (acc.access_kind == STATIC)
			{
				if (try tp = TypeProperty::lookup_field(name, mem_name))
				{
					String left_name = cursor::spelling(acc.left, tmem);
					String ct_eval = macro_expand::evaluate_compile_time(project.workspace.ctx, sf, ct_node);
					return property_hover(string::tformat("%s::%s : %s", left_name, tp.name, tp.type_desc), ct_eval, tp.doc);
				}
			}
			else
			{
				if (acc.member.contains(loc))
				{
					if (try property = ValueProperty::lookup_field(name, mem_name))
					{
						String recv_type = query::type_of(project.workspace.ctx, sf, acc.left, loc);
						String type = query::value_property_type(project.workspace.ctx, sf, recv_type, property);
						if (type.len) return string::tformat("```c3\n%s %s\n```\n\n%s", type, property.name, property.doc);
					}
					if (query::is_swizzle(mem_name))
					{
						String type = query::member_type(project.workspace.ctx, sf, query::type_of(project.workspace.ctx, sf, acc.left, loc), mem_name, loc);
						if (type.len) return string::tformat("```c3\n%s %s\n```", type, mem_name);
					}
				}

				String left_str = cursor::spelling(acc.left, tmem);
				bool is_reflect = ((acc.left.kind == CT_REFLECT_EXPR || left_str.starts_with("$reflect")));
				if (is_reflect)
				{
					if (try rp = ReflectProperty::lookup_field(name, mem_name))
					{
						String ct_eval = macro_expand::evaluate_compile_time(project.workspace.ctx, sf, ct_node);
						return property_hover(string::tformat("%s.%s : %s", left_str, rp.name, rp.type_desc), ct_eval, rp.doc);
					}
				}
			}
		}

		String ct_eval = macro_expand::evaluate_compile_time(project.workspace.ctx, sf, ct_node);
		if (ct_eval.len > 0)
		{
			DString ct_buf;
			ct_buf.tinit();
			ct_buf.appendf("```c3\n// Compile-Time Evaluation:\n%s\n```", ct_eval);
			return ct_buf.str_view();
		}
	}

	List{Node*} overloads;
	overloads.tinit();
	Node*? decl_node = operators.len() ? operators[0].method : query::resolve_symbol_at(project.workspace.ctx, sf, loc, &overloads);
	if (catch decl_node) return "";
	// A member of a generic instance shows the instance's types: `int element` for `Type element` on a `List{int}`.
	GenericBinding binding = operators.len()
		? query::member_binding(project.workspace.ctx, sf, operators[0].receiver, decl_node)
		: query::member_binding_at(project.workspace.ctx, sf, loc, decl_node);

	if (decl_node.kind == TYPE_EXPR)
	{
		if (try pt = PrimitiveType::lookup_field(name, cursor::raw_type_identifier(decl_node) ?? ""))
		{
			return string::tformat("```c3\n%s\n```\n\n%s", pt.name, pt.doc);
		}
	}

	String symbol_name = analysis::get_node_symbol_name(decl_node);
	if (symbol_name.len == 0 && decl_node.kind != MODULE_DECL && decl_node.kind != PATH_EXPR) return "";

	String doc_comment = declaration::docs(decl_node);
	if (doc_comment.len == 0 && decl_node.kind == ATTRIBUTE_DECL)
	{
		doc_comment = decl_node.as(AttributeDecl).attribute_kind.doc;
	}

	DString md_buf;
	md_buf.tinit();
	md_buf.append(declaration::header(project.workspace.ctx, decl_node, symbol_name, binding));
	if (overloads.len() > 1)
	{
		md_buf.append("\n\nDeclared for ");
		foreach (i, o : overloads)
		{
			if (i > 0) md_buf.append(", ");
			md_buf.appendf("`%s`", cursor::spelling(query::receiver_type_expr(o), tmem) ?? "");
		}
	}
	if (doc_comment.len > 0) md_buf.appendf("\n\n%s", doc_comment);

	if (decl_node.kind == MACRO_DECL && overloads.len() <= 1)
	{
		CallFinderContext call_ctx = {.target_range = target_range,.found_call = null };
		foreach (stmt : sf.ast.statements)
		{
			if (!stmt || stmt.kind == ERROR) continue;
			cursor::visit(stmt, null, {.on_enter = &find_call_callback }, &call_ctx);
			if (call_ctx.found_call) break;
		}

		if (call_ctx.found_call)
		{
			String expansion = macro_expand::expand_macro(project.workspace.ctx, sf, call_ctx.found_call, decl_node.as(MacroDecl)) ?? "";
			String trimmed_expansion = expansion.trim();
			if (trimmed_expansion.len > 0 && trimmed_expansion != "{}" && trimmed_expansion != "{\n}")
			{
				md_buf.appendf("\n\n**Macro Expansion:**\n```c3\n%s\n```", expansion);
			}
		}
	}

	return md_buf.str_view();
}
