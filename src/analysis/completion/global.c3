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

fn void provide_global(Context* ctx, List{CompletionItem} * items)
{
	if (ctx.access != NONE || !ctx.ws || !ctx.ws.ctx) return;

	HashSet{String} seen_symbols;
	seen_symbols.tinit();

	foreach (item : *items)
	{
		seen_symbols.add(item.label);
	}

	if (ctx.ws.ctx.registry)
	{
		Registry* reg = ctx.ws.ctx.registry;

		reg.functions.@each(; qname, fn_info)
		{
			if (fn_info && fn_info.node && fn_info.node.kind == FN_DECL)
			{
				FnDecl* fndecl = fn_info.node.as(FnDecl);
				String fname = fndecl.name ? fndecl.name.text : "";
				if (fname.len > 0 && (ctx.prefix.len == 0 || fname.starts_with(ctx.prefix)))
				{
					if (seen_symbols.add(fname))
					{
						add_symbol_completion(ctx, items, fname, fn_info.node, fn_info.mod, ctx.prefix);
					}
				}
			}
		};

		reg.types.@each(; qname, ty_info)
		{
			if (ty_info && ty_info.node)
			{
				String tname = cursor::spelling(ty_info.node, tmem);
				if (tname.len > 0 && (ctx.prefix.len == 0 || tname.starts_with(ctx.prefix)))
				{
					if (seen_symbols.add(tname))
					{
						add_symbol_completion(ctx, items, tname, ty_info.node, ty_info.mod, ctx.prefix);
					}
				}
			}
		};

		reg.macros.@each(; qname, mac_info)
		{
			if (mac_info && mac_info.node && mac_info.node.kind == MACRO_DECL)
			{
				MacroDecl* mac = mac_info.node.as(MacroDecl);
				String mname = mac.name ? mac.name.text : "";
				if (mname.len > 0 && (ctx.prefix.len == 0 || mname.starts_with(ctx.prefix)))
				{
					if (seen_symbols.add(mname))
					{
						add_symbol_completion(ctx, items, mname, mac_info.node, mac_info.mod, ctx.prefix);
					}
				}
			}
		};
	}

	ctx.ws.ctx.files.@each(; file_path, sf)
	{
		if (sf)
		{
			foreach (stmt : sf.ast.statements)
			{
				if (stmt)
				{
					String sname = cursor::spelling(stmt, tmem);
					if (sname.len > 0 && (ctx.prefix.len == 0 || sname.starts_with(ctx.prefix)))
					{
						if (seen_symbols.add(sname))
						{
							add_symbol_completion(ctx, items, sname, stmt, "global", ctx.prefix);
						}
					}
				}
			}
		}
	};
}
