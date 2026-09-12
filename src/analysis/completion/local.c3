module lsp::analysis::completion;

import analyzer::core;
import analyzer::cursor;
import analyzer::sema;

import std::collections::list;
import std::collections::map;
import std::collections::set;

import lsp::core;
import lsp;
import uri;

struct LocalCollectorContext
{
	Context* ctx;
	Location loc;
	List{CompletionItem} * items;
	HashSet{String} seen;
}

fn ChildVisitResult collect_locals_callback(Node* c, Node* p, void* user_data)
{
	if (!c || c.kind == ERROR) return CONTINUE;
	LocalCollectorContext* lctx = (LocalCollectorContext*)user_data;

	if (c.range.start.line > lctx.loc.line) return CONTINUE;
	if (c.range.start.line == lctx.loc.line && c.range.start.column > lctx.loc.column) return CONTINUE;

	switch (c.kind)
	{
		case VAR_DECL:
			{
				VarDecl* vd = c.as(VarDecl);
				String vname = vd.name ? vd.name.text : "";
				if (vname.len > 0 && fuzzy_match(vname, lctx.ctx.prefix))
				{
					if (lctx.seen.add(vname))
					{
						String vtype = vd.type ? (cursor::spelling(vd.type, tmem) ?: "var") : "var";
						lctx.items.push(
						{
							.label = vname,
							.kind = VARIABLE,
							.detail = vtype,
							.insertText = vname,
							.filterText = vname,
							.sortText = string::tformat("0001_%s", vname),
							.data = string::tformat("local:%s", vname)
						}
						);
					}
				}
			}
		case TRY_EXPR:
			{
				TryExpr* te = c.as(TryExpr);
				if (!te.variable || te.variable.kind != IDENT_EXPR) break;
				IdentExpr* ie = te.variable.as(IdentExpr);
				String vname = ie.ident ? ie.ident.text : "";
				if (vname.len == 0 || (lctx.ctx.prefix.len > 0 && !vname.starts_with(lctx.ctx.prefix))) break;
				if (!lctx.seen.add(vname)) break;

				String vtype = te.type ? (cursor::spelling(te.type, tmem) ?: "var") : "var";
				if (vtype == "var" && te.init && lctx.ctx.ws && lctx.ctx.ws.ctx)
				{
					String itype = query::type_of(lctx.ctx.ws.ctx, lctx.ctx.sf, te.init, lctx.loc);
					itype = itype.trim_right("?*& \t");
					if (itype.len > 0) vtype = itype;
				}
				lctx.items.push(
				{
					.label = vname,
					.kind = VARIABLE,
					.detail = vtype,
					.insertText = vname,
					.filterText = vname,
					.sortText = string::tformat("0001_%s", vname),
					.data = string::tformat("local:%s", vname)
				}
				);
			}
		case CATCH_EXPR:
			{
				CatchExpr* ce = c.as(CatchExpr);
				if (ce.variable && ce.variable.kind == IDENT_EXPR)
				{
					IdentExpr* ie = ce.variable.as(IdentExpr);
					String vname = ie.ident ? ie.ident.text : "";
					if (vname.len > 0 && (lctx.ctx.prefix.len == 0 || vname.starts_with(lctx.ctx.prefix)))
					{
						if (lctx.seen.add(vname))
						{
							String vtype = ce.type ? (cursor::spelling(ce.type, tmem) ?: "fault") : "fault";
							lctx.items.push(
							{
								.label = vname,
								.kind = VARIABLE,
								.detail = vtype,
								.insertText = vname,
								.filterText = vname,
								.sortText = string::tformat("0001_%s", vname),
								.data = string::tformat("local:%s", vname)
							}
							);
						}
					}
				}
			}
		case FOREACH_STMT:
			{
				ForeachStmt* fst = c.as(ForeachStmt);
				if (fst.index && fst.index.kind == VAR_DECL)
				{
					VarDecl* ivd = fst.index.as(VarDecl);
					String iname = ivd.name ? ivd.name.text : "";
					if (iname.len > 0 && (lctx.ctx.prefix.len == 0 || iname.starts_with(lctx.ctx.prefix)))
					{
						if (lctx.seen.add(iname))
						{
							lctx.items.push(
							{
								.label = iname,
								.kind = VARIABLE,
								.detail = "sz",
								.insertText = iname,
								.filterText = iname,
								.sortText = string::tformat("0001_%s", iname),
								.data = string::tformat("local:%s", iname)
							}
							);
						}
					}
				}
				if (fst.variable && fst.variable.kind == VAR_DECL)
				{
					VarDecl* vvd = fst.variable.as(VarDecl);
					String vname = vvd.name ? vvd.name.text : "";
					if (vname.len > 0 && (lctx.ctx.prefix.len == 0 || vname.starts_with(lctx.ctx.prefix)))
					{
						if (lctx.seen.add(vname))
						{
							String vtype = vvd.type ? (cursor::spelling(vvd.type, tmem) ?: "var") : "var";
							lctx.items.push(
							{
								.label = vname,
								.kind = VARIABLE,
								.detail = vtype,
								.insertText = vname,
								.filterText = vname,
								.sortText = string::tformat("0001_%s", vname),
								.data = string::tformat("local:%s", vname)
							}
							);
						}
					}
				}
			}
		default:
			break;
	}

	return RECURSE;
}

