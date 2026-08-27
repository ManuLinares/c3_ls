module analyzer::cursor;

import analyzer::core;
import analyzer::core::ast;

enum ChildVisitResult : int
{
	BREAK,
	CONTINUE,
	RECURSE
}

struct VisitorHooks
{
	CursorVisitor on_enter;
	CursorVisitor on_exit;
}

alias CursorVisitor = fn ChildVisitResult (Node* cursor, Node* parent, void* user_data);
<*
 @require hooks.on_enter != null
*>
fn bool visit(Node* child, Node* parent, VisitorHooks hooks, void* data)
{
	ChildVisitResult res = hooks.on_enter(child, parent, data);
	if (res == ChildVisitResult.BREAK) return false;

	if (res == ChildVisitResult.RECURSE)
	{
		if (!visit_children(child, hooks, data)) return false;
	}

	if (hooks.on_exit)
	{
		hooks.on_exit(child, parent, data);
	}

	return true;
}

<*
 Visit children
 returns false if a break was requested
 @param parent : "The Cursor to visit children on"
 @param hooks : "callback functions that will be invoked for all children of 'parent'"
 @param data : "user data to be passed around"
*>
fn bool visit_children(Node* parent, VisitorHooks hooks, void* data)
{
	if (!parent || parent.kind == ERROR) return true;
	Node* node = parent;

	switch
	{
		case node.kind.is_decl():
			if (!visit_decls(node, parent, hooks, data)) return false;
			break;
		case node.kind.is_stmt():
			if (!visit_stmts(node, parent, hooks, data)) return false;
			break;
		case node.kind.is_expr():
			if (!visit_exprs(node, parent, hooks, data)) return false;
			break;
		default:
			break;
	}

	return true;
}

