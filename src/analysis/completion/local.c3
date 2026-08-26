module lsp::analysis::completion;

import analyzer::core;
import analyzer::cursor;
import analyzer::sema;

import std::collections::list;
import std::collections::map;

import lsp::core;
import lsp;
import uri;

fn void provide_locals(Context* ctx, List{CompletionItem} * items)
{
	if (ctx.access != NONE || !ctx.sf) return;

	Location loc = {
		.line = (int)ctx.position.line,
		.column = (int)ctx.position.character
	};

	Range target_range = {.start = loc,.end = loc };
	Node* enclosing_node = cursor::find_at(ctx.sf.ast.statements.array_view(), target_range);
	if (!enclosing_node) return;

	Node* curr = enclosing_node;
	while (curr)
	{
		if (curr.kind == FN_DECL)
		{
			FnDecl* fn_decl = curr.as(FnDecl);
			foreach (param : fn_decl.params)
			{
				if (!param || param.kind != VAR_DECL) continue;
				VarDecl* pdecl = param.as(VarDecl);
				String pname = pdecl.name ? pdecl.name.text : "";
				if (pname.len > 0 && (ctx.prefix.len == 0 || pname.starts_with(ctx.prefix)))
				{
					String ptype = cursor::spelling(pdecl.type, tmem) ?: "param";
					items.push(
					{
						.label = pname,
						.kind = VARIABLE,
						.detail = ptype,
						.insertText = pname,
						.filterText = pname,
						.sortText = string::tformat("0001_%s", pname)
					}
					);
				}
			}
			break;
		}
		else if (curr.kind == MACRO_DECL)
		{
			MacroDecl* mac_decl = curr.as(MacroDecl);
			foreach (param : mac_decl.params)
			{
				if (!param || param.kind != VAR_DECL) continue;
				VarDecl* pdecl = param.as(VarDecl);
				String pname = pdecl.name ? pdecl.name.text : "";
				if (pname.len > 0 && (ctx.prefix.len == 0 || pname.starts_with(ctx.prefix)))
				{
					items.push(
					{
						.label = pname,
						.kind = VARIABLE,
						.detail = "macro param",
						.insertText = pname,
						.filterText = pname,
						.sortText = string::tformat("0001_%s", pname)
					}
					);
				}
			}
			break;
		}
		break;
	}
}
