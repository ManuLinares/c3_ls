module lsp::analysis;

import analyzer::core;
import analyzer::cursor;
import lsp::core;
import lsp;

import analyzer::sema;
import std::collections::list;

<*
 Retrieves the canonical identifier text for any AST node with robust fallbacks.
*>
fn String get_node_symbol_name(Node* node)
{
	if (!node) return "";
	String symbol_name = cursor::spelling(node, tmem);
	switch (true)
	{
		case symbol_name.len == 0 && node.kind == IDENT_EXPR:
			{
				IdentExpr* ident_expr = node.as(IdentExpr);
				return ident_expr.ident ? ident_expr.ident.text : "";
			}
		case symbol_name.len == 0 && node.kind == TYPE_EXPR:
			{
				return cursor::raw_type_identifier(node) ?? "";
			}
		case symbol_name.len == 0 && query::label_of(node) != null:
			return query::label_of(node).text;
		default:
			return symbol_name;
	}
}

fn SymbolKind to_symbol_kind(Node* node)
{
	if (!node) return VARIABLE;
	switch (node.kind)
	{
		case MODULE_DECL: return MODULE;
		case FN_DECL:
			{
				FnDecl* fd = node.as(FnDecl);
				return fd.associated_type ? METHOD : FUNCTION;
			}
		case MACRO_DECL: return FUNCTION;
		case STRUCT_DECL: return STRUCT;
		case ENUM_DECL: return ENUM;
		case INTERFACE_DECL: return INTERFACE;
		case TYPEDEF_DECL: return CLASS;
		case ALIAS_DECL: return CLASS;
		case FAULT_DECL: return CONSTANT;
		case FAULTDEF_DECL: return CONSTANT;
		case ATTRDEF_DECL: return PROPERTY;
		case VAR_DECL:
			{
				VarDecl* vd = node.as(VarDecl);
				if (vd.var_flags.is_const) return CONSTANT;
				return vd.var_kind == VAR_FIELD ? FIELD : VARIABLE;
			}
		default:
			return VARIABLE;
	}
}

fn CompletionItemKind to_completion_kind(Node* node)
{
	if (!node) return VALUE;
	switch (node.kind)
	{
		case MODULE_DECL: return MODULE;
		case FN_DECL:
			{
				FnDecl* fd = node.as(FnDecl);
				return fd.associated_type ? METHOD : FUNCTION;
			}
		case MACRO_DECL: return FUNCTION;
		case STRUCT_DECL: return STRUCT;
		case ENUM_DECL: return ENUM;
		case INTERFACE_DECL: return INTERFACE;
		case TYPEDEF_DECL: return CLASS;
		case ALIAS_DECL: return CLASS;
		case FAULT_DECL: return CONSTANT;
		case FAULTDEF_DECL: return CONSTANT;
		case ATTRDEF_DECL: return KEYWORD;
		case VAR_DECL:
			{
				VarDecl* vd = node.as(VarDecl);
				if (vd.var_flags.is_const) return CONSTANT;
				return vd.var_kind == VAR_FIELD ? FIELD : VARIABLE;
			}
		default:
			return VALUE;
	}
}

fn Module* find_module_by_identifier(LspWorkspace* ws, String current_module_name, String identifier)
{
	if (!ws.ctx) return null;

	String scoped_path = "";
	if (current_module_name.len > 0)
	{
		scoped_path = string::tformat("%s::%s", current_module_name, identifier);
	}
	String suffix_path = string::tformat("::%s", identifier);

	ws.ctx.modules.@each(; mod_name, mod)
	{
		if (mod_name == identifier) return mod;
		if (scoped_path.len > 0 && mod_name == scoped_path) return mod;
		if (mod_name.ends_with(suffix_path)) return mod;
	};

	return null;
}

fn LspRange to_lsp_range(Range r)
{
	return {
		.start = {
			.line = r.start.line >= 0 ? (uint)r.start.line : 0,
			.character = r.start.column >= 0 ? (uint)r.start.column : 0
		},
		.end = {
			.line = r.end.line >= 0 ? (uint)r.end.line : (r.start.line >= 0 ? (uint)r.start.line : 0),
			.character = r.end.column >= 0 ? (uint)r.end.column : (r.start.column >= 0 ? (uint)r.start.column : 0)
		}
	};
}

