module lsp::analysis::completion;

import analyzer::core;
import analyzer::cursor;
import analyzer::sema;
import analyzer::sema::query;

import std::collections::list;
import std::collections::map;
import std::collections::set;

import lsp::core;
import lsp;
import lsp::analysis;
import uri;

fn sz scan_base_expression_start(String text, sz end_idx)
{
	sz idx = end_idx;
	while (idx > 0 && (text[idx - 1] == ' ' || text[idx - 1] == '\t'))
	{
		idx--;
	}

	while (idx > 0)
	{
		if (text[idx - 1] == ')' || text[idx - 1] == ']' || text[idx - 1] == '}')
		{
			while (idx > 0 && (text[idx - 1] == ')' || text[idx - 1] == ']' || text[idx - 1] == '}'))
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
				}
			}

			while (idx > 0 && (text[idx - 1].is_alnum() || text[idx - 1] == '_' || text[idx - 1] == '@' || text[idx - 1] == '#' || text[idx - 1] == '$'))
			{
				idx--;
			}
		}
		else if (text[idx - 1] == '"')
		{
			idx--;
			while (idx > 0)
			{
				if (text[idx - 1] == '"' && (idx == 1 || text[idx - 2] != '\\'))
				{
					idx--;
					break;
				}
				idx--;
			}
		}
		else if (text[idx - 1] == '\'')
		{
			idx--;
			while (idx > 0)
			{
				if (text[idx - 1] == '\'' && (idx == 1 || text[idx - 2] != '\\'))
				{
					idx--;
					break;
				}
				idx--;
			}
		}
		else if (text[idx - 1] == '`')
		{
			idx--;
			while (idx > 0 && text[idx - 1] != '`')
			{
				idx--;
			}
			if (idx > 0) idx--;
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

		sz p = idx;
		while (p > 0 && (text[p - 1] == ' ' || text[p - 1] == '\t'))
		{
			p--;
		}

		if (p >= 2 && text[p - 2] == ':' && text[p - 1] == ':')
		{
			idx = p - 2;
			while (idx > 0 && text[idx - 1].is_space())
			{
				idx--;
			}
		}
		else if (p >= 1 && text[p - 1] == '.')
		{
			idx = p - 1;
			while (idx > 0 && text[idx - 1].is_space())
			{
				idx--;
			}
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

	while (cursor_idx > 0 && (text[cursor_idx - 1] == ' ' || text[cursor_idx - 1] == '\t'))
	{
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

	while (cursor_idx > 0 && text[cursor_idx - 1].is_space())
	{
		cursor_idx--;
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

fn sz? find_top_level_dot(String expr)
{
	int paren_depth = 0;
	int bracket_depth = 0;
	int brace_depth = 0;
	bool in_str = false;
	bool in_char = false;
	bool in_raw = false;

	for (sz i = 0; i < expr.len; i++)
	{
		char c = expr[i];
		if (in_raw)
		{
			if (c == '`') in_raw = false;
			continue;
		}
		if (in_str)
		{
			if (c == '\\' && i + 1 < expr.len) { i++; continue; }
			if (c == '"') in_str = false;
			continue;
		}
		if (in_char)
		{
			if (c == '\\' && i + 1 < expr.len) { i++; continue; }
			if (c == '\'') in_char = false;
			continue;
		}

		switch (c)
		{
			case '`': in_raw = true;
			case '"': in_str = true;
			case '\'': in_char = true;
			case '(': paren_depth++;
			case ')': if (paren_depth > 0) paren_depth--;
			case '[': bracket_depth++;
			case ']': if (bracket_depth > 0) bracket_depth--;
			case '{': brace_depth++;
			case '}': if (brace_depth > 0) brace_depth--;
			case '.':
				if (paren_depth == 0 && bracket_depth == 0 && brace_depth == 0)
				{
					// Skip ranges (..) and ellipses (...)
					if (i + 1 < expr.len && expr[i + 1] == '.') continue;
					if (i > 0 && expr[i - 1] == '.') continue;
					// Skip float literal decimals (e.g. 3.14)
					if (i > 0 && expr[i - 1].is_digit() && i + 1 < expr.len && expr[i + 1].is_digit()) continue;
					return i;
				}
			default: break;
		}
	}
	return NOT_FOUND~;
}


fn String resolve_type_from_identifier_or_chain(Context* ctx, String base_id)
{
	if (base_id.len == 0) return "";

	String clean_id = base_id.trim();

	// Unwrap parentheses e.g. `(3.14)` -> `3.14`
	while (clean_id.starts_with("(") && clean_id.ends_with(")") && clean_id.len >= 2)
	{
		clean_id = clean_id[1 : ^2].trim();
	}

	// 1. Literals
	if ((clean_id.starts_with("\"") && clean_id.ends_with("\"")) || (clean_id.starts_with("`") && clean_id.ends_with("`")))
	{
		return "String";
	}
	if (clean_id.starts_with("'") && clean_id.ends_with("'") && clean_id.len >= 2)
	{
		return "char";
	}
	if (clean_id.len > 0 && (clean_id[0].is_digit() || (clean_id.starts_with("-") && clean_id.len > 1 && clean_id[1].is_digit())))
	{
		if (clean_id.ends_with("f") || clean_id.ends_with("f32")) return "float";
		if (clean_id.contains(".") || clean_id.ends_with("d") || clean_id.ends_with("f64")) return "double";
		if (clean_id.ends_with("ul") || clean_id.ends_with("UL")) return "ulong";
		if (clean_id.ends_with("l") || clean_id.ends_with("L")) return "long";
		if (clean_id.ends_with("u") || clean_id.ends_with("U")) return "uint";
		return "int";
	}

	if (clean_id.starts_with("$Typeof") || clean_id.starts_with("$Typefrom"))
	{
		String inner = "";
		if (try open_p = clean_id.index_of_char('('))
		{
			if (try close_p = clean_id.rindex_of_char(')'))
			{
				if (close_p > open_p)
				{
					inner = clean_id[open_p + 1 : close_p - open_p - 1].trim();
				}
			}
		}
		if (inner.len > 0)
		{
			return resolve_type_from_identifier_or_chain(ctx, inner);
		}
		return "";
	}

	if (clean_id.ends_with(")") && clean_id.contains("("))
	{
		if (try paren_idx = clean_id.index_of_char('('))
		{
			String fn_name = clean_id[:paren_idx].trim();
			if (ctx.ws && ctx.ws.ctx && ctx.ws.ctx.registry)
			{
				if (try fn_info = ctx.ws.ctx.registry.functions.get(fn_name))
				{
					if (fn_info.node && fn_info.node.kind == FN_DECL)
					{
						FnDecl* fd = fn_info.node.as(FnDecl);
						if (fd.ret_type) return cursor::raw_type_identifier(fd.ret_type) ?? "";
					}
				}
			}
		}
	}

	// 2. Chained dot expressions (a.b.c)
	if (try dot_idx = find_top_level_dot(clean_id))
	{
		String root_id = clean_id[:dot_idx].trim();
		String current_type = resolve_type_from_identifier_or_chain(ctx, root_id);
		String remaining = clean_id[dot_idx + 1..];

		while (current_type.len > 0 && remaining.len > 0)
		{
			String seg = remaining;
			if (try next_dot = find_top_level_dot(remaining))
			{
				seg = remaining[:next_dot].trim();
				remaining = remaining[next_dot + 1..];
			}
			else
			{
				remaining = "";
			}

			if (try paren_idx = seg.index_of_char('('))
			{
				seg = seg[:paren_idx].trim();
			}

			if (try brace_idx = current_type.index_of_char('{'))
			{
				current_type = current_type[:brace_idx].trim();
			}
			if ((current_type == "String" || current_type.ends_with("[]")) && seg == "len")
			{
				current_type = "sz";
				continue;
			}
			if (current_type == "String" && seg == "ptr")
			{
				current_type = "char*";
				continue;
			}

			Node* member = query::find_member_in_type(ctx.ws.ctx, current_type, seg, ctx.sf);
			if (member && member.kind == VAR_DECL)
			{
				VarDecl* vd = member.as(VarDecl);
				current_type = vd.type ? cursor::spelling(vd.type, tmem) : "";
			}
			else
			{
				Location loc = {
					.line = (int)ctx.position.line,
					.column = (int)ctx.position.character
				};
				Node* mnode = query::find_method_in_type(ctx.ws.ctx, current_type, seg, ctx.sf, loc);
				if (mnode && mnode.kind == FN_DECL)
				{
					FnDecl* fd = mnode.as(FnDecl);
					current_type = fd.ret_type ? cursor::spelling(fd.ret_type, tmem) : "";
				}
				else
				{
					return "";
				}
			}
		}

		return current_type;
	}

	if (try brace_idx = clean_id.index_of_char('{'))
	{
		clean_id = clean_id[:brace_idx].trim();
	}
	clean_id = clean_id.trim_right("*& \t");

	String type_name = "";
	if (ctx.sf)
	{
		Location loc = {
			.line = (int)ctx.position.line,
			.column = (int)ctx.position.character
		};
		(void)query::find_local_decl_in_file(ctx.sf, clean_id, &type_name, ctx.ws.ctx, loc);
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
							type_name = cursor::spelling(vd.type, tmem);
						}
					}
				default:
					break;
			}
		}
	}

	return type_name.len > 0 ? type_name : clean_id;
}

