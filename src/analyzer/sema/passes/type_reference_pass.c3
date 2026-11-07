module analyzer::sema;

import analyzer::core;
import analyzer::cursor;
import analyzer::core::constants;
import analyzer::sema::query;
import std::collections::map;

struct TypeReferenceCheck
{
	AnalyzerContext* context;
	SourceFile* sf;
	// Per module section: name -> declaration to report, or null when the
	// name needs no report.
	HashMap{String, Node*} verdicts;
	GenericDecl* section_generics;
	GenericDecl* decl_generics;
}

<*
 Report type names that resolve to a declaration only reachable through an
 import the file lacks.
*>
fn void run_type_reference_pass(SemaContext* ctx) => @pool()
{
	SourceFile* sf = ctx.context.current_source_file;
	if (!sf) return;

	TypeReferenceCheck check = { .context = ctx.context, .sf = sf };
	check.verdicts.tinit();
	foreach (stmt : sf.ast.statements)
	{
		if (!stmt || stmt.kind == ERROR) continue;
		if (stmt.kind == MODULE_DECL)
		{
			check.verdicts.clear();
			check.section_generics = query::generics_of(stmt);
		}
		check.decl_generics = query::generics_of(stmt);
		cursor::visit(stmt, null, { .on_enter = &check_type_reference }, &check);
	}
}

fn bool declares_param(GenericDecl* gd, String name) @local
{
	if (!gd) return false;
	foreach (param : gd.params)
	{
		if (param && param.kind != ERROR && query::generic_param_name(param) == name) return true;
	}
	return false;
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
	if (declares_param(check.decl_generics, name.text) || declares_param(check.section_generics, name.text)) return RECURSE;

	Node* decl;
	if (try cached = check.verdicts.get(name.text))
	{
		decl = cached;
	}
	else
	{
		decl = query::find_type_node_in_context(check.context, check.sf, name.text, name.range.start)
			? null
			: query::find_type_node_in_context(check.context, null, name.text);
		check.verdicts.set(name.text, decl);
	}
	if (!decl) return RECURSE;

	String mod = module_of(check.context, decl);
	if (mod.len == 0) return RECURSE;
	diagnostics::error(check.context, name.range, "Did you mean the %s '%s' in module %s? If so please add 'import %s'.",
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
