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
			return @ok(query::label_of(node));
	}
}

<*
 Name token introduced by a declaration or labelled statement `node`.
*>
fn Ident*? declared_name(Node* node)
{
	if (!node) return NOT_FOUND~;
	return cursor::decl_name(node) ?? query::label_of(node);
}

<*
 Name token through which a non-declaration node refers to a symbol, or null.
*>
fn Ident*? ref_name(Node* node)
{
	if (!node) return NOT_FOUND~;
	switch (node.kind)
	{
		case IDENT_EXPR:
			return node.as(IdentExpr).ident ?: NOT_FOUND~;
		case TYPE_EXPR:
			TypeExpr* te = node.as(TypeExpr);
			return te.type_kind == TYPE_IDENTIFIER ? te.unresolved.name.get() : NOT_FOUND~;
		case ATTRIBUTE_DECL:
			return node.as(AttributeDecl).name.get();
		case CONTRACT_PARAM:
			return node.as(ContractParam).ident.get();
		default:
			return query::jump_label(node);
	}
}

<*
 Declaration `ref`, the name token of non-declaration `node`, refers to.
*>
fn Node*? resolve_ref(RefCollectorContext* ctx, Node* node, Ident* ref) @local
{
	if (node.kind == TYPE_EXPR && !@ok(node.as(TypeExpr).unresolved.path.get())) return ctx.types.resolve(ref);
	return query::resolve_symbol_at(ctx.project.workspace.ctx, ctx.sf, ref.range.start);
}

fn ChildVisitResult collect_references_callback(Node* c, Node* p, void* user_data)
{
	if (!c || c.kind == ERROR) return CONTINUE;
	RefCollectorContext* ctx = (RefCollectorContext*)user_data;

	Ident*? name = NOT_FOUND~;
	if (c == ctx.decl_node)
	{
		if (!ctx.include_declaration) return RECURSE;
		name = declared_name(c) ?? ref_name(c);
	}
	else if (!@ok(declared_name(c)))
	{
		if (try ref = ref_name(c) && ref.text == ctx.symbol_name)
		{
			if (try decl = resolve_ref(ctx, c, ref) && decl == ctx.decl_node) name = ref;
		}
	}
	if (catch name) return RECURSE;
	if (name.text != ctx.symbol_name) return RECURSE;

	LspLocation loc = {
		.uri = ctx.file_uri,
		.range = analysis::to_lsp_range(name.range)
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
	if (try name = declared_name(decl_node) ?? ref_name(decl_node)) return name.text;
	return analysis::get_node_symbol_name(decl_node);
}

fn LspLocation[]? find_references(LspProject* project, Uri uri, LspPosition pos, ReferenceContext context)
{
	Location loc = {
		.line = (int)pos.line,
		.column = (int)pos.character
	};

	SourceFile* sf = project.workspace.get_source_file_by_path(uri.path)!;
	if (!project.workspace.ctx) return {};

	Node* decl_node = query::resolve_symbol_at(project.workspace.ctx, sf, loc)!;

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
