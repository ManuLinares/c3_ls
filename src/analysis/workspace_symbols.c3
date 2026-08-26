module lsp::analysis::workspace_symbols;

import analyzer::core;
import analyzer::cursor;

import std::collections::list;
import std::io;

import lsp::core;
import lsp;
import lsp::analysis::document_symbols;
import uri;

const sz MAX_WORKSPACE_SYMBOLS = 512;

fn SymbolKind symbol_kind_from_node(Node* node)
{
	if (!node) return VARIABLE;
	switch (node.kind)
	{
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

fn SymbolInformation[]? query_workspace_symbols(LspProject* project, String query)
{
	List{SymbolInformation} results;
	results.tinit();

	if (!project.workspace.ctx) return results.array_view();

	String q_lower = query.to_lower_tcopy();

	project.workspace.ctx.files.@each(; file_path, sf)
	{
		if (results.len() >= MAX_WORKSPACE_SYMBOLS) return results.array_view();

		if (sf && sf.ast.statements.len() > 0)
		{
			Uri u = uri::from_file_path(tmem, file_path);
			String file_uri = u.to_raw_string(tmem);

			foreach (stmt : sf.ast.statements)
			{
				if (results.len() >= MAX_WORKSPACE_SYMBOLS) break;
				if (!stmt || stmt.kind == ERROR) continue;

				String sname = cursor::spelling(stmt, tmem);
				if (sname.len == 0) continue;

				if (q_lower.len == 0 || sname.to_lower_tcopy().contains(q_lower))
				{
					results.push(
					{
						.name = sname,
						.kind = symbol_kind_from_node(stmt),
						.location = {
							.uri = file_uri,
							.range = document_symbols::to_lsp_range(stmt.range)
						},
						.containerName = ""
					}
					);
				}

				if (stmt.kind == STRUCT_DECL)
				{
					StructDecl* sd = stmt.as(StructDecl);
					foreach (field : sd.fields)
					{
						if (results.len() >= MAX_WORKSPACE_SYMBOLS) break;
						if (!field || field.kind != VAR_DECL) continue;
						VarDecl* vd = field.as(VarDecl);
						String fname = vd.name ? vd.name.text : "";
						if (fname.len > 0 && (q_lower.len == 0 || fname.to_lower_tcopy().contains(q_lower)))
						{
							results.push(
							{
								.name = fname,
								.kind = FIELD,
								.location = {
									.uri = file_uri,
									.range = document_symbols::to_lsp_range(vd.node.range)
								},
								.containerName = sname
							}
							);
						}
					}
				}
				else if (stmt.kind == ENUM_DECL)
				{
					EnumDecl* ed = stmt.as(EnumDecl);
					foreach (variant : ed.variants)
					{
						if (results.len() >= MAX_WORKSPACE_SYMBOLS) break;
						if (!variant || variant.kind != VAR_DECL) continue;
						VarDecl* vd = variant.as(VarDecl);
						String vname = vd.name ? vd.name.text : "";
						if (vname.len > 0 && (q_lower.len == 0 || vname.to_lower_tcopy().contains(q_lower)))
						{
							results.push(
							{
								.name = vname,
								.kind = ENUMMEMBER,
								.location = {
									.uri = file_uri,
									.range = document_symbols::to_lsp_range(vd.node.range)
								},
								.containerName = sname
							}
							);
						}
					}
				}
				else if (stmt.kind == FAULTDEF_DECL)
				{
					FaultdefDecl* fd = stmt.as(FaultdefDecl);
					foreach (f : fd.faults)
					{
						if (results.len() >= MAX_WORKSPACE_SYMBOLS) break;
						if (!f || f.kind != FAULT_DECL) continue;
						FaultDecl* fdecl = f.as(FaultDecl);
						String fname = fdecl.name ? fdecl.name.text : "";
						if (fname.len > 0 && (q_lower.len == 0 || fname.to_lower_tcopy().contains(q_lower)))
						{
							results.push(
							{
								.name = fname,
								.kind = CONSTANT,
								.location = {
									.uri = file_uri,
									.range = document_symbols::to_lsp_range(f.range)
								},
								.containerName = ""
							}
							);
						}
					}
				}
			}
		}
	};

	return results.array_view();
}
