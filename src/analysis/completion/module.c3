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

fn void provide_module_paths(Context* ctx, List{CompletionItem} * items)
{
	if (ctx.access != NONE || !ctx.ws || !ctx.ws.ctx) return;

	ctx.ws.ctx.modules.@each(; mod_name, mod)
	{
		if (mod_name.len > 0 && (ctx.prefix.len == 0 || mod_name.starts_with(ctx.prefix)))
		{
			items.push(
			{
				.label = mod_name,
				.kind = MODULE,
				.detail = "module",
				.insertText = mod_name,
				.filterText = mod_name,
				.sortText = string::tformat("0009_%s", mod_name)
			}
			);
		}
	};
}
