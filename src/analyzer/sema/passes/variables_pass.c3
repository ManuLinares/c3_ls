// src/analyzer/sema/passes/variables_pass.c3
module analyzer::sema;

import analyzer::core;
import analyzer::cursor;

import std::collections::list;
import std::collections::map;
import std::io::path;

fn void run_variable_pass(SemaContext* ctx) => @pool()
{
	SourceFile* sf = ctx.context.current_source_file;
	String[] lines = sf.content.tsplit("\n");

	Range range = {
		.start = {},
		.end = {
			.line = lines.len > 0 ? lines.len - 1 : 0,
			.column = lines.len > 0 ? (lines[^1].len > 0 ? lines[^1].len - 1 : 0) : 0
		},
	};

	String current_mod_name = "";
	Path? p = path::tnew(sf.path);
	if (try p_val = p)
	{
		current_mod_name = p_val.basename();
	}
	if (current_mod_name.len == 0) current_mod_name = "default";

	HashMap{String, Scope*} module_scopes;
	module_scopes.tinit();

	String current_scope_key = current_mod_name;
	Scope* initial_mod_scope = scope::create(ctx.allocator, range);
	module_scopes.set(current_scope_key, initial_mod_scope);
	Scope* current_section_scope = scope::create(ctx.allocator, range, initial_mod_scope);
	ctx.scope = current_section_scope;

	foreach (root_node : sf.ast.statements)
	{
		if (!root_node) continue;

		if (root_node.kind == MODULE_DECL)
		{
			ModuleDecl* mod_decl = root_node.as(ModuleDecl);
			if (mod_decl.path && mod_decl.path.kind == PATH_EXPR)
			{
				PathExpr* pe = mod_decl.path.as(PathExpr);
				if (pe.path && pe.path.text.len > 0)
				{
					current_mod_name = pe.path.text;

					String feat_suffix = "";
					foreach (attr : mod_decl.attributes)
					{
						if (attr && attr.kind == ATTRIBUTE_DECL)
						{
							AttributeDecl* ad = attr.as(AttributeDecl);
							if (ad.attribute_kind == AttributeKind.FEAT || ad.attribute_kind == AttributeKind.IF)
							{
								feat_suffix = string::tformat("%s@%s", feat_suffix, ad.name ? ad.name.text : "feat");
								foreach (e : ad.exprs)
								{
									feat_suffix = string::tformat("%s(%s)", feat_suffix, cursor::spelling(e, tmem));
								}
							}
						}
					}

					String gen_suffix = "";
					if (mod_decl.generics && mod_decl.generics.kind == GENERIC_DECL)
					{
						GenericDecl* gd = mod_decl.generics.as(GenericDecl);
						gen_suffix = "<";
						foreach (i, p_node : gd.params)
						{
							if (i > 0) gen_suffix = string::tformat("%s,", gen_suffix);
							String pname = cursor::spelling(p_node, tmem);
							if (pname.len == 0) pname = cursor::raw_type_identifier(p_node) ?? "";
							gen_suffix = string::tformat("%s%s", gen_suffix, pname);
						}
						gen_suffix = string::tformat("%s>", gen_suffix);
					}

					String full_suffix = string::tformat("%s%s", feat_suffix, gen_suffix);
					current_scope_key = full_suffix.len > 0 ? string::tformat("%s#%s", current_mod_name, full_suffix) : current_mod_name;

					Scope** existing = module_scopes.get_ref(current_scope_key) ?? null;
					Scope* mod_scope = null;
					if (!existing)
					{
						mod_scope = scope::create(ctx.allocator, range);
						module_scopes.set(current_scope_key, mod_scope);
					}
					else
					{
						mod_scope = *existing;
					}
					current_section_scope = scope::create(ctx.allocator, range, mod_scope);
					ctx.scope = current_section_scope;
				}
			}
			continue;
		}

		ctx.scope = current_section_scope;

		switch (root_node.kind)
		{
			case VAR_DECL:
			case FN_DECL:
			case MACRO_DECL:
				break;
			default:
				continue;
		}

		cursor::visit(root_node, null, { &sema_on_enter, &sema_on_exit }, ctx);
	}
}

fn void push_scope(SemaContext* ctx, Node* node)
{
	diagnostics::log_debug("[VariablePass]: Pushed new scope for %s at %s", node.kind.description, node.range);

	Scope* new_scope = scope::create(ctx.allocator, node.range, ctx.scope);

	ctx.scope.children.push(new_scope);
	ctx.scope = new_scope;
}

fn void pop_scope(SemaContext* ctx)
{
	if (ctx.scope.parent)
	{
		ctx.scope = ctx.scope.parent;
	}
}

