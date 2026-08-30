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
import uri;
import analyzer::lexer;
import lsp::analysis;
import lsp::analysis::hover;

struct Context
{
	Uri uri;
	LspPosition position;
	sz offset;
	LspWorkspace* ws;
	SourceFile* sf;
	Allocator allocator;
	String prefix;
	ScopeKind scope;
	LspAccessKind access;
	String base_identifier;
	String expected_type;
	String caller_mod;
	bool missing_second_colon;
}

fn void resolve_item(LspProject* project, CompletionItem* item)
{
	if (!project || !item || item.label.len == 0) return;

	if (item.documentation.kind.len == 0)
	{
		item.documentation.kind = MARKDOWN;
	}

	if (item.kind == KEYWORD) return;

	Node* target_node = null;

	if (item.data.len > 0)
	{
		if (item.data == "property") return;

		if (item.data.starts_with("local:"))
		{
			String vname = item.data.strip_prefix("local:");
			String vtype = item.detail.len > 0 ? item.detail : "var";
			DString md_buf;
			md_buf.tinit();
			md_buf.appendf("```c3\n%s %s\n```", vtype, vname);
			item.documentation = {
				.kind = MARKDOWN,
				.value = md_buf.str_view()
			};
			return;
		}

		if (item.data.starts_with("module:"))
		{
			String mod_name = item.data.strip_prefix("module:");
			String doc_comment = "";
			if (project.workspace.ctx)
			{
				Module* mod = analysis::find_module_by_identifier(&project.workspace, "", mod_name);
				if (mod && mod.module_decls.len() > 0)
				{
					doc_comment = cursor::docs((Node*)mod.module_decls.get(0)) ?? "";
				}
			}

			DString md_buf;
			md_buf.tinit();
			md_buf.appendf("```c3\nmodule %s;\n```", mod_name);
			if (doc_comment.len > 0)
			{
				String clean_doc = doc_comment.trim().treplace("\"", "");
				if (clean_doc.len > 0)
				{
					md_buf.appendf("\n\n%s", clean_doc);
				}
			}

			item.documentation = {
				.kind = MARKDOWN,
				.value = md_buf.str_view()
			};
			return;
		}

		if (item.data.starts_with("enum_variant:"))
		{
			String payload = item.data.strip_prefix("enum_variant:");
			if (try colon_idx = payload.index_of_char(':'))
			{
				String enum_name = payload[:colon_idx];
				String variant_name = payload[colon_idx + 1..];

				String doc_comment = "";
				if (project.workspace.ctx)
				{
					List{SymbolEntry} syms = project.workspace.find_symbol_by_name(enum_name);
					if (syms.len() > 0 && syms.get(0).node && syms.get(0).node.kind == ENUM_DECL)
					{
						EnumDecl* ed = syms.get(0).node.as(EnumDecl);
						foreach (v : ed.variants)
						{
							if (v && v.kind == VAR_DECL && v.as(VarDecl).name && v.as(VarDecl).name.text == variant_name)
							{
								doc_comment = cursor::docs(v) ?? "";
								break;
							}
						}
					}
				}

				DString md_buf;
				md_buf.tinit();
				md_buf.appendf("```c3\n%s.%s\n```", enum_name, variant_name);
				if (doc_comment.len > 0)
				{
					String clean_doc = doc_comment.trim().treplace("\"", "");
					if (clean_doc.len > 0)
					{
						md_buf.appendf("\n\n%s", clean_doc);
					}
				}

				item.documentation = {
					.kind = MARKDOWN,
					.value = md_buf.str_view()
				};
				return;
			}
		}
		else if (item.data.starts_with("method:"))
		{
			String payload = item.data.strip_prefix("method:");
			if (try colon_idx = payload.index_of_char(':'))
			{
				String type_name = payload[:colon_idx];
				String method_name = payload[colon_idx + 1..];
				target_node = query::find_method_in_type(project.workspace.ctx, type_name, method_name);
			}
		}
		else if (item.data.starts_with("field:"))
		{
			String payload = item.data.strip_prefix("field:");
			if (try colon_idx = payload.index_of_char(':'))
			{
				String type_name = payload[:colon_idx];
				String field_name = payload[colon_idx + 1..];
				target_node = query::find_member_in_type(project.workspace.ctx, type_name, field_name);
			}
		}
		else if (item.data.starts_with("symbol:"))
		{
			String payload = item.data.strip_prefix("symbol:");
			String base = "";
			String sym = payload;
			if (try colon_idx = payload.index_of_char(':'))
			{
				base = payload[:colon_idx];
				sym = payload[colon_idx + 1..];
			}
			else if (item.detail.contains(" via "))
			{
				sz via_idx = item.detail.index_of(" via ") ?? 0;
				base = item.detail[via_idx + 5..].trim();
			}

			if (base.len > 0 && project.workspace.ctx)
			{
				AnalyzerContext* actx = project.workspace.ctx;
				Module* mod = analysis::find_module_by_identifier(&project.workspace, "", base);
				if (mod)
				{
					String qname = string::tformat("%s::%s", mod.name, sym);
					if (actx.registry)
					{
						if (try fn_info = actx.registry.functions.get(qname))
						{
							target_node = fn_info.node;
						}
						else if (try mac_info = actx.registry.macros.get(qname))
						{
							target_node = mac_info.node;
						}
						else if (try ty_info = actx.registry.types.get(qname))
						{
							target_node = ty_info.node;
						}
					}
					if (!target_node)
					{
						foreach (n : mod.nodes)
						{
							if (!n || n.kind == ERROR) continue;
							if (n.kind == FAULTDEF_DECL)
							{
								FaultdefDecl* fd = n.as(FaultdefDecl);
								foreach (fault_node : fd.faults)
								{
									if (!fault_node || fault_node.kind != FAULT_DECL) continue;
									FaultDecl* fdecl = fault_node.as(FaultDecl);
									if (fdecl.name && fdecl.name.text == sym)
									{
										target_node = fault_node;
										break;
									}
								}
								if (target_node) break;
							}
							String sname = cursor::spelling(n, tmem);
							if (sname == sym || sname.strip_prefix("@") == sym.strip_prefix("@"))
							{
								target_node = n;
								break;
							}
						}
					}
				}

				if (!target_node)
				{
					target_node = query::find_method_in_type(actx, base, sym);
				}
				if (!target_node)
				{
					target_node = query::find_member_in_type(actx, base, sym);
				}
			}
		}
	}

	if (item.kind == MODULE)
	{
		DString md_buf;
		md_buf.tinit();
		md_buf.appendf("```c3\nmodule %s;\n```", item.label);
		item.documentation = {
			.kind = MARKDOWN,
			.value = md_buf.str_view()
		};
		return;
	}

	if (item.documentation.value.len > 0) return;

	String sym_name = item.label;

	if (!target_node && item.detail.contains(" via "))
	{
		sz via_idx = item.detail.index_of(" via ") ?? 0;
		String base = item.detail[via_idx + 5..].trim();
		if (base.len > 0 && project.workspace.ctx)
		{
			AnalyzerContext* actx = project.workspace.ctx;
			Module* mod = analysis::find_module_by_identifier(&project.workspace, "", base);
			if (mod)
			{
				String qname = string::tformat("%s::%s", mod.name, sym_name);
				if (actx.registry)
				{
					if (try fn_info = actx.registry.functions.get(qname))
					{
						target_node = fn_info.node;
					}
					else if (try mac_info = actx.registry.macros.get(qname))
					{
						target_node = mac_info.node;
					}
					else if (try ty_info = actx.registry.types.get(qname))
					{
						target_node = ty_info.node;
					}
				}
			}
			if (!target_node)
			{
				target_node = query::find_method_in_type(actx, base, sym_name);
			}
			if (!target_node)
			{
				target_node = query::find_member_in_type(actx, base, sym_name);
			}
		}
	}

	if (!target_node)
	{
		List{SymbolEntry} syms = project.workspace.find_symbol_by_name(sym_name);
		if (syms.len() == 0 && sym_name.starts_with("@"))
		{
			syms = project.workspace.find_symbol_by_name(sym_name.strip_prefix("@"));
		}
		if (syms.len() > 0 && syms.get(0).node)
		{
			target_node = syms.get(0).node;
		}
	}

	if (!target_node) return;

	String sig = hover::format_node_signature(target_node, sym_name);
	String doc_comment = cursor::docs(target_node) ?? "";

	DString md_buf;
	md_buf.tinit();
	md_buf.appendf("```c3\n%s\n```", sig);

	if (doc_comment.len > 0)
	{
		String clean_doc = doc_comment.trim().treplace("\"", "");
		if (clean_doc.len > 0)
		{
			md_buf.appendf("\n\n%s", clean_doc);
		}
	}

	item.documentation = {
		.kind = MARKDOWN,
		.value = md_buf.str_view()
	};
}