fn void inject_vector_swizzles(List{CompletionItem} * items, String prefix)
{
	const String[*] COMPS = {
		"x", "y", "z", "w", "r", "g", "b", "a", "u", "v",
		"xy", "yx", "xx", "yy", "xz", "yz", "zx", "zy", "zz",
		"xyz", "xzy", "yxz", "yzx", "zxy", "zyx",
		"xyzw", "rgba"
	};
	foreach (c : COMPS)
	{
		if (prefix.len == 0 || c.starts_with(prefix))
		{
			items.push(
			{
				.label = c,
				.kind = FIELD,
				.detail = "swizzle",
				.insertText = c,
				.filterText = c,
				.sortText = string::tformat("0001_%s", c),
				.data = "property"
			}
			);
		}
	}
}

fn bool is_matching_associated_type(Node* assoc_type_node, String clean_type, String type_name)
{
	if (!assoc_type_node) return false;
	String assoc_raw = cursor::raw_type_identifier(assoc_type_node) ?? "";
	String assoc_spell = cursor::spelling(assoc_type_node, tmem);

	String target_clean = clean_type.trim_right("*& \t");
	String target_raw = type_name.trim_right("*& \t");

	if (assoc_raw.len > 0 && (assoc_raw == target_clean || assoc_raw == target_raw)) return true;
	if (assoc_spell.len > 0 && (assoc_spell == target_clean || assoc_spell == target_raw)) return true;

	if (query::is_vector_type(clean_type))
	{
		if (query::is_vector_type(assoc_spell) || query::is_vector_type(assoc_raw)) return true;
	}

	return false;
}

