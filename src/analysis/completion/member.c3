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

fn String resolve_root_initializer_type(Context* ctx, SourceFile* sf, sz pos)
{
	if (!sf || pos == 0 || pos > sf.content.len) return "";

	sz line_start = pos;
	while (line_start > 0 && sf.content[line_start - 1] != '\n' && sf.content[line_start - 1] != ';')
	{
		line_start--;
	}

	String line_segment = sf.content[line_start : pos - line_start].trim();
	while (line_segment.ends_with("(") || line_segment.ends_with("{") || line_segment.ends_with(","))
	{
		line_segment = line_segment[:^1].trim_right();
	}
	if (line_segment.len == 0) return "";

	// 1. Compound literal
	if (line_segment.ends_with(")"))
	{
		int pdepth = 1;
		sz p = line_segment.len - 1;
		while (p > 0 && pdepth > 0)
		{
			p--;
			if (line_segment[p] == ')')
			{
				pdepth++;
			}
			else if (line_segment[p] == '(')
			{
				pdepth--;
			}
		}
		if (pdepth == 0)
		{
			String inside = line_segment[p + 1 : line_segment.len - 1 - (p + 1)].trim();
			while (inside.starts_with("(") && inside.ends_with(")") && inside.len >= 2)
			{
				inside = inside[1 : ^2].trim();
			}
			if (try br_idx = inside.index_of_char('['))
			{
				inside = inside[:br_idx].trim();
			}
			inside = inside.trim_right("*& \t");
			if (inside.len > 0 && (inside[0].is_upper() || inside.contains("::")))
			{
				return inside;
			}
		}
	}

	// 2. Call argument context
	CallTargetInfo target_info = analysis::parse_call_context(sf.content, pos);
	if (target_info.is_valid)
	{
		Location loc = { .line = (int)ctx.position.line, .column = (int)ctx.position.character };
		Node* callee_node = (ctx.ws && ctx.ws.ctx) ? query::resolve_callee_by_name(ctx.ws.ctx, sf, target_info.callee_name, loc) : null;
		if (callee_node)
		{
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

			sz param_offset = (target_info.callee_name.contains(".") && is_method) ? 1 : 0;
			sz param_idx = (sz)target_info.active_param + param_offset;
			if (param_idx < params.len)
			{
				Node* p = params[param_idx];
				if (p && p.kind == VAR_DECL)
				{
					VarDecl* vd = p.as(VarDecl);
					if (vd.type)
					{
						String type_str = cursor::raw_type_identifier(vd.type) ?? cursor::spelling(vd.type, tmem);
						type_str = type_str.trim_right("*& \t");
						if (type_str.len > 0) return type_str;
					}
				}
			}
		}

		if (pos > target_info.open_paren_idx + 1)
		{
			String args_part = sf.content[target_info.open_paren_idx + 1 : pos - (target_info.open_paren_idx + 1)].trim();
			String[] args = args_part.tsplit(",");
			foreach (arg : args)
			{
				String candidate = arg.trim().trim_right("*& \t");
				while (candidate.starts_with("(") && candidate.ends_with(")") && candidate.len >= 2)
				{
					candidate = candidate[1 : ^2].trim().trim_right("*& \t");
				}
				if (candidate.len > 0 && (candidate[0].is_upper() || candidate.contains("::")))
				{
					return candidate;
				}
			}
		}
	}

	// 3. Assignment / Variable Declaration
	if (try eq_idx = line_segment.rindex_of_char('='))
	{
		String lhs = line_segment[:eq_idx].trim();
		String[] words = lhs.tsplit(" ");
		if (words.len >= 2)
		{
			String candidate = words[^2].trim().trim_right("*& \t");
			if (candidate.len > 0 && (candidate[0].is_upper() || candidate.contains("::")))
			{
				return candidate;
			}
		}
		if (words.len >= 1)
		{
			String var_expr = words[^1].trim();
			Location loc = { .line = (int)ctx.position.line, .column = (int)ctx.position.character };
			String res_type = "";
			if (ctx.ws && ctx.ws.ctx)
			{
				res_type = query::resolve_type_of_chain(ctx.ws.ctx, sf, var_expr, loc);
			}
			if (res_type.len == 0)
			{
				(void)query::find_local_decl_in_file(sf, var_expr, &res_type, ctx.ws ? ctx.ws.ctx : null, loc);
			}
			if (res_type.len > 0) return res_type;
		}
	}

	// 4. Return statement
	if (line_segment.starts_with("return") || line_segment.contains("return "))
	{
		Location loc = { .line = (int)ctx.position.line, .column = (int)ctx.position.character };
		foreach (stmt : sf.ast.statements)
		{
			if (stmt && stmt.range.contains(loc) && stmt.kind == FN_DECL)
			{
				FnDecl* fd = stmt.as(FnDecl);
				if (fd.ret_type) return cursor::raw_type_identifier(fd.ret_type) ?? "";
			}
		}
	}

	return "";
}