fn ScopeKind detect_completion_scope(SourceFile* sf, sz offset, String* out_expected_type, AnalyzerContext* actx = null, Location loc = { -1, -1 })
{
	if (!sf || offset == 0 || offset > sf.content.len) return EXECUTION;

	sz line_start = offset;
	while (line_start > 0 && sf.content[line_start - 1] != '\n')
	{
		line_start--;
	}

	String line_prefix = sf.content[line_start : offset - line_start].trim_left();

	if (line_prefix == "import" || line_prefix.starts_with("import ") || line_prefix.starts_with("import\t"))
	{
		return IMPORT;
	}

	if (try eq_idx = line_prefix.rindex_of_char('='))
	{
		if (eq_idx == 0 || (line_prefix[eq_idx - 1] != '=' && line_prefix[eq_idx - 1] != '!' && line_prefix[eq_idx - 1] != '<' && line_prefix[eq_idx - 1] != '>'))
		{
			String lhs = line_prefix[:eq_idx].trim();
			String[] words = lhs.tsplit(" ");
			if (words.len >= 2)
			{
				String candidate_type = words[^2].trim().trim_right("*& \t");
				if (candidate_type.len > 0 && (candidate_type[0].is_upper() || candidate_type.contains("::") || candidate_type == "fault"))
				{
					if (out_expected_type) *out_expected_type = candidate_type;
					return TYPE_ASSIGNMENT;
				}
			}
			if (words.len >= 1)
			{
				String var_expr = words[^1].trim();
				String resolved_type = "";
				if (actx && sf)
				{
					resolved_type = query::resolve_type_of_chain(actx, sf, var_expr, loc);
				}
				if (resolved_type.len == 0 && sf)
				{
					(void)query::find_local_decl_in_file(sf, var_expr, &resolved_type, actx, loc);
				}
				if (resolved_type.len > 0)
				{
					if (out_expected_type) *out_expected_type = resolved_type;
					return TYPE_ASSIGNMENT;
				}
			}
		}
	}

	return EXECUTION;
}