fn bool visit_decls(Node* node, Node* parent, VisitorHooks hooks, void* data) @private
{
	switch (node.kind)
	{
		case MODULE_DECL:
			{
				ModuleDecl* md = node.as(ModuleDecl);
				if (md.path && !visit(md.path, parent, hooks, data)) return false;
				foreach (attr : md.attributes)
				{
					if (!visit(attr, parent, hooks, data)) return false;
				}
				if (md.generics && !visit(md.generics, parent, hooks, data)) return false;
				if (try contract = md.contract.get())
				{
					if (!visit(contract, parent, hooks, data)) return false;
				}
				break;
			}
		case IMPORT_DECL:
			{
				ImportDecl* id = node.as(ImportDecl);
				foreach (attr : id.attributes)
				{
					if (!visit(attr, parent, hooks, data)) return false;
				}
				foreach (path : id.paths)
				{
					if (!visit(path, parent, hooks, data)) return false;
				}
				break;
			}
		case FN_DECL:
			{
				FnDecl* fndecl = node.as(FnDecl);
				if (fndecl.associated_type && !visit(fndecl.associated_type, parent, hooks, data)) return false;
				if (fndecl.ret_type && !visit(fndecl.ret_type, parent, hooks, data)) return false;
				if (fndecl.generics && !visit(fndecl.generics, parent, hooks, data)) return false;
				foreach (param : fndecl.params)
				{
					if (!visit(param, parent, hooks, data)) return false;
				}
				foreach (attr : fndecl.attributes)
				{
					if (!visit(attr, parent, hooks, data)) return false;
				}
				if (try contract = fndecl.contract.get())
				{
					if (!visit(contract, parent, hooks, data)) return false;
				}
				if (fndecl.body && !visit(fndecl.body, parent, hooks, data)) return false;
				break;
			}
		case MACRO_DECL:
			{
				MacroDecl* mac = node.as(MacroDecl);
				if (try assoc = mac.associated_type.get())
				{
					if (!visit(assoc, parent, hooks, data)) return false;
				}
				if (try ret = mac.ret_type.get())
				{
					if (!visit(ret, parent, hooks, data)) return false;
				}
				if (mac.generics && !visit(mac.generics, parent, hooks, data)) return false;
				foreach (param : mac.params)
				{
					if (!visit(param, parent, hooks, data)) return false;
				}
				if (mac.body_params && !visit(mac.body_params, parent, hooks, data)) return false;
				foreach (attr : mac.attributes)
				{
					if (!visit(attr, parent, hooks, data)) return false;
				}
				if (try contract = mac.contract.get())
				{
					if (!visit(contract, parent, hooks, data)) return false;
				}
				if (mac.body && !visit(mac.body, parent, hooks, data)) return false;
				break;
			}
		case STRUCT_DECL:
			{
				StructDecl* structdecl = node.as(StructDecl);
				if (structdecl.generics && !visit(structdecl.generics, parent, hooks, data)) return false;
				foreach (inter : structdecl.interfaces)
				{
					if (!visit(inter, parent, hooks, data)) return false;
				}
				foreach (field : structdecl.fields)
				{
					if (!visit(field, parent, hooks, data)) return false;
				}
				foreach (attr : structdecl.attributes)
				{
					if (!visit(attr, parent, hooks, data)) return false;
				}
				if (structdecl.next)
				{
					if (!visit(structdecl.next, parent, hooks, data)) return false;
				}
				if (structdecl.type)
				{
					if (!visit(structdecl.type, parent, hooks, data)) return false;
				}
				break;
			}
		case ATTRIBUTE_DECL:
			{
				AttributeDecl* attr = node.as(AttributeDecl);
				if (try val = attr.path.get())
				{
					if (!visit(val, parent, hooks, data)) return false;
				}

				foreach (expr : attr.exprs)
				{
					if (!visit(expr, parent, hooks, data)) return false;
				}

				break;
			}
		case ENUM_DECL:
			{
				EnumDecl* ed = node.as(EnumDecl);
				if (ed.backing_type)
				{
					if (!visit(ed.backing_type, parent, hooks, data)) return false;
				}
				foreach (inter : ed.interfaces)
				{
					if (!visit(inter, parent, hooks, data)) return false;
				}
				foreach (vari : ed.variants)
				{
					if (!visit(vari, parent, hooks, data)) return false;
				}
				foreach (attr : ed.attributes)
				{
					if (!visit(attr, parent, hooks, data)) return false;
				}
				foreach (param : ed.assoc_params)
				{
					if (!visit(param, parent, hooks, data)) return false;
				}
				break;
			}
		case VAR_DECL:
			{
				VarDecl* vardecl = node.as(VarDecl);
				if (vardecl.type && !visit(vardecl.type, parent, hooks, data)) return false;
				if (vardecl.init_expr && !visit(vardecl.init_expr, parent, hooks, data)) return false;
				foreach (attr : vardecl.attributes)
				{
					if (!visit(attr, parent, hooks, data)) return false;
				}
				if (vardecl.next && !visit(vardecl.next, parent, hooks, data)) return false;
				break;
			}
		case TYPEDEF_DECL:
			{
				TypedefDecl* td = node.as(TypedefDecl);
				if (td.generics && !visit(td.generics, parent, hooks, data)) return false;
				if (td.base_type && !visit(td.base_type, parent, hooks, data)) return false;
				foreach (inter : td.interfaces)
				{
					if (!visit(inter, parent, hooks, data)) return false;
				}
				foreach (attr : td.attributes)
				{
					if (!visit(attr, parent, hooks, data)) return false;
				}
				break;
			}
		case ALIAS_DECL:
			{
				AliasDecl* ad = node.as(AliasDecl);
				if (ad.generics && !visit(ad.generics, parent, hooks, data)) return false;
				if (ad.target && !visit(ad.target, parent, hooks, data)) return false;
				foreach (attr : ad.attributes)
				{
					if (!visit(attr, parent, hooks, data)) return false;
				}
				break;
			}
		case FAULTDEF_DECL:
			{
				FaultdefDecl* fd = node.as(FaultdefDecl);
				foreach (f : fd.faults)
				{
					if (!visit(f, parent, hooks, data)) return false;
				}
				break;
			}
		case INTERFACE_DECL:
			{
				InterfaceDecl* inter = node.as(InterfaceDecl);
				foreach (val : inter.interfaces)
				{
					if (!visit(val, parent, hooks, data)) return false;
				}
				foreach (val : inter.attributes)
				{
					if (!visit(val, parent, hooks, data)) return false;
				}
				foreach (val : inter.methods)
				{
					if (!visit(val, parent, hooks, data)) return false;
				}
				break;
			}
		case GENERIC_DECL:
			{
				GenericDecl* gd = node.as(GenericDecl);
				foreach (val : gd.params)
				{
					if (!visit(val, parent, hooks, data)) return false;
				}
				break;
			}
		case BODY_PARAM_DECL:
			{
				BodyParamDecl* bpd = node.as(BodyParamDecl);
				foreach (val : bpd.params)
				{
					if (!visit(val, parent, hooks, data)) return false;
				}
				break;
			}
		default:
			break;
	}

	return true;
}

