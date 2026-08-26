module lsp::analysis::references;

import analyzer::core;
import analyzer::cursor;
import analyzer::sema::query;

import std::collections::list;
import std::io;

import lsp::core;
import lsp;
import lsp::analysis;
import uri;

struct RefCollectorContext
{
	LspProject* project;
	SourceFile* sf;
	Node* decl_node;
	String symbol_name;
	String file_uri;
	bool include_declaration;
	List{LspLocation} * locations;
}

fn ChildVisitResult collect_references_callback(Node* c, Node* p, void* user_data)
{
	if (!c || c.kind == ERROR) return CONTINUE;
	RefCollectorContext* ctx = (RefCollectorContext*)user_data;

	bool matched = false;
	Range node_range = c.range;

	switch (c.kind)
	{
		case IDENT_EXPR:
			{
				IdentExpr* ie = c.as(IdentExpr);
				if (ie.ident && ie.ident.text == ctx.symbol_name)
				{
					Node* resolved = null;
					if (ie.path_expr && ie.path_expr.kind == PATH_EXPR)
					{
						String mod_name = ie.path_expr.as(PathExpr).path ? ie.path_expr.as(PathExpr).path.text.strip_suffix("::") : "";
						Module* mod = analysis::find_module_by_identifier(&ctx.project.workspace, "", mod_name);
						if (mod)
						{
							String qname = string::tformat("%s::%s", mod.name, ctx.symbol_name);
							if (ctx.project.workspace.ctx && ctx.project.workspace.ctx.registry)
							{
								if (try fn_info = ctx.project.workspace.ctx.registry.functions.get(qname))
								{
									resolved = fn_info.node;
								}
								else if (try mac_info = ctx.project.workspace.ctx.registry.macros.get(qname))
								{
									resolved = mac_info.node;
								}
								else if (try ty_info = ctx.project.workspace.ctx.registry.types.get(qname))
								{
									resolved = ty_info.node;
								}
							}
							if (!resolved)
							{
								foreach (node : mod.nodes)
								{
									if (!node || node.kind == ERROR) continue;
									String sname = cursor::spelling(node, tmem);
									if (sname == ctx.symbol_name)
									{
										resolved = node;
										break;
									}
								}
							}
						}
					}
					else if (ctx.project.workspace.ctx)
					{
						resolved = query::resolve_symbol_at(ctx.project.workspace.ctx, ctx.sf, ie.ident.range.start);
					}

					if (resolved == ctx.decl_node)
					{
						matched = true;
						node_range = ie.ident.range;
					}
					else if (resolved != null && ctx.decl_node != null && resolved.kind == ctx.decl_node.kind)
					{
						String rname = cursor::spelling(resolved, tmem);
						if (rname.len > 0 && rname == ctx.symbol_name)
						{
							matched = true;
							node_range = ie.ident.range;
						}
					}
				}
			}
		case TYPE_EXPR:
			{
				TypeExpr* te = c.as(TypeExpr);
				if (te.type_kind == TYPE_IDENTIFIER && te.unresolved.name && te.unresolved.name.text == ctx.symbol_name)
				{
					matched = true;
					node_range = te.unresolved.name.range;
				}
			}
		case VAR_DECL:
			{
				VarDecl* vd = c.as(VarDecl);
				if (ctx.include_declaration && c == ctx.decl_node && vd.name && vd.name.text == ctx.symbol_name)
				{
					matched = true;
					node_range = vd.name.range;
				}
			}
		case FN_DECL:
			{
				FnDecl* fd = c.as(FnDecl);
				if (ctx.include_declaration && c == ctx.decl_node && fd.name && fd.name.text == ctx.symbol_name)
				{
					matched = true;
					node_range = fd.name.range;
				}
			}
		case MACRO_DECL:
			{
				MacroDecl* md = c.as(MacroDecl);
				if (ctx.include_declaration && c == ctx.decl_node && md.name && md.name.text == ctx.symbol_name)
				{
					matched = true;
					node_range = md.name.range;
				}
			}
		case STRUCT_DECL:
			{
				StructDecl* sd = c.as(StructDecl);
				if (ctx.include_declaration && c == ctx.decl_node && sd.name && sd.name.text == ctx.symbol_name)
				{
					matched = true;
					node_range = sd.name.range;
				}
			}
		case ENUM_DECL:
			{
				EnumDecl* ed = c.as(EnumDecl);
				if (ctx.include_declaration && c == ctx.decl_node && ed.name && ed.name.text == ctx.symbol_name)
				{
					matched = true;
					node_range = ed.name.range;
				}
			}
		case TYPEDEF_DECL:
			{
				TypedefDecl* td = c.as(TypedefDecl);
				if (ctx.include_declaration && c == ctx.decl_node && td.name && td.name.text == ctx.symbol_name)
				{
					matched = true;
					node_range = td.name.range;
				}
			}
		case ALIAS_DECL:
			{
				AliasDecl* ad = c.as(AliasDecl);
				if (ctx.include_declaration && c == ctx.decl_node && ad.name && ad.name.text == ctx.symbol_name)
				{
					matched = true;
					node_range = ad.name.range;
				}
			}
		default:
			break;
	}

	if (matched)
	{
		LspLocation loc = {
			.uri = ctx.file_uri,
			.range = {
				.start = {
					.line = (uint)node_range.start.line,
					.character = (uint)node_range.start.column
				},
				.end = {
					.line = (uint)node_range.end.line,
					.character = (uint)node_range.end.column
				}
			}
		};

		bool exists = false;
		foreach (existing : *ctx.locations)
		{
			if (existing.uri == loc.uri &&
			existing.range.start.line == loc.range.start.line &&
			existing.range.start.character == loc.range.start.character)
			{
				exists = true;
				break;
			}
		}
		if (!exists)
		{
			ctx.locations.push(loc);
		}
	}

	return RECURSE;
}

fn LspLocation[]? find_references(LspProject* project, Uri uri, LspPosition pos, ReferenceContext context)
{
	Location loc = {
		.line = (int)pos.line,
		.column = (int)pos.character
	};

	SourceFile* sf = project.workspace.get_source_file_by_path(uri.path);
	if (!sf || !project.workspace.ctx) return {};

	Node* decl_node = query::resolve_symbol_at(project.workspace.ctx, sf, loc);
	if (!decl_node) return {};

	String symbol_name = analysis::get_node_symbol_name(decl_node);
	if (symbol_name.len == 0) return {};

	List{LspLocation} results;
	results.tinit();

	if (project.workspace.ctx)
	{
		project.workspace.ctx.files.@each(; file_path, target_sf)
		{
			if (target_sf)
			{
				Uri target_u = uri::from_file_path(tmem, file_path);
				String raw_target_uri = target_u.to_raw_string(tmem);

				RefCollectorContext ref_ctx = {
					.project = project,
					.sf = target_sf,
					.decl_node = decl_node,
					.symbol_name = symbol_name,
					.file_uri = raw_target_uri,
					.include_declaration = context.includeDeclaration,
					.locations = &results
				};

				foreach (stmt : target_sf.ast.statements)
				{
					if (!stmt || stmt.kind == ERROR) continue;
					cursor::visit(stmt, null, {.on_enter = &collect_references_callback }, &ref_ctx);
				}
			}
		};
	}

	return results.array_view();
}
