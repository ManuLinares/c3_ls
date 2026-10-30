module lsp::analysis::goto_definition;

import analyzer::core;
import analyzer::cursor;
import analyzer::sema::query;

import std::collections::list;
import std::collections::map;
import std::io;

import lsp::core;
import lsp;
import lsp::analysis;
import uri;

fn bool node_to_location(LspProject* project, Uri fallback_uri, Node* node, LspLocation* out_loc)
{
	if (!node || node.range.start.line < 0) return false;

	String target_uri = fallback_uri.to_raw_string(tmem);

	if (project.workspace.ctx)
	{
		project.workspace.ctx.files.@each(; file_path, file_sf)
		{
			if (file_sf && file_path.len > 0 && file_sf.contains_node(node))
			{
				Uri u = uri::from_file_path(tmem, file_path);
				target_uri = u.to_raw_string(tmem);
			}
		};
	}

	if (target_uri == "file:///" || target_uri.len <= 8) return false;

	Range target_range = node.range;
	switch (node.kind)
	{
		case FN_DECL:
			if (node.as(FnDecl).name) target_range = node.as(FnDecl).name.range;
		case MACRO_DECL:
			if (node.as(MacroDecl).name) target_range = node.as(MacroDecl).name.range;
		case VAR_DECL:
			if (node.as(VarDecl).name) target_range = node.as(VarDecl).name.range;
		case STRUCT_DECL:
			if (node.as(StructDecl).name) target_range = node.as(StructDecl).name.range;
		case ENUM_DECL:
			if (node.as(EnumDecl).name) target_range = node.as(EnumDecl).name.range;
		case TYPEDEF_DECL:
			if (node.as(TypedefDecl).name) target_range = node.as(TypedefDecl).name.range;
		case ALIAS_DECL:
			if (node.as(AliasDecl).name) target_range = node.as(AliasDecl).name.range;
		case INTERFACE_DECL:
			if (node.as(InterfaceDecl).name) target_range = node.as(InterfaceDecl).name.range;
		case FAULT_DECL:
			if (node.as(FaultDecl).name) target_range = node.as(FaultDecl).name.range;
		case ATTRDEF_DECL:
			if (node.as(AttrdefDecl).name) target_range = node.as(AttrdefDecl).name.range;
		case TRY_EXPR:
			if (node.as(TryExpr).variable) target_range = node.as(TryExpr).variable.range;
		case CATCH_EXPR:
			if (node.as(CatchExpr).variable) target_range = node.as(CatchExpr).variable.range;
		case MODULE_DECL:
			if (node.as(ModuleDecl).path) target_range = node.as(ModuleDecl).path.range;
		default:
			break;
	}

	*out_loc = {
		.uri = target_uri,
		.range = {
			.start = {
				.line = (uint)target_range.start.line,
				.character = (uint)target_range.start.column
			},
			.end = {
				.line = (uint)target_range.end.line,
				.character = (uint)target_range.end.column
			}
		}
	};
	return true;
}

fn LspLocation[]? goto_definition(LspProject* project, Uri uri, LspPosition pos)
{
	Location loc = {
		.line = (int)pos.line,
		.column = (int)pos.character
	};

	SourceFile* sf = project.workspace.get_source_file_by_path(uri.path);
	if (!sf || !project.workspace.ctx) return {};

	Node* decl_node = query::resolve_symbol_at(project.workspace.ctx, sf, loc);
	if (!decl_node) return {};

	if (decl_node.kind == MODULE_DECL)
	{
		ModuleDecl* md = decl_node.as(ModuleDecl);
		String mod_name = (md.path && md.path.kind == PATH_EXPR && md.path.as(PathExpr).path) ? md.path.as(PathExpr).path.text : "";
		if (Module* mod = project.workspace.ctx.modules.get(mod_name) ?? null)
		{
			List{LspLocation} results;
			results.tinit();
			foreach (mdecl : mod.module_decls)
			{
				LspLocation l;
				if (node_to_location(project, uri, (Node*)mdecl, &l))
				{
					results.push(l);
				}
			}
			if (results.len() > 0) return results.array_view();
		}
	}

	LspLocation single_loc;
	if (node_to_location(project, uri, decl_node, &single_loc))
	{
		LspLocation[] locations = alloc::alloc_array(tmem, LspLocation, 1);
		locations[0] = single_loc;
		return locations;
	}

	return {};
}