fn bool visit_stmts(Node* node, Node* parent, VisitorHooks hooks, void* data) @private
{
	switch (node.kind)
	{
		case COMPOUND_STMT:
			{
				CompoundStmt* comp = node.as(CompoundStmt);
				foreach (stmt : comp.statements)
				{
					if (!visit(stmt, parent, hooks, data)) return false;
				}
				break;
			}

		case IF_STMT:
			{
				IfStmt* if_stmt = node.as(IfStmt);

				if (if_stmt.condition && !visit(if_stmt.condition, parent, hooks, data)) return false;
				if (if_stmt.then_body && !visit(if_stmt.then_body, parent, hooks, data)) return false;
				if (if_stmt.else_body && !visit(if_stmt.else_body, parent, hooks, data)) return false;

				break;
			}

		case CT_IF_STMT:
			{
				CtIfStmt* if_stmt = node.as(CtIfStmt);

				if (if_stmt.expr && !visit(if_stmt.expr, parent, hooks, data)) return false;
				foreach (val : if_stmt.then_stmts)
				{
					if (!visit(val, parent, hooks, data)) return false;
				}
				foreach (val : if_stmt.else_stmts)
				{
					if (!visit(val, parent, hooks, data)) return false;
				}
				break;
			}

		case SWITCH_STMT:
			{
				SwitchStmt* swi = node.as(SwitchStmt);
				if (swi.cond && !visit(swi.cond, parent, hooks, data)) return false;
				foreach (val : swi.cases)
				{
					if (!visit(val, parent, hooks, data)) return false;
				}
				break;
			}

		case DEFAULT_STMT:
			{
				DefaultStmt* def = node.as(DefaultStmt);
				if (def.body && !visit(def.body, parent, hooks, data)) return false;
				break;
			}

		case CASE_STMT:
			{
				CaseStmt* cs = node.as(CaseStmt);
				if (cs.expr && !visit(cs.expr, parent, hooks, data)) return false;
				if (cs.to_expr && !visit(cs.to_expr, parent, hooks, data)) return false;
				if (cs.body && !visit(cs.body, parent, hooks, data)) return false;
				break;
			}

		case NEXTCASE_STMT:
			{
				NextcaseStmt* next = node.as(NextcaseStmt);
				if (next.expr && !visit(next.expr, parent, hooks, data)) return false;
				break;
			}

		case RETURN_STMT:
			{
				ReturnStmt* ret = node.as(ReturnStmt);
				if (ret.expr && !visit(ret.expr, parent, hooks, data)) return false;
				break;
			}

		case CT_SWITCH_STMT:
			{
				CtSwitchStmt* cts = node.as(CtSwitchStmt);
				if (cts.cond && !visit(cts.cond, parent, hooks, data)) return false;
				foreach (val : cts.cases)
				{
					if (!visit(val, parent, hooks, data)) return false;
				}
				break;
			}
		case EXPR_STMT:
			{
				ExprStmt* exst = node.as(ExprStmt);
				if (exst.expr_stmt)
				{
					if (!visit(exst.expr_stmt, parent, hooks, data)) return false;
				}
				break;
			}
		case FOR_STMT:
			{
				ForStmt* fs = node.as(ForStmt);
				if (try val = fs.init.get())
				{
					if (!visit(val, parent, hooks, data)) return false;
				}
				if (try val = fs.cond.get())
				{
					if (!visit(val, parent, hooks, data)) return false;
				}
				if (try val = fs.incr.get())
				{
					if (!visit(val, parent, hooks, data)) return false;
				}
				if (fs.body && !visit(fs.body, parent, hooks, data)) return false;
				break;
			}
		case CT_FOR_STMT:
			{
				CtForStmt* fs = node.as(CtForStmt);
				if (try val = fs.init.get())
				{
					if (!visit(val, parent, hooks, data)) return false;
				}

				if (fs.cond && !visit(fs.cond, parent, hooks, data)) return false;

				if (try val = fs.incr.get())
				{
					if (!visit(val, parent, hooks, data)) return false;
				}
				if (fs.body && !visit(fs.body, parent, hooks, data)) return false;
				break;
			}
		case WHILE_STMT:
			{
				WhileStmt* ws = node.as(WhileStmt);
				if (ws.cond && !visit(ws.cond, parent, hooks, data)) return false;
				if (ws.body && !visit(ws.body, parent, hooks, data)) return false;
				break;
			}
		case DO_WHILE_STMT:
			{
				DoWhileStmt* dws = node.as(DoWhileStmt);
				if (dws.body && !visit(dws.body, parent, hooks, data)) return false;
				if (try val = dws.cond.get())
				{
					if (!visit(val, parent, hooks, data)) return false;
				}
				break;
			}
		case FOREACH_STMT:
			{
				ForeachStmt* st = node.as(ForeachStmt);
				if (st.index && !visit(st.index, parent, hooks, data)) return false;
				if (st.variable && !visit(st.variable, parent, hooks, data)) return false;
				if (st.enumeration && !visit(st.enumeration, parent, hooks, data)) return false;
				if (st.body && !visit(st.body, parent, hooks, data)) return false;
				break;
			}
		case CT_FOREACH_STMT:
			{
				CtForeachStmt* st = node.as(CtForeachStmt);
				if (st.index && !visit(st.index, parent, hooks, data)) return false;
				if (st.value && !visit(st.value, parent, hooks, data)) return false;
				if (st.expr && !visit(st.expr, parent, hooks, data)) return false;
				if (st.body && !visit(st.body, parent, hooks, data)) return false;
				break;
			}
		case DEFER_STMT:
			{
				DeferStmt* st = node.as(DeferStmt);
				if (st.ident && !visit(st.ident, parent, hooks, data)) return false;
				if (st.body && !visit(st.body, parent, hooks, data)) return false;
				break;
			}
		case CT_EXPAND_STMT:
			{
				CtExpandStmt* st = node.as(CtExpandStmt);
				if (st.expr && !visit(st.expr, parent, hooks, data)) return false;
				break;
			}
		default:
			break;
	}

	return true;
}

