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
	TypeNameScope types;
}

<*
 True for declarations visible only inside their enclosing function.
*>
fn bool is_local_decl(Node* node)
{
	if (!node) return false;
	switch (node.kind)
	{
		case VAR_DECL:
			switch (node.as(VarDecl).var_kind)
			{
				case VAR_GLOBAL:
				case VAR_FIELD:
				case VAR_BITFIELD:
					return false;
				default:
					return true;
			}
		case TRY_EXPR:
		case CATCH_EXPR:
		case CONTRACT_PARAM:
			return true;
		default:
			return false;
	}
}

<*
 Name token introduced by a declaration node, or null.
*>
fn Ident* decl_name(Node* node)
{
	if (!node) return null;
	switch (node.kind)
	{
		case VAR_DECL: return node.as(VarDecl).name;
		case FN_DECL: return node.as(FnDecl).name;
		case MACRO_DECL: return node.as(MacroDecl).name;
		case STRUCT_DECL: return node.as(StructDecl).name;
		case ENUM_DECL: return node.as(EnumDecl).name;
		case TYPEDEF_DECL: return node.as(TypedefDecl).name;
		case ALIAS_DECL: return node.as(AliasDecl).name;
		case FAULT_DECL: return node.as(FaultDecl).name;
		case INTERFACE_DECL: return node.as(InterfaceDecl).name;
		case ATTRDEF_DECL: return node.as(AttrdefDecl).name;
		default: return null;
	}
}

<*
 Name token through which a non-declaration node refers to a symbol, or null.
*>
fn Ident* ref_name(Node* node)
{
	if (!node) return null;
	switch (node.kind)
	{
		case IDENT_EXPR:
			return node.as(IdentExpr).ident;
		case TYPE_EXPR:
			TypeExpr* te = node.as(TypeExpr);
			return te.type_kind == TYPE_IDENTIFIER ? te.unresolved.name : null;
		case ATTRIBUTE_DECL:
			return node.as(AttributeDecl).name;
		default:
			return null;
	}
}

<*
 Declaration `ref`, the name token of non-declaration `node`, refers to.
*>
fn Node* resolve_ref(RefCollectorContext* ctx, Node* node, Ident* ref) @local
{
	if (node.kind == TYPE_EXPR && !node.as(TypeExpr).unresolved.path) return ctx.types.resolve(ref);
	return query::resolve_symbol_at(ctx.project.workspace.ctx, ctx.sf, ref.range.start);
}

fn ChildVisitResult collect_references_callback(Node* c, Node* p, void* user_data)
{
	if (!c || c.kind == ERROR) return CONTINUE;
	RefCollectorContext* ctx = (RefCollectorContext*)user_data;

	Ident* name = null;
	if (c == ctx.decl_node)
	{
		if (!ctx.include_declaration) return RECURSE;
		name = decl_name(c) ?: ref_name(c);
	}
	else if (!decl_name(c))
	{
		Ident* ref = ref_name(c);
		if (ref && ref.text == ctx.symbol_name && resolve_ref(ctx, c, ref) == ctx.decl_node) name = ref;
	}
	if (!name || name.text != ctx.symbol_name) return RECURSE;

	LspLocation loc = {
		.uri = ctx.file_uri,
		.range = {
			.start = {
				.line = (uint)name.range.start.line,
				.character = (uint)name.range.start.column
			},
			.end = {
				.line = (uint)name.range.end.line,
				.character = (uint)name.range.end.column
			}
		}
	};

	ctx.locations.push(loc);
	return RECURSE;
}

fn void collect_in_file(LspProject* project, SourceFile* sf, String file_uri, Node* decl_node, String symbol_name, bool include_declaration, List{LspLocation}* results)
{
	RefCollectorContext ref_ctx = {
		.project = project,
		.sf = sf,
		.decl_node = decl_node,
		.symbol_name = symbol_name,
		.file_uri = file_uri,
		.include_declaration = include_declaration,
		.locations = results
	};
	ref_ctx.types.init(project.workspace.ctx, sf);
	foreach (stmt : sf.ast.statements)
	{
		if (!stmt || stmt.kind == ERROR) continue;
		ref_ctx.types.enter(stmt);
		cursor::visit(stmt, null, {.on_enter = &collect_references_callback }, &ref_ctx);
	}
}

<*
 Symbol name of a declaration as spelled at its use sites.
*>
fn String decl_symbol_name(Node* decl_node)
{
	if (Ident* name = decl_name(decl_node) ?: ref_name(decl_node)) return name.text;
	return analysis::get_node_symbol_name(decl_node);
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

	String symbol_name = decl_symbol_name(decl_node);
	if (symbol_name.len == 0) return {};

	List{LspLocation} results;
	results.tinit();

	if (is_local_decl(decl_node))
	{
		collect_in_file(project, sf, uri.to_raw_string(tmem), decl_node, symbol_name, context.includeDeclaration, &results);
		return results.array_view();
	}

	project.workspace.ctx.files.@each(; file_path, target_sf)
	{
		if (target_sf && target_sf.mentions(symbol_name))
		{
			String raw_target_uri = uri::from_file_path(tmem, file_path).to_raw_string(tmem);
			collect_in_file(project, target_sf, raw_target_uri, decl_node, symbol_name, context.includeDeclaration, &results);
		}
	};

	return results.array_view();
}
