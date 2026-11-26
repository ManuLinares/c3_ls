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

	// `int a, b;` chains `b` through `next`, a sibling of `a` outside its range.
	if (child.kind == VAR_DECL && child.as(VarDecl).next) return visit(child.as(VarDecl).next, parent, hooks, data);
	return true;
}

<*
 Doc contract attached to a declaration, or null.
*>
fn Node*? decl_contract(Node* node)
{
	NullableNode contract;
	switch (node.kind)
	{
		case MODULE_DECL: contract = node.as(ModuleDecl).contract;
		case FN_DECL: contract = node.as(FnDecl).contract;
		case MACRO_DECL: contract = node.as(MacroDecl).contract;
		case STRUCT_DECL: contract = node.as(StructDecl).contract;
		case INTERFACE_DECL: contract = node.as(InterfaceDecl).contract;
		case FAULTDEF_DECL: contract = node.as(FaultdefDecl).contract;
		case FAULT_DECL: contract = node.as(FaultDecl).contract;
		case VAR_DECL: contract = node.as(VarDecl).contract;
		case ENUM_DECL: contract = node.as(EnumDecl).contract;
		case ALIAS_DECL: contract = node.as(AliasDecl).contract;
		case TYPEDEF_DECL: contract = node.as(TypedefDecl).contract;
		default: return NOT_FOUND~;
	}
	return contract.get();
}

faultdef VISIT_BREAK;

<*
 The children of `parent` being visited; each method fails with VISIT_BREAK when a hook asks to stop.
*>
struct Walk
{
	Node* parent;
	VisitorHooks hooks;
	void* data;
}

fn void? Walk.node(&self, Node* child)
{
	if (!visit(child, self.parent, self.hooks, self.data)) return VISIT_BREAK~;
}

fn void? Walk.opt(&self, NullableNode child)
{
	if (try c = child.get()) self.node(c)!;
}

fn void? Walk.all(&self, NodeArray children)
{
	foreach (child : children)
	{
		if (child) self.node(child)!;
	}
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
	Walk w = { parent, hooks, data };
	switch
	{
		case parent.kind.is_decl(): return @ok(visit_decls(parent, &w));
		case parent.kind.is_stmt(): return @ok(visit_stmts(parent, &w));
		case parent.kind.is_expr(): return @ok(visit_exprs(parent, &w));
		default: return true;
	}
}

