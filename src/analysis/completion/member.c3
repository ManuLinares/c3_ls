module lsp::analysis::completion;

import analyzer::core;
import analyzer::cursor;
import analyzer::sema;
import analyzer::sema::query;

import std::collections::list;
import std::collections::map;

import lsp::core;
import lsp;
import lsp::analysis;
import uri;

fn sz scan_base_expression_start(String text, sz end_idx)
{
	sz idx = end_idx;
	while (idx > 0)
	{
		if (text[idx - 1] == ')')
		{
			int depth = 1;
			idx--;
			while (idx > 0 && depth > 0)
			{
				idx--;
				if (text[idx] == ')')
				{
					depth++;
				}
				else if (text[idx] == '(')
				{
					depth--;
				}
			}
			continue;
		}
		else if (text[idx - 1] == '}')
		{
			int depth = 1;
			idx--;
			while (idx > 0 && depth > 0)
			{
				idx--;
				if (text[idx] == '}')
				{
					depth++;
				}
				else if (text[idx] == '{')
				{
					depth--;
				}
			}
			continue;
		}
		else if (text[idx - 1] == ']')
		{
			int depth = 1;
			idx--;
			while (idx > 0 && depth > 0)
			{
				idx--;
				if (text[idx] == ']')
				{
					depth++;
				}
				else if (text[idx] == '[')
				{
					depth--;
				}
			}
			continue;
		}
		else if (text[idx - 1].is_alnum() || text[idx - 1] == '_' || text[idx - 1] == '@' || text[idx - 1] == '#' || text[idx - 1] == '$')
		{
			while (idx > 0 && (text[idx - 1].is_alnum() || text[idx - 1] == '_' || text[idx - 1] == '@' || text[idx - 1] == '#' || text[idx - 1] == '$'))
			{
				idx--;
			}
		}
		else
		{
			break;
		}

		if (idx >= 2 && text[idx - 2] == ':' && text[idx - 1] == ':')
		{
			idx -= 2;
		}
		else if (idx >= 1 && text[idx - 1] == '.')
		{
			idx -= 1;
		}
		else
		{
			break;
		}
	}
	return idx;
}

fn void detect_access_context(Context* ctx, SourceFile* sf)
{
	ctx.access = NONE;
	ctx.base_identifier = "";
	ctx.missing_second_colon = false;

	if (!sf || ctx.offset == 0 || ctx.offset > sf.content.len)
	{
		return;
	}

	String text = sf.content[:ctx.offset];
	sz cursor_idx = text.len;

	while (cursor_idx > 0)
	{
		char c = text[cursor_idx - 1];
		if (!c.is_alnum() && c != '_' && c != '@' && c != '#' && c != '$')
		{
			break;
		}
		cursor_idx--;
	}

	String text_before = text[:cursor_idx];

	if (text_before.ends_with("::"))
	{
		ctx.access = STATIC;
		ctx.missing_second_colon = false;
		cursor_idx -= 2;
	}
	else if (text_before.ends_with("."))
	{
		ctx.access = INSTANCE;
		cursor_idx -= 1;
	}
	else if (text_before.ends_with(":"))
	{
		ctx.access = STATIC;
		ctx.missing_second_colon = true;
		cursor_idx -= 1;
	}
	else
	{
		return;
	}

	sz base_end = cursor_idx;
	sz base_start = scan_base_expression_start(text, base_end);

	if (base_end > base_start)
	{
		ctx.base_identifier = text[base_start : base_end - base_start];
	}
	else
	{
		ctx.access = NONE;
		ctx.missing_second_colon = false;
	}
}