fn void collect_file_symbols(
	SourceFile* sf,
	String file_uri,
	String query_lower,
	sz max_symbols,
	List{SymbolInformation}* out_symbols
)
{
	if (!sf) return;

	foreach (stmt : sf.ast.statements)
	{
		if (max_symbols > 0 && out_symbols.len() >= max_symbols) break;
		if (!stmt || stmt.kind == ERROR) continue;

		if (stmt.kind == FAULTDEF_DECL)
		{
			FaultdefDecl* fd = stmt.as(FaultdefDecl);
			foreach (f : fd.faults)
			{
				if (max_symbols > 0 && out_symbols.len() >= max_symbols) break;
				if (!f || f.kind != FAULT_DECL) continue;
				FaultDecl* fdecl = f.as(FaultDecl);
				String fname = fdecl.name ? fdecl.name.text : "";
				if (fname.len > 0 && (query_lower.len == 0 || fname.to_lower_tcopy().contains(query_lower)))
				{
					out_symbols.push(
					{
						.name = fname,
						.kind = CONSTANT,
						.location = { .uri = file_uri, .range = to_lsp_range(f.range) },
						.containerName = ""
					}
					);
				}
			}
			continue;
		}

		String sname = "";
		String container = "";

		switch (stmt.kind)
		{
			case MODULE_DECL:
				{
					ModuleDecl* md = stmt.as(ModuleDecl);
					sname = (md.path && md.path.kind == PATH_EXPR && md.path.as(PathExpr).path)
						? md.path.as(PathExpr).path.text
						: "module";
				}
			case FN_DECL:
				{
					FnDecl* fd = stmt.as(FnDecl);
					sname = fd.name ? fd.name.text : "";
					if (fd.associated_type)
					{
						container = cursor::raw_type_identifier(fd.associated_type) ?? "";
					}
				}
			case MACRO_DECL:
				{
					MacroDecl* md = stmt.as(MacroDecl);
					sname = md.name ? md.name.text : "";
					if (try assoc_node = md.associated_type.get())
					{
						container = cursor::raw_type_identifier(assoc_node) ?? "";
					}
				}
			default:
				sname = cursor::spelling(stmt, tmem);
				break;
		}

		if (sname.len == 0) continue;

		if (query_lower.len == 0 || sname.to_lower_tcopy().contains(query_lower))
		{
			out_symbols.push(
			{
				.name = sname,
				.kind = to_symbol_kind(stmt),
				.location = { .uri = file_uri, .range = to_lsp_range(stmt.range) },
				.containerName = container
			}
			);
		}

		switch (stmt.kind)
		{
			case STRUCT_DECL:
				{
					StructDecl* sd = stmt.as(StructDecl);
					foreach (f : sd.fields)
					{
						if (max_symbols > 0 && out_symbols.len() >= max_symbols) break;
						if (!f || f.kind != VAR_DECL) continue;
						VarDecl* vd = f.as(VarDecl);
						String fname = vd.name ? vd.name.text : "";
						if (fname.len > 0 && (query_lower.len == 0 || fname.to_lower_tcopy().contains(query_lower)))
						{
							out_symbols.push(
							{
								.name = fname,
								.kind = FIELD,
								.location = { .uri = file_uri, .range = to_lsp_range(vd.node.range) },
								.containerName = sname
							}
							);
						}
					}
				}
			case ENUM_DECL:
				{
					EnumDecl* ed = stmt.as(EnumDecl);
					foreach (v : ed.variants)
					{
						if (max_symbols > 0 && out_symbols.len() >= max_symbols) break;
						if (!v || v.kind != VAR_DECL) continue;
						VarDecl* vd = v.as(VarDecl);
						String vname = vd.name ? vd.name.text : "";
						if (vname.len > 0 && (query_lower.len == 0 || vname.to_lower_tcopy().contains(query_lower)))
						{
							out_symbols.push(
							{
								.name = vname,
								.kind = ENUMMEMBER,
								.location = { .uri = file_uri, .range = to_lsp_range(vd.node.range) },
								.containerName = sname
							}
							);
						}
					}
				}
			default:
				break;
		}
	}
}
<*
 Range in `content` of `text`, a view into it.

 @require text.ptr >= content.ptr && text.ptr + text.len <= content.ptr + content.len
*>
fn Range range_of(String content, String text)
{
	sz start = (sz)(text.ptr - content.ptr);
	return { core::location_at(content, start), core::location_at(content, start + text.len) };
}

<*
 Target of the call `info` describes, resolved through the last character of its callee name.
*>
fn CallTarget call_target_of(AnalyzerContext* context, SourceFile* sf, CallTargetInfo info)
{
	if (!info.is_valid || !info.callee_name.len) return {};
	Location end = range_of(sf.content, info.callee_name).end;
	return query::call_target_at(context, sf, { end.line, end.column - 1 });
}