fn void? visit_decls(Node* node, Walk* w) @private
{
	if (try contract = decl_contract(node)) w.node(contract)!;
	switch (node.kind)
	{
		case MODULE_DECL:
			{
				ModuleDecl* md = node.as(ModuleDecl);
				w.opt(md.path)!;
				w.all(md.attributes)!;
				w.opt(md.generics)!;
				break;
			}
		case IMPORT_DECL:
			{
				ImportDecl* id = node.as(ImportDecl);
				w.all(id.attributes)!;
				foreach (path : id.paths)
				{
					w.node(path)!;
					// Each path's attributes follow it, outside its range.
					if (path && path.kind == PATH_EXPR)
					{
						w.all(path.as(PathExpr).attributes)!;
					}
				}
				break;
			}
		case FN_DECL:
			{
				FnDecl* fndecl = node.as(FnDecl);
				w.opt(fndecl.associated_type)!;
				w.node(fndecl.ret_type)!;
				w.opt(fndecl.generics)!;
				w.all(fndecl.params)!;
				w.all(fndecl.attributes)!;
				w.opt(fndecl.body)!;
				break;
			}
		case MACRO_DECL:
			{
				MacroDecl* mac = node.as(MacroDecl);
				w.opt(mac.associated_type)!;
				w.opt(mac.ret_type)!;
				w.opt(mac.generics)!;
				w.all(mac.params)!;
				w.opt(mac.body_params)!;
				w.all(mac.attributes)!;
				w.opt(mac.body)!;
				break;
			}
		case STRUCT_DECL:
			{
				StructDecl* structdecl = node.as(StructDecl);
				w.opt(structdecl.generics)!;
				w.all(structdecl.interfaces)!;
				w.all(structdecl.fields)!;
				w.all(structdecl.attributes)!;
				w.opt(structdecl.type)!;
				break;
			}
		case ATTRIBUTE_DECL:
			{
				AttributeDecl* attr = node.as(AttributeDecl);
				w.opt(attr.path)!;

				w.all(attr.exprs)!;

				break;
			}
		case ENUM_DECL:
			{
				EnumDecl* ed = node.as(EnumDecl);
				w.opt(ed.backing_type)!;
				w.all(ed.interfaces)!;
				w.all(ed.variants)!;
				w.all(ed.attributes)!;
				w.all(ed.assoc_params)!;
				break;
			}
		case VAR_DECL:
			{
				VarDecl* vardecl = node.as(VarDecl);
				// The type of an implicit self parameter is the method's associated
				// type node, and `b` in `int a, b;` shares the type node of `a`.
				bool owns_type = node.range.contains(vardecl.type.get().range.start) ?? false;
				if (owns_type) w.opt(vardecl.type)!;
				w.opt(vardecl.init_expr)!;
				w.opt(vardecl.assoc_values)!;
				w.all(vardecl.attributes)!;
				break;
			}
		case TYPEDEF_DECL:
			{
				TypedefDecl* td = node.as(TypedefDecl);
				w.opt(td.generics)!;
				w.opt(td.base_type)!;
				w.all(td.interfaces)!;
				w.all(td.attributes)!;
				break;
			}
		case ALIAS_DECL:
			{
				AliasDecl* ad = node.as(AliasDecl);
				w.opt(ad.generics)!;
				w.opt(ad.target)!;
				w.all(ad.attributes)!;
				break;
			}
		case FAULTDEF_DECL:
			{
				FaultdefDecl* fd = node.as(FaultdefDecl);
				w.all(fd.faults)!;
				break;
			}
		case INTERFACE_DECL:
			{
				InterfaceDecl* inter = node.as(InterfaceDecl);
				w.all(inter.interfaces)!;
				w.all(inter.attributes)!;
				w.all(inter.methods)!;
				break;
			}
		case GENERIC_DECL:
			{
				GenericDecl* gd = node.as(GenericDecl);
				w.all(gd.params)!;
				break;
			}
		case BODY_PARAM_DECL:
			{
				BodyParamDecl* bpd = node.as(BodyParamDecl);
				w.all(bpd.params)!;
				break;
			}
		case FAULT_DECL:
			{
				FaultDecl* fd = node.as(FaultDecl);
				w.all(fd.attributes)!;
				break;
			}
		case ATTRDEF_DECL:
			{
				AttrdefDecl* ad = node.as(AttrdefDecl);
				w.all(ad.params)!;
				w.all(ad.attributes)!;
				w.all(ad.defined_attributes)!;
				break;
			}
		case CT_ASSERT_DECL:
			{
				CtAssertDecl* ca = node.as(CtAssertDecl);
				w.node(ca.stmt)!;
				break;
			}
		case CT_INCLUDE_DECL:
			w.all(node.as(CtIncludeDecl).args)!;
		case CT_EXPAND_DECL:
			{
				CtExpandDecl* ce = node.as(CtExpandDecl);
				w.node(ce.expr)!;
				w.all(ce.attributes)!;
				break;
			}
		case CONTRACT_DECL:
			{
				ContractDecl* cd = node.as(ContractDecl);
				w.all(cd.params)!;
				w.all(cd.requires)!;
				w.all(cd.ensures)!;
				w.all(cd.returns)!;
				w.opt(cd.return_desc)!;
				w.opt(cd.deprecated)!;
				break;
			}
		default:
			break;
	}
}

