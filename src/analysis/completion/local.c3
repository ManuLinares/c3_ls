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
	List{CompletionItem}* items;
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
				if (vname.len > 0 && (lctx.ctx.prefix.len == 0 || vname.starts_with(lctx.ctx.prefix)))
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
							.sortText = string::tformat("0001_%s", vname)
						}
						);
					}
				}
			}
		case TRY_EXPR:
			{
				TryExpr* te = c.as(TryExpr);
				if (te.variable && te.variable.kind == IDENT_EXPR)
				{
					IdentExpr* ie = te.variable.as(IdentExpr);
					String vname = ie.ident ? ie.ident.text : "";
					if (vname.len > 0 && (lctx.ctx.prefix.len == 0 || vname.starts_with(lctx.ctx.prefix)))
					{
						if (lctx.seen.add(vname))
						{
							String vtype = te.type ? (cursor::spelling(te.type, tmem) ?: "var") : "var";
							lctx.items.push(
							{
								.label = vname,
								.kind = VARIABLE,
								.detail = vtype,
								.insertText = vname,
								.filterText = vname,
								.sortText = string::tformat("0001_%s", vname)
							}
							);
						}
					}
				}
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
								.sortText = string::tformat("0001_%s", vname)
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
								.sortText = string::tformat("0001_%s", iname)
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
								.sortText = string::tformat("0001_%s", vname)
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

fn void provide_locals(Context* ctx, List{CompletionItem}* items)
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