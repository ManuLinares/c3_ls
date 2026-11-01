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

fn void provide_module_paths(Context* ctx, List{CompletionItem} * items, SourceFile* sf = null, sz offset = 0)
{
	if (!ctx.ws || !ctx.ws.ctx) return;

	String base_path = "";
	String filter_prefix = "";
	bool missing_second_colon = false;

	if (sf && offset > 0 && offset <= sf.content.len)
	{
		sz line_start = offset;
		while (line_start > 0 && sf.content[line_start - 1] != '\n')
		{
			line_start--;
		}

		String line_prefix = sf.content[line_start : offset - line_start].trim_left();
		bool is_import = line_prefix.starts_with("import");
		bool is_module = line_prefix.starts_with("module");

		if (is_import || is_module)
		{
			String mod_text = is_module ? line_prefix.strip_prefix("module").trim_left() : line_prefix.strip_prefix("import").trim_left();
			if (is_import)
			{
				if (try comma_idx = mod_text.rindex_of_char(','))
				{
					mod_text = mod_text[comma_idx + 1..].trim_left();
				}
			}

			if (mod_text.ends_with("::"))
			{
				base_path = mod_text[:^ 2].trim();
			}
			else if (mod_text.ends_with(":"))
			{
				base_path = mod_text[:^ 1].trim();
				missing_second_colon = true;
			}
			else if (try scope_idx = mod_text.rindex_of("::"))
			{
				base_path = mod_text[:scope_idx].trim();
				filter_prefix = mod_text[scope_idx + 2..].trim();
			}
			else
			{
				filter_prefix = mod_text.trim();
			}
		}
	}

	HashSet{String} seen_labels;
	seen_labels.tinit();

	ctx.ws.ctx.modules.@each(; mod_name, mod)
	{
		if (mod_name.len == 0) return;

		String doc_text = "";
		if (mod && mod.module_decls.len() > 0)
		{
			doc_text = cursor::docs((Node*)mod.module_decls.get(0)) ?? "";
		}

		if (base_path.len == 0)
		{
			if (filter_prefix.len == 0 || mod_name.starts_with(filter_prefix))
			{
				if (seen_labels.add(mod_name))
				{
					items.push(
					{
						.label = mod_name,
						.kind = MODULE,
						.detail = "module",
						.documentation = {
							.kind = MARKDOWN,
							.value = doc_text.len > 0 ? doc_text.trim().treplace("\"", "") : ""
						},
						.insertText = mod_name,
						.filterText = mod_name,
						.sortText = string::tformat("0009_%s", mod_name),
						.data = string::tformat("module:%s", mod_name)
					}
					);
				}
			}
		}
		else
		{
			String prefix_match = string::tformat("%s::", base_path);
			if (mod_name.starts_with(prefix_match))
			{
				String remaining = mod_name[prefix_match.len..];
				String segment = remaining;
				if (try next_colon = remaining.index_of("::"))
				{
					segment = remaining[:next_colon];
				}

				if (filter_prefix.len == 0 || segment.starts_with(filter_prefix))
				{
					if (seen_labels.add(segment))
					{
						String full_mod_name = string::tformat("%s::%s", base_path, segment);
						String insert_str = missing_second_colon ? string::tformat(":%s", segment) : segment;
						items.push(
						{
							.label = segment,
							.kind = MODULE,
							.detail = string::tformat("module %s", full_mod_name),
							.documentation = {
								.kind = MARKDOWN,
								.value = doc_text.len > 0 ? doc_text.trim().treplace("\"", "") : ""
							},
							.insertText = insert_str,
							.filterText = segment,
							.sortText = string::tformat("0001_%s", segment),
							.data = string::tformat("module:%s", full_mod_name)
						}
						);
					}
				}
			}
		}
	};
}