fn void? visit_stmts(Node* node, Walk* w) @private
{
	switch (node.kind)
	{
		case COMPOUND_STMT:
			{
				CompoundStmt* comp = node.as(CompoundStmt);
				w.all(comp.statements)!;
				break;
			}

		case IF_STMT:
			{
				IfStmt* if_stmt = node.as(IfStmt);

				w.node(if_stmt.condition)!;
				w.node(if_stmt.then_body)!;
				w.opt(if_stmt.else_body)!;

				break;
			}

		case CT_IF_STMT:
			{
				CtIfStmt* if_stmt = node.as(CtIfStmt);

				w.node(if_stmt.expr)!;
				w.all(if_stmt.then_stmts)!;
				w.all(if_stmt.else_stmts)!;
				break;
			}

		case SWITCH_STMT:
			{
				SwitchStmt* swi = node.as(SwitchStmt);
				w.all(swi.attributes)!;
				w.opt(swi.cond)!;
				w.all(swi.cases)!;
				break;
			}

		case DEFAULT_STMT:
			{
				DefaultStmt* def = node.as(DefaultStmt);
				w.node(def.body)!;
				break;
			}

		case CASE_STMT:
			{
				CaseStmt* cs = node.as(CaseStmt);
				w.node(cs.expr)!;
				w.opt(cs.to_expr)!;
				w.node(cs.body)!;
				break;
			}

		case NEXTCASE_STMT:
			{
				NextcaseStmt* next = node.as(NextcaseStmt);
				w.opt(next.expr)!;
				break;
			}

		case RETURN_STMT:
			{
				ReturnStmt* ret = node.as(ReturnStmt);
				w.opt(ret.expr)!;
				break;
			}

		case CT_SWITCH_STMT:
			{
				CtSwitchStmt* cts = node.as(CtSwitchStmt);
				w.opt(cts.cond)!;
				w.all(cts.cases)!;
				break;
			}
		case EXPR_STMT:
			{
				ExprStmt* exst = node.as(ExprStmt);
				w.node(exst.expr_stmt)!;
				break;
			}
		case FOR_STMT:
			{
				ForStmt* fs = node.as(ForStmt);
				w.opt(fs.init)!;
				w.opt(fs.cond)!;
				w.opt(fs.incr)!;
				w.node(fs.body)!;
				break;
			}
		case CT_FOR_STMT:
			{
				CtForStmt* fs = node.as(CtForStmt);
				w.opt(fs.init)!;

				w.opt(fs.cond)!;

				w.opt(fs.incr)!;
				w.node(fs.body)!;
				break;
			}
		case WHILE_STMT:
			{
				WhileStmt* ws = node.as(WhileStmt);
				w.node(ws.cond)!;
				w.node(ws.body)!;
				break;
			}
		case DO_WHILE_STMT:
			{
				DoWhileStmt* dws = node.as(DoWhileStmt);
				w.node(dws.body)!;
				w.opt(dws.cond)!;
				break;
			}
		case FOREACH_STMT:
			{
				ForeachStmt* st = node.as(ForeachStmt);
				w.opt(st.index)!;
				w.node(st.variable)!;
				w.node(st.enumeration)!;
				w.node(st.body)!;
				break;
			}
		case CT_FOREACH_STMT:
			{
				CtForeachStmt* st = node.as(CtForeachStmt);
				w.opt(st.index)!;
				w.node(st.value)!;
				w.node(st.expr)!;
				w.node(st.body)!;
				break;
			}
		case DEFER_STMT:
			{
				DeferStmt* st = node.as(DeferStmt);
				w.opt(st.ident)!;
				w.node(st.body)!;
				break;
			}
		case CT_EXPAND_STMT:
			{
				CtExpandStmt* st = node.as(CtExpandStmt);
				w.node(st.expr)!;
				break;
			}
		case ASSERT_STMT:
			{
				AssertStmt* st = node.as(AssertStmt);
				w.node(st.expr)!;
				w.opt(st.message)!;
				w.all(st.args)!;
				break;
			}
		case CT_ASSERT_STMT:
			{
				CtAssertStmt* st = node.as(CtAssertStmt);
				w.node(st.expr)!;
				w.opt(st.msg_expr)!;
				w.all(st.args)!;
				break;
			}
		case CT_ERROR_STMT:
			{
				CtErrorStmt* st = node.as(CtErrorStmt);
				w.node(st.expr)!;
				break;
			}
		case CT_ECHO_STMT:
			{
				CtEchoStmt* st = node.as(CtEchoStmt);
				w.node(st.expr)!;
				break;
			}
		default:
			break;
	}
}