fn String apply_field_path(Context* ctx, SourceFile* sf, String root_type, List{String} field_path)
{
	String curr_type = root_type.trim_right("*& \t");
	if (try br_idx = curr_type.index_of_char('['))
	{
		curr_type = curr_type[:br_idx].trim();
	}
	if (try br_idx = curr_type.index_of_char('{'))
	{
		curr_type = curr_type[:br_idx].trim();
	}

	for (sz i = field_path.len(); i > 0; i--)
	{
		String field_name = field_path.get(i - 1);
		Node* member = null;
		if (ctx.ws && ctx.ws.ctx)
		{
			member = query::find_member_in_type(ctx.ws.ctx, curr_type, field_name, sf);
		}
		if (member && member.kind == VAR_DECL)
		{
			VarDecl* vd = member.as(VarDecl);
			if (vd.type)
			{
				curr_type = cursor::raw_type_identifier(vd.type) ?? cursor::spelling(vd.type, tmem);
				curr_type = curr_type.trim_right("*& \t");
				if (try br_idx = curr_type.index_of_char('['))
				{
					curr_type = curr_type[:br_idx].trim();
				}
				if (try br_idx = curr_type.index_of_char('{'))
				{
					curr_type = curr_type[:br_idx].trim();
				}
			}
			else
			{
				return "";
			}
		}
		else
		{
			return "";
		}
	}

	return curr_type;
}

fn String find_designated_initializer_type(Context* ctx, SourceFile* sf, sz dot_offset)
{
	if (!sf || dot_offset == 0 || dot_offset > sf.content.len) return "";

	String text = sf.content[:dot_offset];
	List{String} field_path;
	field_path.tinit();

	sz idx = text.len;

	while (idx > 0)
	{
		int brace_depth = 0;
		int paren_depth = 0;
		int bracket_depth = 0;
		bool in_str = false;
		bool in_char = false;
		bool in_raw = false;
		sz open_brace_idx = 0;
		bool found_open_brace = false;

		for (sz i = idx; i > 0; i--)
		{
			char c = text[i - 1];

			if (c == '`') { in_raw = !in_raw; continue; }
			if (in_raw) continue;
			if (c == '"' && (i < 2 || text[i - 2] != '\\')) { in_str = !in_str; continue; }
			if (in_str) continue;
			if (c == '\'' && (i < 2 || text[i - 2] != '\\')) { in_char = !in_char; continue; }
			if (in_char) continue;

			switch (c)
			{
				case '}': brace_depth++;
				case '{':
					if (brace_depth > 0)
					{
						brace_depth--;
					}
					else
					{
						open_brace_idx = i - 1;
						found_open_brace = true;
					}
				case ')': paren_depth++;
				case '(': if (paren_depth > 0) paren_depth--;
				case ']': bracket_depth++;
				case '[': if (bracket_depth > 0) bracket_depth--;
				default: break;
			}
			if (found_open_brace) break;
		}

		if (!found_open_brace) return "";

		sz p = open_brace_idx;
		while (p > 0 && text[p - 1].is_space()) p--;

		if (p > 0 && text[p - 1] == '=')
		{
			p--;
			while (p > 0 && text[p - 1].is_space()) p--;

			sz name_end = p;
			while (p > 0 && (text[p - 1].is_alnum() || text[p - 1] == '_')) p--;
			sz name_start = p;

			if (p > 0 && text[p - 1] == '.')
			{
				String field_name = text[name_start : name_end - name_start].trim();
				if (field_name.len > 0)
				{
					field_path.push(field_name);
					idx = p - 1;
					continue;
				}
			}

			String root_type = resolve_root_initializer_type(ctx, sf, open_brace_idx);
			if (root_type.len > 0)
			{
				return apply_field_path(ctx, sf, root_type, field_path);
			}
			return "";
		}

		String root_type = resolve_root_initializer_type(ctx, sf, open_brace_idx);
		if (root_type.len > 0)
		{
			return apply_field_path(ctx, sf, root_type, field_path);
		}

		if (p > 0 && (text[p - 1] == '{' || text[p - 1] == ',' || text[p - 1] == '('))
		{
			idx = p;
			continue;
		}

		return "";
	}

	return "";
}