fn bool visit_exprs(Node* node, Node* parent, VisitorHooks hooks, void* data) @private
{
	switch (node.kind)
	{
		case IDENT_EXPR:
			{
				IdentExpr* ident = node.as(IdentExpr);
				if (ident.path_expr && !visit(ident.path_expr, parent, hooks, data)) return false;
				break;
			}
		case CALL_EXPR:
			{
				CallExpr* call = node.as(CallExpr);
				if (call.callee && !visit(call.callee, parent, hooks, data)) return false;
				foreach (arg : call.args)
				{
					if (!visit(arg, parent, hooks, data)) return false;
				}
				if (call.macro_body_expr && !visit((Node*)call.macro_body_expr, parent, hooks, data)) return false;
				break;
			}
		case ACCESS_EXPR:
			{
				AccessExpr* access = node.as(AccessExpr);
				if (access.left && !visit(access.left, parent, hooks, data)) return false;
				if (access.member && !visit(access.member, parent, hooks, data)) return false;
				break;
			}
		case BINARY_EXPR:
			{
				BinaryExpr* bin = node.as(BinaryExpr);
				if (bin.left && !visit(bin.left, parent, hooks, data)) return false;
				if (bin.right && !visit(bin.right, parent, hooks, data)) return false;
				break;
			}
		case TYPE_EXPR:
			{
				TypeExpr* te = node.as(TypeExpr);
				switch (te.type_kind)
				{
				case TYPE_IDENTIFIER:
					{
						if (te.unresolved.path && !visit(te.unresolved.path, parent, hooks, data)) return false;
						break;
					}
				case TYPE_POINTER:
				case TYPE_SLICE:
					{
						if (te.modify.base && !visit(te.modify.base, parent, hooks, data)) return false;
						break;
					}
				case TYPE_ARRAY:
				case TYPE_VECTOR:
					{
						if (te.array.base && !visit(te.array.base, parent, hooks, data)) return false;
						if (te.array.len_expr && !visit(te.array.len_expr, parent, hooks, data)) return false;
						break;
					}
				case TYPE_GENERIC:
					{
						if (te.generic.base && !visit(te.generic.base, parent, hooks, data)) return false;
						foreach (param : te.generic.params)
						{
							if (!visit(param, parent, hooks, data)) return false;
						}
						break;
					}
				case TYPE_TYPEOF:
				case TYPE_TYPEFROM:
					{
						if (te.expr && !visit(te.expr, parent, hooks, data)) return false;
						break;
					}
				case TYPE_FUNCTION:
					{
						if (te.func.ret_type && !visit(te.func.ret_type, parent, hooks, data)) return false;
						foreach (param : te.func.params)
						{
							if (!visit(param, parent, hooks, data)) return false;
						}
						foreach (attr : te.func.attributes)
						{
							if (!visit(attr, parent, hooks, data)) return false;
						}
						break;
					}
			}
			break;
		}
		case EXPR_LIST:
			{
				ExprList* list = node.as(ExprList);
				foreach (val : list.exprs)
				{
					if (!visit(val, parent, hooks, data)) return false;
				}
				break;
			}
		case UNARY_EXPR:
			{
				UnaryExpr* expr = node.as(UnaryExpr);
				if (expr.expr && !visit(expr.expr, parent, hooks, data)) return false;
				break;
			}
		case POST_UNARY_EXPR:
			{
				PostUnaryExpr* expr = node.as(PostUnaryExpr);
				if (expr.expr && !visit(expr.expr, parent, hooks, data)) return false;
				break;
			}
		case COND_EXPR:
			{
				CondExpr* list = node.as(CondExpr);
				foreach (val : list.exprs)
				{
					if (!visit(val, parent, hooks, data)) return false;
				}
				break;
			}
		case MACRO_BODY_EXPR:
			{
				MacroBodyExpr* expr = node.as(MacroBodyExpr);
				foreach (val : expr.args)
				{
					if (!visit(val, parent, hooks, data)) return false;
				}
				if (expr.body && !visit(expr.body, parent, hooks, data)) return false;
				break;
			}
		case CAST_EXPR:
			{
				CastExpr* cast = node.as(CastExpr);
				if (cast.inner && !visit(cast.inner, parent, hooks, data)) return false;
				if (cast.operand && !visit(cast.operand, parent, hooks, data)) return false;
				break;
			}
		case GROUP_EXPR:
			{
				GroupExpr* group = node.as(GroupExpr);
				if (group.inner && !visit(group.inner, parent, hooks, data)) return false;
				break;
			}
		case TERNARY_EXPR:
			{
				TernaryExpr* ternary = node.as(TernaryExpr);
				if (ternary.cond && !visit(ternary.cond, parent, hooks, data)) return false;
				if (ternary.then_expr && !visit(ternary.then_expr, parent, hooks, data)) return false;
				if (ternary.else_expr && !visit(ternary.else_expr, parent, hooks, data)) return false;
				break;
			}
		case TRY_EXPR:
			{
				TryExpr* try_expr = node.as(TryExpr);
				if (try_expr.type && !visit(try_expr.type, parent, hooks, data)) return false;
				if (try_expr.variable && !visit(try_expr.variable, parent, hooks, data)) return false;
				if (try_expr.init && !visit(try_expr.init, parent, hooks, data)) return false;
				if (try_expr.next && !visit(try_expr.next, parent, hooks, data)) return false;
				break;
			}
		case CATCH_EXPR:
			{
				CatchExpr* catch_expr = node.as(CatchExpr);
				if (catch_expr.type && !visit(catch_expr.type, parent, hooks, data)) return false;
				if (catch_expr.variable && !visit(catch_expr.variable, parent, hooks, data)) return false;
				foreach (expr : catch_expr.exprs)
				{
					if (!visit(expr, parent, hooks, data)) return false;
				}
				break;
			}
		case INITIALIZER_LIST_EXPR:
			{
				InitializerListExpr* init = node.as(InitializerListExpr);
				foreach (expr : init.exprs)
				{
					if (!visit(expr, parent, hooks, data)) return false;
				}
				break;
			}
		case COMPOUND_LITERAL_EXPR:
			{
				CompoundLiteralExpr* lit = node.as(CompoundLiteralExpr);
				if (lit.type_expr && !visit(lit.type_expr, parent, hooks, data)) return false;
				if (lit.initializer_expr && !visit(lit.initializer_expr, parent, hooks, data)) return false;
				break;
			}
		case DESIGNATED_INITIALIZER_EXPR:
			{
				DesignatedInitializerExpr* des = node.as(DesignatedInitializerExpr);
				if (des.path && !visit(des.path, parent, hooks, data)) return false;
				if (des.value && !visit(des.value, parent, hooks, data)) return false;
				break;
			}
		case DESIGNATOR_EXPR:
			{
				DesignatorExpr* des = node.as(DesignatorExpr);
				if (des.path && !visit(des.path, parent, hooks, data)) return false;
				if (des.designator_kind == PERIOD && des.data.field && !visit(des.data.field, parent, hooks, data)) return false;
				if (des.designator_kind != PERIOD && des.data.range && !visit(des.data.range, parent, hooks, data)) return false;
				break;
			}
		case NAMED_ARG_EXPR:
			{
				NamedArgExpr* named = node.as(NamedArgExpr);
				if (named.value && !visit(named.value, parent, hooks, data)) return false;
				break;
			}
		case SPLAT_EXPR:
			{
				SplatExpr* splat = node.as(SplatExpr);
				if (splat.inner && !visit(splat.inner, parent, hooks, data)) return false;
				break;
			}
		case LAMBDA_EXPR:
			{
				LambdaExpr* lambda = node.as(LambdaExpr);
				if (lambda.return_type && !visit(lambda.return_type, parent, hooks, data)) return false;
				foreach (p : lambda.params)
				{
					if (!visit(p, parent, hooks, data)) return false;
				}
				if (lambda.body && !visit(lambda.body, parent, hooks, data)) return false;
				break;
			}
		case RANGE_EXPR:
			{
				RangeExpr* range = node.as(RangeExpr);
				if (range.start && !visit(range.start, parent, hooks, data)) return false;
				if (range.end && !visit(range.end, parent, hooks, data)) return false;
				break;
			}
		case CT_DEFINED_EXPR:
			{
				CtDefinedExpr* def = node.as(CtDefinedExpr);
				foreach (e : def.expr_list)
				{
					if (!visit(e, parent, hooks, data)) return false;
				}
				break;
			}
		case CT_REFLECT_EXPR:
			{
				CtReflectExpr* ref = node.as(CtReflectExpr);
				if (ref.inner_expr && !visit(ref.inner_expr, parent, hooks, data)) return false;
				break;
			}
		case CT_STRINGIFY_EXPR:
			{
				CtStringifyExpr* str = node.as(CtStringifyExpr);
				if (str.inner_expr && !visit(str.inner_expr, parent, hooks, data)) return false;
				break;
			}
		case CT_FEATURE_EXPR:
			{
				CtFeatureExpr* feat = node.as(CtFeatureExpr);
				if (feat.inner_expr && !visit(feat.inner_expr, parent, hooks, data)) return false;
				break;
			}
		case CT_EVAL_EXPR:
			{
				CtEvalExpr* ev = node.as(CtEvalExpr);
				if (ev.inner_expr && !visit(ev.inner_expr, parent, hooks, data)) return false;
				break;
			}
		case LENGTHOF_EXPR:
			{
				LengthofExpr* len = node.as(LengthofExpr);
				if (len.inner_expr && !visit(len.inner_expr, parent, hooks, data)) return false;
				break;
			}
		case OPTIONAL_EXPR:
			{
				OptionalExpr* opt = node.as(OptionalExpr);
				if (opt.inner_expr && !visit(opt.inner_expr, parent, hooks, data)) return false;
				break;
			}
		case MAYBE_DEREF_EXPR:
			{
				MaybeDerefExpr* md = node.as(MaybeDerefExpr);
				if (md.left && !visit(md.left, parent, hooks, data)) return false;
				break;
			}
		case GENERIC_IDENT_EXPR:
			{
				GenericIdentExpr* gi = node.as(GenericIdentExpr);
				foreach (e : gi.exprs)
				{
					if (!visit(e, parent, hooks, data)) return false;
				}
				break;
			}
		case EVAL_NAMED_ARG_EXPR:
			{
				EvalNamedArgExpr* ena = node.as(EvalNamedArgExpr);
				if (ena.name && !visit(ena.name, parent, hooks, data)) return false;
				if (ena.value && !visit(ena.value, parent, hooks, data)) return false;
				break;
			}
		case CONTRACT_EXPR:
			{
				ContractExpr* ce = node.as(ContractExpr);
				if (ce.exprs && !visit(ce.exprs, parent, hooks, data)) return false;
				if (ce.expr_string && !visit(ce.expr_string, parent, hooks, data)) return false;
				break;
			}
		default:
			break;
	}

	return true;
}