fn void? visit_exprs(Node* node, Walk* w) @private
{
	switch (node.kind)
	{
		case IDENT_EXPR:
			{
				IdentExpr* ident = node.as(IdentExpr);
				w.opt(ident.path_expr)!;
				break;
			}
		case CALL_EXPR:
			{
				CallExpr* call = node.as(CallExpr);
				w.node(call.callee)!;
				w.all(call.args)!;
				w.opt(call.macro_body_expr)!;
				break;
			}
		case ACCESS_EXPR:
			{
				AccessExpr* access = node.as(AccessExpr);
				w.node(access.left)!;
				w.opt(access.member)!;
				break;
			}
		case BINARY_EXPR:
			{
				BinaryExpr* bin = node.as(BinaryExpr);
				w.node(bin.left)!;
				w.node(bin.right)!;
				break;
			}
		case TYPE_EXPR:
			{
				TypeExpr* te = node.as(TypeExpr);
				switch (te.type_kind)
				{
				case TYPE_IDENTIFIER:
					{
						w.opt(te.unresolved.path)!;
						break;
					}
				case TYPE_POINTER:
				case TYPE_SLICE:
					{
						w.node(te.modify.base)!;
						break;
					}
				case TYPE_ARRAY:
				case TYPE_VECTOR:
					{
						w.node(te.array.base)!;
						w.opt(te.array.len_expr)!;
						break;
					}
				case TYPE_GENERIC:
					{
						w.node(te.generic.base)!;
						w.all(te.generic.params)!;
						break;
					}
				case TYPE_TYPEOF:
				case TYPE_TYPEFROM:
					{
						w.node(te.expr)!;
						break;
					}
				case TYPE_FUNCTION:
					{
						w.node(te.func.ret_type)!;
						w.all(te.func.params)!;
						w.all(te.func.attributes)!;
						break;
					}
			}
			break;
		}
		case EXPR_LIST:
			{
				ExprList* list = node.as(ExprList);
				w.all(list.exprs)!;
				break;
			}
		case UNARY_EXPR:
			{
				UnaryExpr* expr = node.as(UnaryExpr);
				w.node(expr.expr)!;
				break;
			}
		case POST_UNARY_EXPR:
			{
				PostUnaryExpr* expr = node.as(PostUnaryExpr);
				w.node(expr.expr)!;
				break;
			}
		case COND_EXPR:
			{
				CondExpr* list = node.as(CondExpr);
				w.all(list.exprs)!;
				break;
			}
		case MACRO_BODY_EXPR:
			{
				MacroBodyExpr* expr = node.as(MacroBodyExpr);
				w.all(expr.args)!;
				w.opt(expr.body)!;
				break;
			}
		case CAST_EXPR:
			{
				CastExpr* cast = node.as(CastExpr);
				w.node(cast.inner)!;
				w.node(cast.operand)!;
				break;
			}
		case GROUP_EXPR:
			{
				GroupExpr* group = node.as(GroupExpr);
				w.node(group.inner)!;
				break;
			}
		case TERNARY_EXPR:
			{
				TernaryExpr* ternary = node.as(TernaryExpr);
				w.node(ternary.cond)!;
				w.node(ternary.then_expr)!;
				w.node(ternary.else_expr)!;
				break;
			}
		case TRY_EXPR:
			{
				TryExpr* try_expr = node.as(TryExpr);
				w.opt(try_expr.type)!;
				w.node(try_expr.variable)!;
				w.opt(try_expr.init)!;
				if (try_expr.next) w.node(try_expr.next)!;
				break;
			}
		case CATCH_EXPR:
			{
				CatchExpr* catch_expr = node.as(CatchExpr);
				w.opt(catch_expr.type)!;
				w.opt(catch_expr.variable)!;
				w.all(catch_expr.exprs)!;
				break;
			}
		case INITIALIZER_LIST_EXPR:
			{
				InitializerListExpr* init = node.as(InitializerListExpr);
				w.all(init.exprs)!;
				break;
			}
		case COMPOUND_LITERAL_EXPR:
			{
				CompoundLiteralExpr* lit = node.as(CompoundLiteralExpr);
				w.node(lit.type_expr)!;
				w.node(lit.initializer_expr)!;
				break;
			}
		case DESIGNATED_INITIALIZER_EXPR:
			{
				DesignatedInitializerExpr* des = node.as(DesignatedInitializerExpr);
				w.node(des.path)!;
				w.node(des.value)!;
				break;
			}
		case DESIGNATOR_EXPR:
			{
				DesignatorExpr* des = node.as(DesignatorExpr);
				w.opt(des.path)!;
				switch (des.designator_kind)
				{
					case PERIOD: w.opt(des.data.field)!;
					default: w.node(des.data.range)!;
				}
				break;
			}
		case NAMED_ARG_EXPR:
			{
				NamedArgExpr* named = node.as(NamedArgExpr);
				w.node(named.value)!;
				break;
			}
		case SPLAT_EXPR:
			{
				SplatExpr* splat = node.as(SplatExpr);
				w.node(splat.inner)!;
				break;
			}
		case LAMBDA_EXPR:
			{
				LambdaExpr* lambda = node.as(LambdaExpr);
				w.opt(lambda.return_type)!;
				w.all(lambda.params)!;
				w.node(lambda.body)!;
				break;
			}
		case RANGE_EXPR:
			{
				RangeExpr* range = node.as(RangeExpr);
				w.opt(range.start)!;
				w.opt(range.end)!;
				break;
			}
		case CT_DEFINED_EXPR:
			{
				CtDefinedExpr* def = node.as(CtDefinedExpr);
				w.all(def.expr_list)!;
				break;
			}
		case CT_REFLECT_EXPR:
			{
				CtReflectExpr* ref = node.as(CtReflectExpr);
				w.node(ref.inner_expr)!;
				break;
			}
		case CT_STRINGIFY_EXPR:
			{
				CtStringifyExpr* str = node.as(CtStringifyExpr);
				w.node(str.inner_expr)!;
				break;
			}
		case CT_FEATURE_EXPR:
			{
				CtFeatureExpr* feat = node.as(CtFeatureExpr);
				w.all(feat.expr_list)!;
				break;
			}
		case CT_EVAL_EXPR:
			{
				CtEvalExpr* ev = node.as(CtEvalExpr);
				w.node(ev.inner_expr)!;
				break;
			}
		case LENGTHOF_EXPR:
			{
				LengthofExpr* len = node.as(LengthofExpr);
				w.node(len.inner_expr)!;
				break;
			}
		case OPTIONAL_EXPR:
			{
				OptionalExpr* opt = node.as(OptionalExpr);
				w.node(opt.inner_expr)!;
				break;
			}
		case MAYBE_DEREF_EXPR:
			{
				MaybeDerefExpr* md = node.as(MaybeDerefExpr);
				w.node(md.left)!;
				break;
			}
		case GENERIC_IDENT_EXPR:
			{
				GenericIdentExpr* gi = node.as(GenericIdentExpr);
				w.node(gi.left)!;
				w.all(gi.exprs)!;
				break;
			}
		case EVAL_NAMED_ARG_EXPR:
			{
				EvalNamedArgExpr* ena = node.as(EvalNamedArgExpr);
				w.node(ena.name)!;
				w.node(ena.value)!;
				break;
			}
		case CONTRACT_EXPR:
			{
				ContractExpr* ce = node.as(ContractExpr);
				w.opt(ce.pinpoint)!;
				w.node(ce.exprs)!;
				w.opt(ce.expr_string)!;
				break;
			}
		case VASPLAT_EXPR:
			{
				VasplatExpr* ve = node.as(VasplatExpr);
				w.opt(ve.range_expr)!;
				break;
			}
		case VAARG_EXPR:
			{
				VaargExpr* ve = node.as(VaargExpr);
				w.opt(ve.expr)!;
				break;
			}
		default:
			break;
	}
}