fn String resolve_type_from_identifier_or_chain(Context* ctx, String base_id)
{
	if (base_id.len == 0)
	{
		return "";
	}

	if (base_id.starts_with("$Typeof") || base_id.starts_with("$Typefrom"))
	{
		String inner = "";
		if (try open_p = base_id.index_of_char('('))
		{
			if (try close_p = base_id.rindex_of_char(')'))
			{
				if (close_p > open_p)
				{
					inner = base_id[open_p + 1 : close_p - open_p - 1].trim();
				}
			}
		}
		if (inner.len > 0)
		{
			return resolve_type_from_identifier_or_chain(ctx, inner);
		}
		return "";
	}

	if (try dot_idx = base_id.index_of_char('.'))
	{
		String root_id = base_id[:dot_idx].trim();
		String current_type = resolve_type_from_identifier_or_chain(ctx, root_id);
		String remaining = base_id[dot_idx + 1..];

		while (current_type.len > 0 && remaining.len > 0)
		{
			String seg = remaining;
			if (try next_dot = remaining.index_of_char('.'))
			{
				seg = remaining[:next_dot].trim();
				remaining = remaining[next_dot + 1..];
			}
			else
			{
				remaining = "";
			}

			if (try brace_idx = current_type.index_of_char('{'))
			{
				current_type = current_type[:brace_idx].trim();
			}

			Node* member = query::find_member_in_type(ctx.ws.ctx, current_type, seg, ctx.sf);
			if (member && member.kind == VAR_DECL)
			{
				VarDecl* vd = member.as(VarDecl);
				current_type = vd.type ? (cursor::raw_type_identifier(vd.type) ?? "") : "";
			}
			else
			{
				Node* mnode = query::find_method_in_type(ctx.ws.ctx, current_type, seg, ctx.sf);
				if (mnode && mnode.kind == FN_DECL)
				{
					FnDecl* fd = mnode.as(FnDecl);
					current_type = fd.ret_type ? (cursor::raw_type_identifier(fd.ret_type) ?? "") : "";
				}
				else
				{
					return "";
				}
			}
		}

		return current_type;
	}

	String clean_id = base_id;
	if (try brace_idx = base_id.index_of_char('{'))
	{
		clean_id = base_id[:brace_idx].trim();
	}

	String type_name = "";
	if (ctx.sf)
	{
		(void)query::find_local_decl_in_file(ctx.sf, clean_id, &type_name, ctx.ws.ctx);
	}

	if (type_name.len == 0 && ctx.ws)
	{
		List{SymbolEntry} syms = ctx.ws.find_symbol_by_name(clean_id, ctx.sf);
		if (syms.len() > 0 && syms.get(0).node)
		{
			Node* base_node = syms.get(0).node;
			switch (base_node.kind)
			{
				case STRUCT_DECL:
				case ENUM_DECL:
				case TYPEDEF_DECL:
					type_name = clean_id;
				case VAR_DECL:
					{
						VarDecl* vd = base_node.as(VarDecl);
						if (vd.type)
						{
							type_name = cursor::raw_type_identifier(vd.type) ?? "";
						}
					}
				default:
					break;
			}
		}
	}

	return type_name.len > 0 ? type_name : clean_id;
}

fn void inject_vector_completions(List{CompletionItem}* items, String prefix)
{
	const String[*] COMPS = { "x", "y", "xy", "yx", "xx", "yy", "r", "g", "rg", "gr", "u", "v" };
	foreach (c : COMPS)
	{
		if (prefix.len == 0 || c.starts_with(prefix))
		{
			items.push(
			{
				.label = c,
				.kind = FIELD,
				.detail = "component",
				.insertText = c,
				.filterText = c,
				.sortText = string::tformat("0001_%s", c)
			}
			);
		}
	}

	const String[*] METHODS = {
		"length", "length_sq", "distance", "distance_sq", "normalize", "dot", "cross", "angle",
		"lerp", "reflect", "rotate", "transform", "clamp_length", "move_towards",
		"sum", "product", "min", "max", "ceil", "floor", "round", "trunc"
	};
	foreach (m : METHODS)
	{
		if (prefix.len == 0 || m.starts_with(prefix))
		{
			items.push(
			{
				.label = m,
				.kind = FUNCTION,
				.detail = "vec method",
				.insertText = string::tformat("%s($1)", m),
				.insertTextFormat = SNIPPET,
				.filterText = m,
				.sortText = string::tformat("0002_%s", m)
			}
			);
		}
	}
}

fn void provide_enum_variants(List{CompletionItem}* items, Node* enum_node, String type_name, String prefix, bool missing_second_colon = false)
{
	if (!enum_node || enum_node.kind != ENUM_DECL)
	{
		return;
	}
	EnumDecl* enum_decl = enum_node.as(EnumDecl);

	foreach (variant : enum_decl.variants)
	{
		if (!variant || variant.kind != VAR_DECL)
		{
			continue;
		}
		VarDecl* var_decl = variant.as(VarDecl);
		String vname = var_decl.name ? var_decl.name.text : "";
		if (vname.len > 0 && (prefix.len == 0 || vname.starts_with(prefix)))
		{
			String insert_str = missing_second_colon ? string::tformat(":%s", vname) : vname;
			items.push(
			{
				.label = vname,
				.kind = ENUMMEMBER,
				.detail = string::tformat("enum %s", type_name),
				.insertText = insert_str,
				.filterText = vname,
				.sortText = string::tformat("0001_%s", vname),
				.data = string::tformat("enum_variant:%s:%s", type_name, vname)
			}
			);
		}
	}
}