fn void provide_locals(Context* ctx, List{CompletionItem} * items)
{
	if (ctx.access != NONE || !ctx.sf) return;

	Location loc = {
		.line = (int)ctx.position.line,
		.column = (int)ctx.position.character
	};

	Node* enclosing_fn = null;
	foreach (stmt : ctx.sf.ast.statements)
	{
		if (stmt && stmt.range.contains(loc))
		{
			enclosing_fn = stmt;
			break;
		}
	}

	if (!enclosing_fn) return;

	LocalCollectorContext lctx = {
		.ctx = ctx,
		.loc = loc,
		.items = items
	};
	lctx.seen.tinit();

	cursor::visit(enclosing_fn, null, {.on_enter = &collect_locals_callback }, &lctx);
}

fn String extract_named_arg_identifier(String arg_str) @local
{
	String s = arg_str.trim();
	if (s.len == 0) return "";
	if (s.starts_with("#") || s.starts_with("$")) s = s[1..];
	if (s.len == 0 || (!s[0].is_alpha() && s[0] != '_')) return "";

	sz i = 0;
	while (i < s.len && (s[i].is_alnum() || s[i] == '_')) i++;

	String name = s[:i];
	while (i < s.len && (s[i] == ' ' || s[i] == '\t')) i++;

	if (i < s.len && s[i] == ':' && (i + 1 == s.len || s[i + 1] != ':'))
	{
		return name;
	}

	return "";
}

fn void provide_named_args(Context* ctx, List{CompletionItem} * items)
{
	if (!ctx.sf || ctx.offset == 0 || !ctx.ws || !ctx.ws.ctx) return;

	CallTargetInfo target_info = analysis::parse_call_context(ctx.sf.content, ctx.offset);
	if (!target_info.is_valid || target_info.callee_name.len == 0) return;

	Location loc = {
		.line = (int)ctx.position.line,
		.column = (int)ctx.position.character
	};

	Node* callee_node = query::resolve_callee_by_name(ctx.ws.ctx, ctx.sf, target_info.callee_name, loc);
	if (!callee_node) return;

	NodeArray params = {};
	bool is_method = false;

	switch (callee_node.kind)
	{
		case FN_DECL:
			{
				FnDecl* fd = callee_node.as(FnDecl);
				params = fd.params;
				is_method = (fd.associated_type != null);
			}
		case MACRO_DECL:
			{
				MacroDecl* md = callee_node.as(MacroDecl);
				params = md.params;
				is_method = @ok(md.associated_type.get());
			}
		default:
			break;
	}

	if (params.len == 0) return;

	sz start_idx = (is_method && target_info.callee_name.contains(".")) ? 1 : 0;

	String args_text = "";
	if (ctx.offset > target_info.open_paren_idx + 1)
	{
		args_text = ctx.sf.content[target_info.open_paren_idx + 1 : ctx.offset - (target_info.open_paren_idx + 1)];
	}

	sz positional_count = 0;
	List{String} used_names;
	used_names.tinit();

	if (args_text.len > 0)
	{
		int depth = 0;
		bool in_str = false;
		bool in_char = false;
		bool in_raw = false;
		sz arg_start = 0;

		for (sz i = 0; i < args_text.len; i++)
		{
			char c = args_text[i];
			if (in_raw)
			{
				if (c == '`') in_raw = false;
				continue;
			}
			if (in_str)
			{
				if (c == '\\' && i + 1 < args_text.len) { i++; continue; }
				if (c == '"') in_str = false;
				continue;
			}
			if (in_char)
			{
				if (c == '\\' && i + 1 < args_text.len) { i++; continue; }
				if (c == '\'') in_char = false;
				continue;
			}

			switch (c)
			{
				case '`': in_raw = true;
				case '"': in_str = true;
				case '\'': in_char = true;
				case '(':
				case '[':
				case '{':
					depth++;
				case ')':
				case ']':
				case '}':
					if (depth > 0) depth--;
				case ',':
					if (depth == 0)
					{
						String completed_arg = args_text[arg_start : i - arg_start].trim();
						if (completed_arg.len > 0)
						{
							String named = extract_named_arg_identifier(completed_arg);
							if (named.len > 0)
							{
								used_names.push(named);
							}
							else
							{
								positional_count++;
							}
						}
						arg_start = i + 1;
					}
				default:
					break;
			}
		}
	}

	for (sz i = start_idx; i < params.len; i++)
	{
		sz param_pos_idx = i - start_idx;
		if (param_pos_idx < positional_count) continue;

		Node* p = params[i];
		if (!p || p.kind != VAR_DECL) continue;
		VarDecl* vd = p.as(VarDecl);
		String raw_name = vd.name ? vd.name.text : "";
		if (raw_name.len == 0 || vd.var_flags.is_variadic) continue;

		String pname = raw_name.strip_prefix("#").strip_prefix("$");

		bool already_used = false;
		foreach (u : used_names)
		{
			if (u == pname) { already_used = true; break; }
		}
		if (already_used) continue;

		if (fuzzy_match(pname, ctx.prefix))
		{
			String ptype = vd.type ? (cursor::spelling(vd.type, tmem) ?: "any") : "any";
			items.push(
			{
				.label = string::tformat("%s:", pname),
				.kind = FIELD,
				.detail = string::tformat("%s %s:", ptype, pname),
				.insertText = string::tformat("%s: ", pname),
				.filterText = pname,
				.sortText = string::tformat("0000_%s", pname),
				.data = "property"
			}
			);
		}
	}
}