fn void provide_methods_for_type(Context* ctx, List{CompletionItem} * items, String type_name, HashSet{String} * seen_methods)
{
	if (!ctx.ws || !ctx.ws.ctx || type_name.len == 0) return;

	String clean_type = type_name.trim_right("*& \t");
	if (try brace_idx = clean_type.index_of_char('{'))
	{
		clean_type = clean_type[:brace_idx].trim();
	}
	clean_type = clean_type.trim_right("*& \t");

	Registry* reg = ctx.ws.ctx.registry;
	if (reg)
	{
		reg.functions.@each(; qname, fn_info)
		{
			FunctionInfo* curr = fn_info;
			while (curr != null)
			{
				if (curr.node && curr.node.kind == FN_DECL)
				{
					FnDecl* fndecl = curr.node.as(FnDecl);
					if (fndecl.associated_type && is_matching_associated_type(fndecl.associated_type, clean_type, type_name))
					{
						if (is_symbol_accessible(ctx.sf, ctx.caller_mod, curr.node, curr.mod))
						{
							String mname = fndecl.name ? fndecl.name.text : "";
							if (mname.len > 0 && (ctx.prefix.len == 0 || mname.starts_with(ctx.prefix)))
							{
								if (seen_methods.add(mname))
								{
									add_symbol_completion(ctx, items, mname, curr.node, clean_type, ctx.prefix);
								}
							}
						}
					}
				}
				curr = curr.next;
			}
		};

		reg.macros.@each(; qname, mac_info)
		{
			MacroInfo* curr = mac_info;
			while (curr != null)
			{
				if (curr.node && curr.node.kind == MACRO_DECL)
				{
					MacroDecl* mac = curr.node.as(MacroDecl);
					if (try assoc_node = mac.associated_type.get())
					{
						if (is_matching_associated_type(assoc_node, clean_type, type_name))
						{
							if (is_symbol_accessible(ctx.sf, ctx.caller_mod, curr.node, curr.mod))
							{
								String mname = mac.name ? mac.name.text : "";
								if (mname.len > 0 && (ctx.prefix.len == 0 || mname.starts_with(ctx.prefix)))
								{
									if (seen_methods.add(mname))
									{
										add_symbol_completion(ctx, items, mname, curr.node, clean_type, ctx.prefix);
									}
								}
							}
						}
					}
				}
				curr = curr.next;
			}
		};
	}

	Node* type_node = query::find_type_node_in_context(ctx.ws.ctx, ctx.sf, clean_type);
	if (type_node)
	{
		switch (type_node.kind)
		{
			case TYPEDEF_DECL:
				{
					TypedefDecl* td = type_node.as(TypedefDecl);
					if (td.is_inline && td.base_type)
					{
						String base_type_str = cursor::raw_type_identifier(td.base_type) ?? cursor::spelling(td.base_type, tmem);
						if (base_type_str.len > 0 && base_type_str != clean_type)
						{
							provide_methods_for_type(ctx, items, base_type_str, seen_methods);
						}
					}
				}
			case STRUCT_DECL:
				{
					StructDecl* sd = type_node.as(StructDecl);
					foreach (field : sd.fields)
					{
						if (!field || field.kind != VAR_DECL) continue;
						VarDecl* vd = field.as(VarDecl);
						if (vd.var_flags.is_inline && vd.type)
						{
							String sub_type = cursor::raw_type_identifier(vd.type) ?? "";
							if (sub_type.len > 0 && sub_type != clean_type)
							{
								provide_methods_for_type(ctx, items, sub_type, seen_methods);
							}
						}
					}
					foreach (inter : sd.interfaces)
					{
						String inter_type = cursor::raw_type_identifier(inter) ?? "";
						if (inter_type.len > 0 && inter_type != clean_type)
						{
							provide_methods_for_type(ctx, items, inter_type, seen_methods);
						}
					}
				}
			default:
				break;
		}
	}
}

