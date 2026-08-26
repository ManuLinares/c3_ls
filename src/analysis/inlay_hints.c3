module lsp::analysis::inlay_hints;

import analyzer::core;
import analyzer::cursor;
import analyzer::sema::query;

import std::collections::list;
import std::io;

import lsp::core;
import lsp;
import uri;

struct InlayHintCollector
{
	LspProject* project;
	SourceFile* sf;
	LspRange range;
	List{InlayHint} * hints;
}

fn ChildVisitResult collect_inlay_hints_callback(Node* c, Node* p, void* user_data)
{
	if (!c || c.kind == ERROR) return CONTINUE;
	InlayHintCollector* ctx = (InlayHintCollector*)user_data;

	if (c.range.end.line < (int)ctx.range.start.line || c.range.start.line > (int)ctx.range.end.line)
	{
		return CONTINUE;
	}

	switch (c.kind)
	{
		case CALL_EXPR:
			{
				CallExpr* call = c.as(CallExpr);
				if (!call.callee || call.args.len == 0) break;

				String callee_name = "";
				switch (call.callee.kind)
				{
				case IDENT_EXPR:
					{
						IdentExpr* ie = call.callee.as(IdentExpr);
						callee_name = ie.ident ? ie.ident.text : "";
					}
				case ACCESS_EXPR:
					{
						AccessExpr* acc = call.callee.as(AccessExpr);
						String recv_name = cursor::spelling(acc.left, tmem);
						String member_name = cursor::spelling(acc.member, tmem);
						if (recv_name.len > 0 && member_name.len > 0)
						{
							callee_name = string::tformat("%s.%s", recv_name, member_name);
						}
					}
				default:
					break;
			}

			if (callee_name.len == 0) break;

			Node* callee_node = query::resolve_callee_by_name(ctx.project.workspace.ctx, ctx.sf, callee_name);
			if (!callee_node) break;

			NodeArray params = {};
			switch (callee_node.kind)
			{
				case FN_DECL:
					params = callee_node.as(FnDecl).params;
				case MACRO_DECL:
					params = callee_node.as(MacroDecl).params;
				default:
					break;
			}

			if (params.len == 0) break;

			sz param_offset = 0;
			if (call.callee.kind == ACCESS_EXPR && params.len > 0)
			{
				if (params[0] && params[0].kind == VAR_DECL)
				{
					VarDecl* first_p = params[0].as(VarDecl);
					if (first_p.var_flags.is_self || (first_p.name && (first_p.name.text == "self" || first_p.name.text == "this")))
					{
						param_offset = 1;
					}
				}
			}

			for (sz i = 0; i < call.args.len; i++)
			{
				sz param_idx = i + param_offset;
				if (param_idx >= params.len) break;

				Node* arg = call.args[i];
				if (!arg || arg.kind == ERROR) continue;

				if (arg.kind == NAMED_ARG_EXPR || arg.kind == EVAL_NAMED_ARG_EXPR) continue;

				Node* param_node = params[param_idx];
				if (!param_node || param_node.kind != VAR_DECL) continue;
				VarDecl* pdecl = param_node.as(VarDecl);

				String pname = pdecl.name ? pdecl.name.text : "";
				if (pname.len == 0 || pname == "self" || pname == "this") continue;

				ctx.hints.push(
				{
					.position = {
						.line = arg.range.start.line >= 0 ? (uint)arg.range.start.line : 0,
						.character = arg.range.start.column >= 0 ? (uint)arg.range.start.column : 0
					},
					.label = string::tformat("%s:", pname),
					.kind = PARAMETER,
					.paddingLeft = false,
					.paddingRight = true
				}
				);
			}
		}
		default:
			break;
	}

	return RECURSE;
}

fn InlayHint[]? get_inlay_hints(LspProject* project, Uri uri, LspRange range)
{
	SourceFile* sf = project.workspace.get_source_file_by_path(uri.path);
	if (!sf) return {};

	List{InlayHint} hints;
	hints.tinit();

	InlayHintCollector collector = {
		.project = project,
		.sf = sf,
		.range = range,
		.hints = &hints
	};

	foreach (stmt : sf.ast.statements)
	{
		if (!stmt || stmt.kind == ERROR) continue;
		if (stmt.range.end.line < (int)range.start.line || stmt.range.start.line > (int)range.end.line) continue;
		cursor::visit(stmt, null, {.on_enter = &collect_inlay_hints_callback }, &collector);
	}

	return hints.array_view();
}
