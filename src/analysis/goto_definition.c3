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

fn LspLocation[]? goto_definition(LspProject* project, Uri uri, LspPosition pos)
{
	Location loc = {
		.line = (int)pos.line,
		.column = (int)pos.character
	};

	SourceFile* sf = project.workspace.get_source_file_by_path(uri.path);
	if (!sf || !project.workspace.ctx) return {};

	Node* decl_node = query::resolve_symbol_at(project.workspace.ctx, sf, loc);
	if (!decl_node || decl_node.range.start.line < 0) return {};

	String target_uri = uri.to_raw_string(tmem);

	if (project.workspace.ctx)
	{
		project.workspace.ctx.files.@each(; file_path, file_sf)
		{
			if (file_sf && file_path.len > 0 && file_sf.contains_node(decl_node))
			{
				Uri u = uri::from_file_path(tmem, file_path);
				target_uri = u.to_raw_string(tmem);
			}
		};
	}

	if (target_uri == "file:///" || target_uri.len <= 8) return {};

	Range target_range = decl_node.range;
	if (decl_node.kind == FN_DECL && decl_node.as(FnDecl).name)
	{
		target_range = decl_node.as(FnDecl).name.range;
	}
	else if (decl_node.kind == MACRO_DECL && decl_node.as(MacroDecl).name)
	{
		target_range = decl_node.as(MacroDecl).name.range;
	}
	else if (decl_node.kind == VAR_DECL && decl_node.as(VarDecl).name)
	{
		target_range = decl_node.as(VarDecl).name.range;
	}
	else if (decl_node.kind == STRUCT_DECL && decl_node.as(StructDecl).name)
	{
		target_range = decl_node.as(StructDecl).name.range;
	}
	else if (decl_node.kind == ENUM_DECL && decl_node.as(EnumDecl).name)
	{
		target_range = decl_node.as(EnumDecl).name.range;
	}
	else if (decl_node.kind == TYPEDEF_DECL && decl_node.as(TypedefDecl).name)
	{
		target_range = decl_node.as(TypedefDecl).name.range;
	}
	else if (decl_node.kind == ALIAS_DECL && decl_node.as(AliasDecl).name)
	{
		target_range = decl_node.as(AliasDecl).name.range;
	}
	else if (decl_node.kind == INTERFACE_DECL && decl_node.as(InterfaceDecl).name)
	{
		target_range = decl_node.as(InterfaceDecl).name.range;
	}
	else if (decl_node.kind == FAULT_DECL && decl_node.as(FaultDecl).name)
	{
		target_range = decl_node.as(FaultDecl).name.range;
	}

	LspLocation[] locations = alloc::alloc_array(tmem, LspLocation, 1);
	locations[0] = {
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

	return locations;
}