fn void provide_expected_type_completions(Context* ctx, List{CompletionItem} * items, String type_name)
{
	if (!ctx.ws || type_name.len == 0) return;

	Node* node = query::find_type_node_in_context(ctx.ws.ctx, ctx.sf, type_name);
	if (!node)
	{
		List{SymbolEntry} syms = ctx.ws.find_symbol_by_name(type_name, ctx.sf);
		if (syms.len() > 0 && syms.get(0).node)
		{
			node = syms.get(0).node;
		}
	}

	if (node && node.kind == ENUM_DECL)
	{
		EnumDecl* ed = node.as(EnumDecl);
		foreach (variant : ed.variants)
		{
			if (!variant || variant.kind != VAR_DECL) continue;
			VarDecl* vd = variant.as(VarDecl);
			String vname = vd.name ? vd.name.text : "";
			if (vname.len > 0 && (ctx.prefix.len == 0 || vname.starts_with(ctx.prefix)))
			{
				items.push(
				{
					.label = vname,
					.kind = ENUMMEMBER,
					.detail = string::tformat("enum %s", type_name),
					.insertText = vname,
					.filterText = vname,
					.sortText = string::tformat("0000_%s", vname),
					.data = string::tformat("enum_variant:%s:%s", type_name, vname)
				}
				);
			}
		}
	}
}

fn CompletionItem[]? resolve(LspProject* project, Uri uri, LspPosition pos)
{
	log::debug("completion resolve at line %d, char %d", pos.line, pos.character);

	List{CompletionItem} items;
	items.init(tmem);

	SourceFile* sf = project.workspace.get_source_file_by_path(uri.path);
	if (!sf) return items.array_view();

	sz offset = analysis::compute_byte_offset(sf.content, pos.line, pos.character);

	if (analysis::is_inside_comment(sf.content, offset))
	{
		return items.array_view();
	}

	Location loc = {
		.line = (int)pos.line,
		.column = (int)pos.character
	};
	String expected_type = "";
	ScopeKind scope = detect_completion_scope(sf, offset, &expected_type, project.workspace.ctx, loc);

	String caller_mod = query::get_module_name_at_location(sf, loc);

	Context ctx = {
		.uri = uri,
		.position = pos,
		.ws = &project.workspace,
		.sf = sf,
		.allocator = tmem,
		.scope = scope,
		.offset = offset,
		.expected_type = expected_type,
		.caller_mod = caller_mod,
		.missing_second_colon = false,
	};

	ctx.prefix = analysis::extract_prefix(sf.content, ctx.offset);

	detect_access_context(&ctx, sf);

	if (ctx.scope == IMPORT)
	{
		provide_module_paths(&ctx, &items, sf, offset);
	}
	else if (ctx.access != NONE)
	{
		provide_member_access(&ctx, &items);
	}
	else
	{
		if (expected_type.len > 0)
		{
			provide_expected_type_completions(&ctx, &items, expected_type);
		}
		provide_locals(&ctx, &items);
		provide_global(&ctx, &items);
		provide_module_paths(&ctx, &items, sf, offset);
		provide_keywords(&ctx, &items);
	}

	foreach (&item : items)
	{
		if (item.documentation.kind.len == 0)
		{
			item.documentation.kind = MARKDOWN;
		}
	}

	return items.array_view();
}
