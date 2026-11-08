module analyzer::sema;

import analyzer::core;
import analyzer::cursor;
import analyzer::core::constants;
import analyzer::sema::query;
import std::collections::map;

struct TypeReferenceCheck
{
	TypeNameScope scope;
	HashMap{String, Node*} anywhere; // name -> declaration in any module, or null
}

<*
 Report type names that resolve to a declaration only reachable through an
 import the file lacks.
*>
fn void run_type_reference_pass(SemaContext* ctx) => @pool()
{
	SourceFile* sf = ctx.context.current_source_file;
	if (!sf) return;

	TypeReferenceCheck check;
	check.scope.init(ctx.context, sf);
	check.anywhere.tinit();
	foreach (stmt : sf.ast.statements)
	{
		if (!stmt || stmt.kind == ERROR) continue;
		check.scope.enter(stmt);
		cursor::visit(stmt, null, { .on_enter = &check_type_reference }, &check);
	}
}

fn ChildVisitResult check_type_reference(Node* node, Node* parent, void* user_data) @local
{
	if (!node || node.kind == ERROR) return CONTINUE;
	if (node.kind != TYPE_EXPR) return RECURSE;

	TypeExpr* te = node.as(TypeExpr);
	if (te.type_kind != TYPE_IDENTIFIER || !te.unresolved.name || te.unresolved.path) return RECURSE;

	Ident* name = te.unresolved.name;
	if (constants::is_primitive(name.text)) return RECURSE;

	TypeReferenceCheck* check = (TypeReferenceCheck*)user_data;
	if (check.scope.resolve(name)) return RECURSE;

	Node* decl;
	if (try cached = check.anywhere.get(name.text))
	{
		decl = cached;
	}
	else
	{
		decl = query::find_type_node_in_context(check.scope.context, null, name.text);
		check.anywhere.set(name.text, decl);
	}
	if (!decl) return RECURSE;

	String mod = module_of(check.scope.context, decl);
	if (mod.len == 0) return RECURSE;
	diagnostics::error(check.scope.context, name.range, "Did you mean the %s '%s' in module %s? If so please add 'import %s'.",
		type_decl_word(decl), name.text, mod, mod);
	return RECURSE;
}

fn String module_of(AnalyzerContext* context, Node* decl) @local
{
	String found = "";
	context.modules.@each(; mod_name, mod)
	{
		if (!found.len && mod)
		{
			foreach (n : mod.nodes)
			{
				if (n == decl)
				{
					found = mod_name;
					break;
				}
			}
		}
	};
	return found;
}

fn String type_decl_word(Node* decl) @local
{
	switch (decl.kind)
	{
		case STRUCT_DECL:
			StructDecl* sd = decl.as(StructDecl);
			return sd.is_union ? "union" : sd.is_bitstruct ? "bitstruct" : "struct";
		case ENUM_DECL: return "enum";
		case TYPEDEF_DECL: return "typedef";
		case ALIAS_DECL: return "alias";
		case INTERFACE_DECL: return "interface";
		default: return "type";
	}
}
