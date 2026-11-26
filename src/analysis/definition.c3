module lsp::analysis::definition;

import analyzer::core;
import analyzer::cursor;
import analyzer::sema::query;

import std::collections::list;
import std::collections::map;
import std::io;

import lsp;
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

	Range target_range = cursor::decl_name(node).range ?? node.range;
	switch (node.kind)
	{
		case TRY_EXPR:
			target_range = node.as(TryExpr).variable.range;
		case CATCH_EXPR:
			if (try variable = node.as(CatchExpr).variable.get()) target_range = variable.range;
		case MODULE_DECL:
			if (try path = node.as(ModuleDecl).path.get()) target_range = path.range;
		default:
			if (try label = query::label_of(node)) target_range = label.range;
	}

	*out_loc = {
		.uri = target_uri,
		.range = analysis::to_lsp_range(target_range)
	};
	return true;
}

fn LspLocation[]? goto_definition(LspProject* project, Uri uri, LspPosition pos)
{
	Location loc = {
		.line = (int)pos.line,
		.column = (int)pos.character
	};

	SourceFile* sf = project.workspace.get_source_file_by_path(uri.path)!;
	if (!project.workspace.ctx) return {};

	List{Node*} overloads;
	overloads.tinit();
	List{OverloadCall} operators;
	operators.tinit();
	query::operator_overloads_at(project.workspace.ctx, sf, loc, &operators);
	foreach (call : operators) overloads.push(call.method);
	Node* decl_node = overloads.len() ? overloads[0] : query::resolve_symbol_at(project.workspace.ctx, sf, loc, &overloads)!;
	if (overloads.len() <= 1)
	{
		overloads.clear();
		query::platform_variants(project.workspace.ctx, decl_node, &overloads);
	}

	if (overloads.len() > 1)
	{
		List{LspLocation} results;
		results.tinit();
		foreach (o : overloads)
		{
			LspLocation l;
			if (node_to_location(project, uri, o, &l)) results.push(l);
		}
		return results.array_view();
	}

	if (decl_node.kind == MODULE_DECL)
	{
		ModuleDecl* md = decl_node.as(ModuleDecl);
		String mod_name = md.path.get().as(PathExpr).path.text ?? "";
		if (try mod = project.workspace.ctx.modules.get(mod_name))
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