fn bool provide_member_access(Context* ctx, List{CompletionItem}* items)
{
	if (ctx.access == NONE || ctx.base_identifier.len == 0)
	{
		return false;
	}

	if (ctx.base_identifier == "$reflect" || ctx.base_identifier.starts_with("$reflect"))
	{
		if (ctx.access == INSTANCE)
		{
			analysis::inject_reflect_properties(items, ctx.prefix);
			return true;
		}
	}

	String base_id = ctx.base_identifier;

	switch (ctx.access)
	{
		case STATIC:
			{
				String type_name = resolve_type_from_identifier_or_chain(ctx, base_id);
				String clean_type = type_name;
				if (try brace_idx = type_name.index_of_char('{'))
				{
					clean_type = type_name[:brace_idx].trim();
				}

				if (ctx.ws && ctx.ws.ctx)
				{
					Module* mod = analysis::find_module_by_identifier(ctx.ws, "", clean_type);
					if (mod)
					{
						foreach (node : mod.nodes)
						{
							if (!node || node.kind == ERROR)
							{
								continue;
							}

							if (node.kind == FAULTDEF_DECL)
							{
								FaultdefDecl* fd = node.as(FaultdefDecl);
								foreach (fault_node : fd.faults)
								{
									if (!fault_node || fault_node.kind != FAULT_DECL)
									{
										continue;
									}
									if (!is_symbol_accessible(ctx.sf, ctx.caller_mod, fault_node, mod.name))
									{
										continue;
									}

									FaultDecl* fdecl = fault_node.as(FaultDecl);
									String fname = fdecl.name ? fdecl.name.text : "";
									if (fname.len > 0 && (ctx.prefix.len == 0 || fname.starts_with(ctx.prefix)))
									{
										add_symbol_completion(ctx, items, fname, fault_node, clean_type, ctx.prefix);
									}
								}
								continue;
							}

							if (!is_symbol_accessible(ctx.sf, ctx.caller_mod, node, mod.name))
							{
								continue;
							}

							String sym_name = cursor::spelling(node, tmem);
							if (sym_name.len == 0)
							{
								continue;
							}
							if (ctx.prefix.len == 0 || sym_name.starts_with(ctx.prefix))
							{
								add_symbol_completion(ctx, items, sym_name, node, clean_type, ctx.prefix);
							}
						}
						return true;
					}
				}

				List{SymbolEntry} syms = ctx.ws.find_symbol_by_name(clean_type, ctx.sf);
				if (syms.len() > 0 && syms.get(0).node)
				{
					Node* sym_node = syms.get(0).node;
					if (sym_node.kind == ENUM_DECL)
					{
						provide_enum_variants(items, sym_node, type_name, ctx.prefix, ctx.missing_second_colon);
					}

					analysis::inject_type_properties(items, sym_node.kind, type_name, ctx.missing_second_colon);
					return true;
				}

				if (constants::is_primitive(clean_type))
				{
					analysis::inject_type_properties(items, NodeKind.VAR_DECL, type_name, ctx.missing_second_colon);
					return true;
				}

				return true;
			}

		case INSTANCE:
			{
				String type_name = resolve_type_from_identifier_or_chain(ctx, base_id);
				String clean_type = type_name;
				if (try brace_idx = type_name.index_of_char('{'))
				{
					clean_type = type_name[:brace_idx].trim();
				}

				Node* target_struct = null;
				if (clean_type.len > 0)
				{
					List{SymbolEntry} syms = ctx.ws.find_symbol_by_name(clean_type, ctx.sf);
					if (syms.len() > 0 && syms.get(0).node)
					{
						Node* type_node = syms.get(0).node;
						if (type_node.kind == ENUM_DECL)
						{
							provide_enum_variants(items, type_node, clean_type, ctx.prefix, false);
							return true;
						}
						else if (type_node.kind == STRUCT_DECL)
						{
							target_struct = type_node;
						}
					}
				}

				if (query::is_vector_type(clean_type))
				{
					inject_vector_completions(items, ctx.prefix);
					return true;
				}

				if (target_struct && target_struct.kind == STRUCT_DECL)
				{
					StructDecl* st = target_struct.as(StructDecl);
					foreach (field : st.fields)
					{
						if (!field || field.kind != VAR_DECL)
						{
							continue;
						}
						VarDecl* fdecl = field.as(VarDecl);
						String fname = fdecl.name ? fdecl.name.text : "";
						if (fname.len > 0 && (ctx.prefix.len == 0 || fname.starts_with(ctx.prefix)))
						{
							String ftype = cursor::spelling(fdecl.type, tmem);
							items.push(
							{
								.label = fname,
								.kind = FIELD,
								.detail = ftype,
								.insertText = fname,
								.filterText = fname,
								.sortText = string::tformat("0001_%s", fname),
								.data = string::tformat("field:%s:%s", clean_type, fname)
							}
							);
						}
					}

					if (ctx.ws.ctx && ctx.ws.ctx.registry)
					{
						ctx.ws.ctx.registry.functions.@each(; qname, fn_info)
						{
							if (fn_info && fn_info.node && fn_info.node.kind == FN_DECL)
							{
								FnDecl* fndecl = fn_info.node.as(FnDecl);
								if (fndecl.associated_type)
								{
									String assoc = cursor::raw_type_identifier(fndecl.associated_type) ?? "";
									if (assoc == clean_type || assoc == type_name)
									{
										String mname = fndecl.name ? fndecl.name.text : "";
										if (mname.len > 0 && (ctx.prefix.len == 0 || mname.starts_with(ctx.prefix)))
										{
											add_symbol_completion(ctx, items, mname, fn_info.node, clean_type, ctx.prefix);
										}
									}
								}
							}
						};
					}

					return true;
				}
				return true;
			}

		default:
			return false;
	}
}