fn void provide_enum_variants(List{CompletionItem} * items, Node* enum_node, String type_name, String prefix, bool missing_second_colon = false)
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

fn bool provide_member_access(Context* ctx, List{CompletionItem} * items)
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

				if (clean_type.len == 0) return false;

				HashSet{String} seen_methods;
				seen_methods.tinit();

				Node* type_node = query::find_type_node_in_context(ctx.ws.ctx, ctx.sf, clean_type);
				if (!type_node && ctx.ws)
				{
					List{SymbolEntry} syms = ctx.ws.find_symbol_by_name(clean_type, ctx.sf);
					if (syms.len() > 0 && syms.get(0).node)
					{
						type_node = syms.get(0).node;
					}
				}

				if (type_node && type_node.kind == ENUM_DECL)
				{
					provide_enum_variants(items, type_node, clean_type, ctx.prefix, false);
					provide_methods_for_type(ctx, items, clean_type, &seen_methods);
					return true;
				}

				if (query::is_vector_type(clean_type))
				{
					inject_vector_swizzles(items, ctx.prefix);
				}

				if (clean_type == "String" || clean_type.ends_with("[]") || clean_type.contains("["))
				{
					if (ctx.prefix.len == 0 || ((String)"len").starts_with(ctx.prefix))
					{
						items.push(
						{
							.label = "len",
							.kind = PROPERTY,
							.detail = "sz",
							.insertText = "len",
							.filterText = "len",
							.sortText = "0001_len",
							.data = "property"
						}
						);
					}
					if (clean_type == "String" || clean_type.ends_with("[]"))
					{
						if (ctx.prefix.len == 0 || ((String)"ptr").starts_with(ctx.prefix))
						{
							String ptr_type = clean_type == "String" ? "char*" : string::tformat("%s*", clean_type.strip_suffix("[]"));
							items.push(
							{
								.label = "ptr",
								.kind = PROPERTY,
								.detail = ptr_type,
								.insertText = "ptr",
								.filterText = "ptr",
								.sortText = "0001_ptr",
								.data = "property"
							}
							);
						}
					}
				}

				if (type_node && type_node.kind == STRUCT_DECL)
				{
					StructDecl* st = type_node.as(StructDecl);
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
				}

				provide_methods_for_type(ctx, items, type_name, &seen_methods);
				return true;
			}

		default:
			return false;
	}
}
