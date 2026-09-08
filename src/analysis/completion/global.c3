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
				if (!fndecl.associated_type)
				{
					String fname = fndecl.name ? fndecl.name.text : "";
					if (fname.len > 0 && fuzzy_match(fname, ctx.prefix))
					{
						if (seen_symbols.add(fname))
						{
							add_symbol_completion(ctx, items, fname, fn_info.node, fn_info.mod, ctx.prefix);
						}
					}
				}
			}
		};

		reg.types.@each(; qname, ty_info)
		{
			if (ty_info && ty_info.node)
			{
				String tname = cursor::spelling(ty_info.node, tmem);
				if (tname.len > 0 && fuzzy_match(tname, ctx.prefix))
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
				if (!@ok(mac.associated_type.get()))
				{
					String mname = mac.name ? mac.name.text : "";
					if (mname.len > 0 && fuzzy_match(mname, ctx.prefix))
					{
						if (seen_symbols.add(mname))
						{
							add_symbol_completion(ctx, items, mname, mac_info.node, mac_info.mod, ctx.prefix);
						}
					}
				}
			}
		};
	}

	ctx.ws.ctx.files.@each(; file_path, sf)
	{
		if (sf)
		{
			String file_mod = query::get_source_file_module_name(sf);
			String mod_ident = file_mod.len > 0 ? file_mod : "global";
			foreach (stmt : sf.ast.statements)
			{
				if (stmt)
				{
					if (stmt.kind == FN_DECL && stmt.as(FnDecl).associated_type != null) continue;
					if (stmt.kind == MACRO_DECL && @ok(stmt.as(MacroDecl).associated_type.get())) continue;

					String sname = cursor::spelling(stmt, tmem);
					if (sname.len > 0 && fuzzy_match(sname, ctx.prefix))
					{
						if (seen_symbols.add(sname))
						{
							add_symbol_completion(ctx, items, sname, stmt, mod_ident, ctx.prefix);
						}
					}
				}
			}
		}
	};
}