fn void detect_access_context(Context* ctx, SourceFile* sf)
{
	ctx.access = NONE;
	ctx.base_identifier = "";
	ctx.missing_second_colon = false;

	if (!sf || ctx.offset == 0 || ctx.offset > sf.content.len) return;

	String text = sf.content[:ctx.offset];
	sz cursor_idx = text.len;

	while (cursor_idx > 0)
	{
		char c = text[cursor_idx - 1];
		if (!c.is_alnum() && c != '_' && c != '@' && c != '#' && c != '$') break;
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

	while (cursor_idx > 0 && text[cursor_idx - 1].is_space()) cursor_idx--;

	sz base_end = cursor_idx;
	sz base_start = scan_base_expression_start(text, base_end);

	if (base_end > base_start)
	{
		ctx.base_identifier = text[base_start : base_end - base_start];
	}
	else
	{
		String struct_type = find_designated_initializer_type(ctx, sf, cursor_idx);
		if (struct_type.len > 0)
		{
			ctx.access = INSTANCE;
			ctx.base_identifier = struct_type;
		}
		else
		{
			ctx.access = NONE;
			ctx.missing_second_colon = false;
		}
	}
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
			case ALIAS_DECL:
				{
					AliasDecl* ad = type_node.as(AliasDecl);
					if (ad.target)
					{
						if (ad.target.kind == TERNARY_EXPR)
						{
							TernaryExpr* ter = ad.target.as(TernaryExpr);
							if (ter.then_expr)
							{
								String t_type = cursor::raw_type_identifier(ter.then_expr) ?? cursor::spelling(ter.then_expr, tmem);
								t_type = t_type.trim_right("*& \t");
								if (t_type.len > 0 && t_type != clean_type)
								{
									provide_methods_for_type(ctx, items, t_type, seen_methods);
								}
							}
							if (ter.else_expr)
							{
								String e_type = cursor::raw_type_identifier(ter.else_expr) ?? cursor::spelling(ter.else_expr, tmem);
								e_type = e_type.trim_right("*& \t");
								if (e_type.len > 0 && e_type != clean_type)
								{
									provide_methods_for_type(ctx, items, e_type, seen_methods);
								}
							}
						}
						else
						{
							String target_type = cursor::raw_type_identifier(ad.target) ?? cursor::spelling(ad.target, tmem);
							target_type = target_type.trim_right("*& \t");
							if (target_type.len > 0 && target_type != clean_type)
							{
								provide_methods_for_type(ctx, items, target_type, seen_methods);
							}
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
	if (!enum_node || enum_node.kind != ENUM_DECL) return;
	EnumDecl* enum_decl = enum_node.as(EnumDecl);

	foreach (variant : enum_decl.variants)
	{
		if (!variant || variant.kind != VAR_DECL) continue;
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

fn void collect_struct_fields_recursive(Context* ctx, List{CompletionItem} * items, Node* struct_node, String type_name, HashSet{String} * seen_fields)
{
	if (!struct_node || struct_node.kind != STRUCT_DECL) return;

	StructDecl* current_st = struct_node.as(StructDecl);
	while (current_st != null)
	{
		foreach (field : current_st.fields)
		{
			if (!field || field.kind != VAR_DECL) continue;
			VarDecl* fdecl = field.as(VarDecl);
			while (fdecl != null)
			{
				String fname = fdecl.name ? fdecl.name.text : "";
				if (fname.len > 0 && (ctx.prefix.len == 0 || fname.starts_with(ctx.prefix)))
				{
					if (seen_fields.add(fname))
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
							.data = string::tformat("field:%s:%s", type_name, fname)
						}
						);
					}
				}
				if (fdecl.var_flags.is_inline && fdecl.type)
				{
					String sub_type = cursor::raw_type_identifier(fdecl.type) ?? cursor::spelling(fdecl.type, tmem);
					sub_type = sub_type.trim_right("*& \t");
					if (sub_type.len > 0)
					{
						Node* sub_node = query::find_type_node_in_context(ctx.ws.ctx, ctx.sf, sub_type);
						if (!sub_node && ctx.ws)
						{
							List{SymbolEntry} syms = ctx.ws.find_symbol_by_name(sub_type, ctx.sf);
							if (syms.len() > 0 && syms.get(0).node)
							{
								sub_node = syms.get(0).node;
							}
						}
						if (sub_node && sub_node.kind == STRUCT_DECL)
						{
							collect_struct_fields_recursive(ctx, items, sub_node, sub_type, seen_fields);
						}
					}
				}
				fdecl = fdecl.next ? fdecl.next.as(VarDecl) : null;
			}
		}
		current_st = current_st.next ? current_st.next.as(StructDecl) : null;
	}
}

fn bool provide_member_access(Context* ctx, List{CompletionItem} * items)
{
	if (ctx.access == NONE || ctx.base_identifier.len == 0) return false;

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
				Location loc = { .line = (int)ctx.position.line, .column = (int)ctx.position.character };
				String type_name = query::resolve_type_of_chain(ctx.ws.ctx, ctx.sf, base_id, loc);
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
							if (!node || node.kind == ERROR) continue;

							if (node.kind == FAULTDEF_DECL)
							{
								FaultdefDecl* fd = node.as(FaultdefDecl);
								foreach (fault_node : fd.faults)
								{
									if (!fault_node || fault_node.kind != FAULT_DECL) continue;
									if (!is_symbol_accessible(ctx.sf, ctx.caller_mod, fault_node, mod.name)) continue;

									FaultDecl* fdecl = fault_node.as(FaultDecl);
									String fname = fdecl.name ? fdecl.name.text : "";
									if (fname.len > 0 && (ctx.prefix.len == 0 || fname.starts_with(ctx.prefix)))
									{
										add_symbol_completion(ctx, items, fname, fault_node, clean_type, ctx.prefix);
									}
								}
								continue;
							}

							if (!is_symbol_accessible(ctx.sf, ctx.caller_mod, node, mod.name)) continue;

							String sym_name = cursor::spelling(node, tmem);
							if (sym_name.len == 0) continue;
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
				Location loc = { .line = (int)ctx.position.line, .column = (int)ctx.position.character };
				String type_name = query::resolve_type_of_chain(ctx.ws.ctx, ctx.sf, base_id, loc);
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
					HashSet{String} seen_fields;
					seen_fields.tinit();
					collect_struct_fields_recursive(ctx, items, type_node, clean_type, &seen_fields);
				}

				provide_methods_for_type(ctx, items, type_name, &seen_methods);
				return true;
			}

		default:
			return false;
	}
}
