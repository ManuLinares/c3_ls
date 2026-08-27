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

fn void detect_access_context(Context* ctx, SourceFile* sf)
{
	ctx.access = NONE;
	ctx.base_identifier = "";

	if (!sf || ctx.offset == 0 || ctx.offset > sf.content.len) return;

	String text = sf.content[:ctx.offset];
	sz cursor_idx = text.len;

	while (cursor_idx > 0)
	{
		char c = text[cursor_idx - 1];
		if (!c.is_alnum() && c != '_' && c != '@' && c != '#' && c != '$') break;
		cursor_idx--;
	}

	String text_before = text[:cursor_idx];

	if (text_before.ends_with("::"))
	{
		ctx.access = STATIC;
		cursor_idx -= 2;
	}
	else if (text_before.ends_with("."))
	{
		ctx.access = INSTANCE;
		cursor_idx -= 1;
	}
	else
	{
		return;
	}

	sz base_end = cursor_idx;
	sz base_start = base_end;
	while (base_start > 0)
	{
		char c = text[base_start - 1];
		if (!c.is_alnum() && c != '_' && c != '@' && c != '#' && c != '$') break;
		base_start--;
	}

	if (base_end > base_start)
	{
		ctx.base_identifier = text[base_start : base_end - base_start];
	}
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

fn void provide_enum_variants(List{CompletionItem}* items, Node* enum_node, String type_name, String prefix)
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
			items.push(
			{
				.label = vname,
				.kind = ENUMMEMBER,
				.detail = string::tformat("enum %s", type_name),
				.insertText = vname,
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
	if (ctx.access == NONE || ctx.base_identifier.len == 0) return false;

	switch (ctx.access)
	{
		case STATIC:
			{
				if (ctx.ws && ctx.ws.ctx)
				{
					Module* mod = analysis::find_module_by_identifier(ctx.ws, "", ctx.base_identifier);
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
										add_symbol_completion(ctx, items, fname, fault_node, ctx.base_identifier, ctx.prefix);
									}
								}
								continue;
							}

							if (!is_symbol_accessible(ctx.sf, ctx.caller_mod, node, mod.name)) continue;

							String sym_name = cursor::spelling(node, tmem);
							if (sym_name.len == 0) continue;
							if (ctx.prefix.len == 0 || sym_name.starts_with(ctx.prefix))
							{
								add_symbol_completion(ctx, items, sym_name, node, ctx.base_identifier, ctx.prefix);
							}
						}
						return true;
					}
				}

				List{SymbolEntry} syms = ctx.ws.find_symbol_by_name(ctx.base_identifier);
				if (syms.len() > 0 && syms.get(0).node)
				{
					Node* sym_node = syms.get(0).node;
					if (sym_node.kind == ENUM_DECL)
					{
						provide_enum_variants(items, sym_node, ctx.base_identifier, ctx.prefix);
					}

					analysis::inject_type_properties(items, sym_node.kind);
					return true;
				}

				if (constants::is_primitive(ctx.base_identifier))
				{
					analysis::inject_type_properties(items, NodeKind.VAR_DECL);
					return true;
				}

				return false;
			}

		case INSTANCE:
			{
				Node* target_struct = null;
				String type_name = "";

				if (ctx.sf)
				{
					(void)query::find_local_decl_in_file(ctx.sf, ctx.base_identifier, &type_name, ctx.ws.ctx);
				}

				if (type_name.len == 0)
				{
					List{SymbolEntry} syms = ctx.ws.find_symbol_by_name(ctx.base_identifier);
					if (syms.len() > 0 && syms.get(0).node)
					{
						Node* base_node = syms.get(0).node;
						switch (base_node.kind)
						{
						case STRUCT_DECL:
							target_struct = base_node;
							type_name = ctx.base_identifier;
						case ENUM_DECL:
							provide_enum_variants(items, base_node, ctx.base_identifier, ctx.prefix);
							return true;
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

				if (type_name.len > 0)
				{
					List{SymbolEntry} syms = ctx.ws.find_symbol_by_name(type_name);
					if (syms.len() > 0 && syms.get(0).node)
					{
						Node* type_node = syms.get(0).node;
						if (type_node.kind == ENUM_DECL)
						{
							provide_enum_variants(items, type_node, type_name, ctx.prefix);
							return true;
						}
						else if (type_node.kind == STRUCT_DECL)
						{
							target_struct = type_node;
						}
					}
				}

				if (query::is_vector_type(type_name))
				{
					inject_vector_completions(items, ctx.prefix);
					return true;
				}

				if (target_struct && target_struct.kind == STRUCT_DECL)
				{
					StructDecl* st = target_struct.as(StructDecl);
					foreach (field : st.fields)
					{
						if (!field || field.kind != VAR_DECL) continue;
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
								.data = string::tformat("field:%s:%s", type_name, fname)
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
									if (assoc == type_name)
									{
										String mname = fndecl.name ? fndecl.name.text : "";
										if (mname.len > 0 && (ctx.prefix.len == 0 || mname.starts_with(ctx.prefix)))
										{
											add_symbol_completion(ctx, items, mname, fn_info.node, type_name, ctx.prefix);
										}
									}
								}
							}
						};
					}

					return true;
				}
				return false;
			}

		default:
			return false;
	}
}