fn bool has_conditional_feat_or_if(Node* node) @local
{
	if (!node) return false;
	NodeArray attrs;
	switch (node.kind)
	{
		case VAR_DECL: attrs = node.as(VarDecl).attributes;
		case FN_DECL: attrs = node.as(FnDecl).attributes;
		case MACRO_DECL: attrs = node.as(MacroDecl).attributes;
		case STRUCT_DECL: attrs = node.as(StructDecl).attributes;
		default: return false;
	}

	foreach (attr : attrs)
	{
		if (!attr || attr.kind != ATTRIBUTE_DECL) continue;
		AttributeDecl* ad = attr.as(AttributeDecl);
		if (ad.attribute_kind == AttributeKind.FEAT || ad.attribute_kind == AttributeKind.IF)
		{
			return true;
		}
	}
	return false;
}

fn ChildVisitResult sema_on_enter(Node* node, Node* parent, void* user_data) @local
{
	SemaContext* ctx = (SemaContext*)user_data;

	switch (node.kind)
	{
		case IF_STMT:
		{
			IfStmt* if_stmt = node.as(IfStmt);
			if (if_stmt.then_body && if_stmt.then_body.kind != COMPOUND_STMT)
			{
				push_scope(ctx, if_stmt.then_body);
				cursor::visit(if_stmt.then_body, node, { &sema_on_enter, &sema_on_exit }, ctx);
				pop_scope(ctx);
			}
			else if (if_stmt.then_body)
			{
				cursor::visit(if_stmt.then_body, node, { &sema_on_enter, &sema_on_exit }, ctx);
			}

			if (if_stmt.else_body)
			{
				if (if_stmt.else_body.kind != COMPOUND_STMT)
				{
					push_scope(ctx, if_stmt.else_body);
					cursor::visit(if_stmt.else_body, node, { &sema_on_enter, &sema_on_exit }, ctx);
					pop_scope(ctx);
				}
				else
				{
					cursor::visit(if_stmt.else_body, node, { &sema_on_enter, &sema_on_exit }, ctx);
				}
			}

			return CONTINUE;
		}
		case CT_IF_STMT:
		{
			CtIfStmt* if_stmt = node.as(CtIfStmt);
			push_scope(ctx, node);
			foreach (child : if_stmt.then_stmts)
			{
				cursor::visit(child, node, { &sema_on_enter, &sema_on_exit }, ctx);
			}
			pop_scope(ctx);
			if (if_stmt.else_stmts.len > 0)
			{
				push_scope(ctx, node);
				foreach (child : if_stmt.else_stmts)
				{
					cursor::visit(child, node, { &sema_on_enter, &sema_on_exit }, ctx);
				}
				pop_scope(ctx);
			}
			return CONTINUE;
		}
		case MACRO_DECL:
		case FN_DECL:
		case LAMBDA_EXPR:
		case MACRO_BODY_EXPR:
		case BODY_PARAM_DECL:
		case FOR_STMT:
		case CT_FOR_STMT:
		case FOREACH_STMT:
		case CT_FOREACH_STMT:
		case WHILE_STMT:
		case DO_WHILE_STMT:
		case COMPOUND_STMT:
			push_scope(ctx, node);
			break;
		default:
			break;
	}

	if VAR: (node.kind == VAR_DECL)
	{
		VarDecl* decl = node.as(VarDecl);

		if (!decl.name) break VAR;

		Scope* target_scope = ctx.scope;
		bool is_section_local = (node.visibility == Visibility.LOCAL);
		if (!is_section_local)
		{
			foreach (attr : decl.attributes)
			{
				if (attr && attr.kind == ATTRIBUTE_DECL && attr.as(AttributeDecl).attribute_kind == AttributeKind.LOCAL)
				{
					is_section_local = true;
					break;
				}
			}
		}

		if (ctx.scope.parent != null && ctx.scope.parent.parent == null && !is_section_local)
		{
			target_scope = ctx.scope.parent;
		}

		VariableInfo* info = target_scope.variables.get(decl.name.text) ?? null;
		if (info)
		{
			if (!has_conditional_feat_or_if(node) && !has_conditional_feat_or_if(info.node))
			{
			diagnostics::note(ctx.context, info.node.range, "Previous definition of '%s' was here", info.name);
			diagnostics::error(ctx.context, decl.range, "Variable '%s' is being redefined in the same scope", decl.name.text);
			}
			break VAR;
		}

		diagnostics::log_debug("[VariablePass]: Added local variable: %s", decl.name.text);

		scope::add_variable(target_scope, ctx.allocator, decl.name.text, node);
	}

	return RECURSE;
}

fn ChildVisitResult sema_on_exit(Node* node, Node* parent, void* user_data) @local
{
	SemaContext* ctx = (SemaContext*)user_data;
	switch (node.kind)
	{
		case MACRO_DECL:
		case FN_DECL:
		case LAMBDA_EXPR:
		case MACRO_BODY_EXPR:
		case BODY_PARAM_DECL:
		case FOR_STMT:
		case CT_FOR_STMT:
		case FOREACH_STMT:
		case CT_FOREACH_STMT:
		case WHILE_STMT:
		case DO_WHILE_STMT:
		case COMPOUND_STMT:
			pop_scope(ctx);
		default:
			break;
	}

	return CONTINUE;
}