module lsp::analysis::document_symbols;

import analyzer::core;
import analyzer::cursor;

import std::collections::list;
import std::io;

import lsp::core;
import lsp;
import uri;

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

fn SymbolInformation[]? get_document_symbols(LspProject* project, Uri uri)
{
	SourceFile* sf = project.workspace.get_source_file_by_path(uri.path);
	if (!sf) return {};

	List{SymbolInformation} symbols;
	symbols.tinit();

	String file_uri = uri.to_raw_string(tmem);

	foreach (stmt : sf.ast.statements)
	{
		if (!stmt || stmt.kind == ERROR) continue;

		switch (stmt.kind)
		{
			case MODULE_DECL:
				{
					ModuleDecl* md = stmt.as(ModuleDecl);
					String mname = (md.path && md.path.kind == PATH_EXPR && md.path.as(PathExpr).path)
					? md.path.as(PathExpr).path.text
					: "module";
					symbols.push(
					{
						.name = mname,
						.kind = MODULE,
						.location = {.uri = file_uri,.range = to_lsp_range(stmt.range) },
						.containerName = ""
					}
					);
				}
			case FN_DECL:
				{
					FnDecl* fd = stmt.as(FnDecl);
					String fname = fd.name ? fd.name.text : "";
					if (fname.len > 0)
					{
						SymbolKind skind = fd.associated_type ? METHOD : FUNCTION;
						String container = fd.associated_type ? (cursor::raw_type_identifier(fd.associated_type) ?? "") : "";
						symbols.push(
						{
							.name = fname,
							.kind = skind,
							.location = {.uri = file_uri,.range = to_lsp_range(stmt.range) },
							.containerName = container
						}
						);
					}
				}
			case MACRO_DECL:
				{
					MacroDecl* md = stmt.as(MacroDecl);
					String mname = md.name ? md.name.text : "";
					if (mname.len > 0)
					{
						String container = "";
						if (try assoc_node = md.associated_type.get())
						{
							container = cursor::raw_type_identifier(assoc_node) ?? "";
						}
						symbols.push(
						{
							.name = mname,
							.kind = FUNCTION,
							.location = {.uri = file_uri,.range = to_lsp_range(stmt.range) },
							.containerName = container
						}
						);
					}
				}
			case STRUCT_DECL:
				{
					StructDecl* sd = stmt.as(StructDecl);
					String sname = sd.name ? sd.name.text : "";
					if (sname.len > 0)
					{
						symbols.push(
						{
							.name = sname,
							.kind = STRUCT,
							.location = {.uri = file_uri,.range = to_lsp_range(stmt.range) },
							.containerName = ""
						}
						);

						foreach (f : sd.fields)
						{
							if (!f || f.kind != VAR_DECL) continue;
							VarDecl* vd = f.as(VarDecl);
							String fname = vd.name ? vd.name.text : "";
							if (fname.len > 0)
							{
								symbols.push(
								{
									.name = fname,
									.kind = FIELD,
									.location = {.uri = file_uri,.range = to_lsp_range(vd.node.range) },
									.containerName = sname
								}
								);
							}
						}
					}
				}
			case ENUM_DECL:
				{
					EnumDecl* ed = stmt.as(EnumDecl);
					String ename = ed.name ? ed.name.text : "";
					if (ename.len > 0)
					{
						symbols.push(
						{
							.name = ename,
							.kind = ENUM,
							.location = {.uri = file_uri,.range = to_lsp_range(stmt.range) },
							.containerName = ""
						}
						);

						foreach (v : ed.variants)
						{
							if (!v || v.kind != VAR_DECL) continue;
							VarDecl* vd = v.as(VarDecl);
							String vname = vd.name ? vd.name.text : "";
							if (vname.len > 0)
							{
								symbols.push(
								{
									.name = vname,
									.kind = ENUMMEMBER,
									.location = {.uri = file_uri,.range = to_lsp_range(vd.node.range) },
									.containerName = ename
								}
								);
							}
						}
					}
				}
			case TYPEDEF_DECL:
				{
					TypedefDecl* td = stmt.as(TypedefDecl);
					String tname = td.name ? td.name.text : "";
					if (tname.len > 0)
					{
						symbols.push(
						{
							.name = tname,
							.kind = CLASS,
							.location = {.uri = file_uri,.range = to_lsp_range(stmt.range) },
							.containerName = ""
						}
						);
					}
				}
			case ALIAS_DECL:
				{
					AliasDecl* ad = stmt.as(AliasDecl);
					String aname = ad.name ? ad.name.text : "";
					if (aname.len > 0)
					{
						symbols.push(
						{
							.name = aname,
							.kind = CLASS,
							.location = {.uri = file_uri,.range = to_lsp_range(stmt.range) },
							.containerName = ""
						}
						);
					}
				}
			case INTERFACE_DECL:
				{
					InterfaceDecl* id = stmt.as(InterfaceDecl);
					String iname = id.name ? id.name.text : "";
					if (iname.len > 0)
					{
						symbols.push(
						{
							.name = iname,
							.kind = INTERFACE,
							.location = {.uri = file_uri,.range = to_lsp_range(stmt.range) },
							.containerName = ""
						}
						);
					}
				}
			case VAR_DECL:
				{
					VarDecl* vd = stmt.as(VarDecl);
					String vname = vd.name ? vd.name.text : "";
					if (vname.len > 0)
					{
						SymbolKind skind = vd.var_flags.is_const ? CONSTANT : VARIABLE;
						symbols.push(
						{
							.name = vname,
							.kind = skind,
							.location = {.uri = file_uri,.range = to_lsp_range(stmt.range) },
							.containerName = ""
						}
						);
					}
				}

			case FAULTDEF_DECL:
				{
					FaultdefDecl* fd = stmt.as(FaultdefDecl);
					foreach (f : fd.faults)
					{
						if (!f || f.kind != FAULT_DECL) continue;
						FaultDecl* fdecl = f.as(FaultDecl);
						String fname = fdecl.name ? fdecl.name.text : "";
						if (fname.len > 0)
						{
							symbols.push(
							{
								.name = fname,
								.kind = CONSTANT,
								.location = {.uri = file_uri,.range = to_lsp_range(f.range) },
								.containerName = ""
							}
							);
						}
					}
				}
			case ATTRDEF_DECL:
				{
					AttrdefDecl* ad = stmt.as(AttrdefDecl);
					String aname = ad.name ? ad.name.text : "";
					if (aname.len > 0)
					{
						symbols.push(
						{
							.name = aname,
							.kind = PROPERTY,
							.location = {.uri = file_uri,.range = to_lsp_range(stmt.range) },
							.containerName = ""
						}
						);
					}
				}

			default:
				break;
		}
	}

	return symbols.array_view();
}
