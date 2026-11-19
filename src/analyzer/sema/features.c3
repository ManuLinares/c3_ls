module analyzer::sema::query;
import analyzer, std::collections::list;

<*
 Module section declaration of `sf` that contains `loc`, or null before the first one.
*>
fn Node* section_node_at(SourceFile* sf, Location loc)
{
	sz index = section_at(sf, loc);
	return index >= 0 ? sf.ast.statements[sf.ast.module_decls[index]] : null;
}

<*
 Whether `decl` or its module section carries a `@feat`.
*>
fn bool has_feat(AnalyzerContext* context, Node* decl)
{
	SourceFile* sf = source_file::file_of(context, decl);
	return cursor::has_attribute(decl, FEAT, null) || (sf && cursor::has_attribute(section_node_at(sf, decl.range.start), FEAT, null));
}

<*
 The `@feat` attributes deciding whether `decl` is compiled: its own and its module section's.
*>
fn void feat_attributes(AnalyzerContext* context, Node* decl, List{AttributeDecl*}* out)
{
	SourceFile* sf = source_file::file_of(context, decl);
	Node* section = sf ? section_node_at(sf, decl.range.start) : null;
	foreach (owner : (Node*[2]){ section == decl ? null : section, decl })
	{
		foreach (attr : cursor::attributes(owner))
		{
			if (attr && attr.kind == ATTRIBUTE_DECL && attr.as(AttributeDecl).attribute_kind == FEAT) out.push(attr.as(AttributeDecl));
		}
	}
}

<*
 Whether `feature` is in `features` or enabled for code in `caller`.
*>
fn bool has_feature(String[] features, SourceFile* caller, String feature)
{
	return array::contains(features, feature) || (caller && array::contains(caller.features, feature));
}

faultdef NOT_A_FEATURE_LIST;

<*
 Value of the feature list `expr` of a `@feat` or `$feat`, as c3c evaluates
 it: uppercase feature names without a path, combined with `&`, `|` and
 parentheses, and negated by any unary operator. Anything else is an error
 in c3c and NOT_A_FEATURE_LIST here.
*>
fn bool? feature_list_holds(String[] features, SourceFile* caller, Node* expr)
{
	if (!expr) return NOT_A_FEATURE_LIST~;
	switch (expr.kind)
	{
		case IDENT_EXPR:
			IdentExpr* ie = expr.as(IdentExpr);
			if (!ie.ident || ie.path_expr || !ie.ident.text.len || !ie.ident.text[0].is_upper() || !lexer::is_all_upper(ie.ident.text)) return NOT_A_FEATURE_LIST~;
			return has_feature(features, caller, ie.ident.text);
		case UNARY_EXPR:
			return !feature_list_holds(features, caller, expr.as(UnaryExpr).expr)!;
		case BINARY_EXPR:
			BinaryExpr* be = expr.as(BinaryExpr);
			if (be.op != OP_BIT_AND && be.op != OP_BIT_OR) return NOT_A_FEATURE_LIST~;
			bool left = feature_list_holds(features, caller, be.left)!;
			bool right = feature_list_holds(features, caller, be.right)!;
			return be.op == OP_BIT_AND ? left && right : left || right;
		case GROUP_EXPR:
			return feature_list_holds(features, caller, expr.as(GroupExpr).inner);
		default:
			return NOT_A_FEATURE_LIST~;
	}
}

<*
 Whether one of the feature lists `exprs`, alternatives as in `@feat(A, B)`,
 holds. Like c3c, the first list that holds decides, and an invalid list
 before it makes the whole attribute fail.
*>
fn bool any_feature_list_holds(String[] features, SourceFile* caller, NodeArray exprs)
{
	foreach (expr : exprs)
	{
		bool? holds = feature_list_holds(features, caller, expr);
		if (catch holds) return false;
		if (holds) return true;
	}
	return false;
}

<*
 Whether `decl` is compiled with `features` for code in `caller`: every
 `@feat` on it and on its module section holds. Arguments of one `@feat` are
 alternatives.
*>
fn bool feat_enabled_with(AnalyzerContext* context, String[] features, SourceFile* caller, Node* decl)
{
	List{AttributeDecl*} attrs;
	attrs.tinit();
	feat_attributes(context, decl, &attrs);
	foreach (attr : attrs)
	{
		if (!any_feature_list_holds(features, caller, attr.exprs)) return false;
	}
	return true;
}

<*
 Whether `decl` is compiled for the context's target, for code in `caller`.
*>
fn bool feat_enabled(AnalyzerContext* context, SourceFile* caller, Node* decl) => feat_enabled_with(context, context.features, caller, decl);

<*
 Features named without negation in the `@feat` feature list `expr`, added to `out`.
*>
fn void positive_features(Node* expr, bool negated, List{String}* out)
{
	if (!expr) return;
	switch (expr.kind)
	{
		case IDENT_EXPR:
			Ident* ident = expr.as(IdentExpr).ident;
			if (ident && !negated) out.push(ident.text);
		case UNARY_EXPR:
			UnaryExpr* ue = expr.as(UnaryExpr);
			positive_features(ue.expr, !negated, out);
		case BINARY_EXPR:
			positive_features(expr.as(BinaryExpr).left, negated, out);
			positive_features(expr.as(BinaryExpr).right, negated, out);
		case GROUP_EXPR:
			positive_features(expr.as(GroupExpr).inner, negated, out);
		default:
			break;
	}
}

<*
 Feature lists of the `$if $feat(...)` and `$case $feat(...)` branches around `loc`, added to `out`.
*>
fn void branch_features(SourceFile* sf, Location loc, List{CtFeatureExpr*}* out)
{
	Node* at = node_at(sf, loc);
	if (!at) return;
	foreach (node : ancestors_of(sf, at))
	{
		switch (node.kind)
		{
			case CT_IF_STMT:
				CtIfStmt* ct_if = node.as(CtIfStmt);
				if (!ct_if.expr || ct_if.expr.kind != CT_FEATURE_EXPR) break;
				foreach (stmt : ct_if.then_stmts)
				{
					if (stmt && stmt.range.contains(loc)) out.push(ct_if.expr.as(CtFeatureExpr));
				}
			case CT_SWITCH_STMT:
				foreach (c : node.as(CtSwitchStmt).cases)
				{
					if (!c || c.kind != CASE_STMT || !c.range.contains(loc)) continue;
					Node* expr = c.as(CaseStmt).expr;
					if (expr && expr.kind == CT_FEATURE_EXPR) out.push(expr.as(CtFeatureExpr));
				}
			default:
				break;
		}
	}
}

<*
 Whether `code` is compiled with `features` for `sf`, inside the `$feat` branches `branches`.
*>
fn bool code_holds(AnalyzerContext* context, String[] features, SourceFile* sf, Node* code, CtFeatureExpr*[] branches)
{
	if (!feat_enabled_with(context, features, sf, code)) return false;
	foreach (branch : branches)
	{
		if (!any_feature_list_holds(features, sf, branch.expr_list)) return false;
	}
	return true;
}

<*
 Feature sets the code at `loc` in `sf` may be compiled with: the target's
 when that code is compiled for it, else those of every c3c target that
 compiles it, as Linux and macOS for AARCH64 code seen on x86_64. Features
 the code's `@feat`, and the `$if $feat`/`$case $feat` branches around it,
 ask for that no c3c target defines, such as WAYLAND, are assumed set, the
 target being tried first.
*>
fn String[][] platform_feature_sets(AnalyzerContext* context, SourceFile* sf, Location loc)
{
	List{String[]} sets;
	sets.tinit();
	Node* code = enclosing_top_level(sf, loc);
	if (!code || code.kind == MODULE_DECL) code = section_node_at(sf, loc);
	List{CtFeatureExpr*} branches;
	branches.tinit();
	if (code) branch_features(sf, loc, &branches);
	if (!code || code_holds(context, context.features, sf, code, branches.array_view()))
	{
		sets.push(context.features);
		return sets.array_view();
	}
	List{AttributeDecl*} attrs;
	attrs.tinit();
	feat_attributes(context, code, &attrs);
	List{String} named;
	named.tinit();
	foreach (attr : attrs) foreach (expr : attr.exprs) positive_features(expr, false, &named);
	foreach (branch : branches) foreach (expr : branch.expr_list) positive_features(expr, false, &named);
	List{String} custom;
	custom.tinit();
	foreach (f : named)
	{
		bool defined;
		foreach (t : arch::C3C_TARGETS) defined = defined || array::contains(t.features, f);
		if (!defined && !array::contains(custom.array_view(), f)) custom.push(f);
	}

	List{String} with_custom;
	with_custom.tinit();
	with_custom.push_all(context.features);
	with_custom.push_all(custom.array_view());
	if (custom.len() && code_holds(context, with_custom.array_view(), sf, code, branches.array_view()))
	{
		sets.push(with_custom.array_view());
		return sets.array_view();
	}
	foreach (assume : (bool[2]){ true, false })
	{
		foreach (t : arch::C3C_TARGETS)
		{
			List{String} features;
			features.tinit();
			features.push_all(t.features);
			if (assume) features.push_all(custom.array_view());
			if (code_holds(context, features.array_view(), sf, code, branches.array_view())) sets.push(features.array_view());
		}
		if (sets.len()) return sets.array_view();
	}
	sets.push(context.features);
	return sets.array_view();
}

<*
 Entries of the variant chain `head` best first for code at `loc` in `sf`:
 variants compiled for a platform that code is written for, then those
 compiled for the target, then the rest, each group in chain order.
*>
macro ranked(AnalyzerContext* context, SourceFile* sf, Location loc, head)
{
	List{$Typeof(head)} out;
	out.tinit();
	if (!head) return out.array_view();
	bool conditional;
	for (var curr = head; curr && !conditional; curr = curr.next) conditional = curr.node && has_feat(context, curr.node);
	if (!conditional || !sf)
	{
		for (var curr = head; curr; curr = curr.next) out.push(curr);
		return out.array_view();
	}
	String[][] platforms = platform_feature_sets(context, sf, loc);
	for (int rank = 2; rank >= 0; rank--)
	{
		for (var curr = head; curr; curr = curr.next)
		{
			if (variant_rank(context, sf, platforms, curr.node) == rank) out.push(curr);
		}
	}
	return out.array_view();
}

<*
 2 when `node` is compiled with one of the feature sets `platforms` of
 platform code, 1 when compiled for the target, 0 otherwise.
*>
fn int variant_rank(AnalyzerContext* context, SourceFile* sf, String[][] platforms, Node* node)
{
	if (!node) return 0;
	if (platforms[0].ptr != context.features.ptr)
	{
		foreach (features : platforms)
		{
			if (feat_enabled_with(context, features, sf, node)) return 2;
		}
	}
	return feat_enabled(context, sf, node) ? 1 : 0;
}

<*
 The variants of the platform-specific declaration `decl`, itself first,
 that the code at `loc` in `sf` may be compiled with; `decl` alone when
 that code is compiled for the target.
*>
fn void usable_variants(AnalyzerContext* context, SourceFile* sf, Location loc, Node* decl, List{Node*}* out)
{
	out.push(decl);
	if (!sf || !has_feat(context, decl)) return;
	String[][] platforms = platform_feature_sets(context, sf, loc);
	if (platforms[0].ptr == context.features.ptr) return;
	List{Node*} variants;
	variants.tinit();
	platform_variants(context, decl, &variants);
	foreach (v : variants)
	{
		if (v != decl && variant_rank(context, sf, platforms, v) == 2) out.push(v);
	}
}

<*
 Every platform variant of `decl`: the declarations of the same name in its
 module, of the same kind, and for a method of the same receiver type. Adds
 nothing when `decl` has no other variant.
*>
fn void platform_variants(AnalyzerContext* context, Node* decl, List{Node*}* out)
{
	if (!context.registry || !decl) return;
	SourceFile* sf = source_file::file_of(context, decl);
	if (!sf) return;
	String name = cursor::spelling(decl, tmem);
	if (!name.len) return;
	String qname = string::tformat("%s::%s", get_module_name_at_location(sf, decl.range.start), name.strip_prefix("@"));
	List{Node*} found;
	found.tinit();
	Node* receiver = receiver_type_expr(decl);
	if (receiver)
	{
		String receiver_name = cursor::raw_type_identifier(receiver) ?? "";
		for (MethodInfo* m = context.registry.methods_by_type.get(method_key(receiver_name)) ?? null; m; m = m.next)
		{
			Node* other = receiver_type_expr(m.node);
			if (m.node.kind == decl.kind && cursor::spelling(m.node, tmem) == name && other && (cursor::raw_type_identifier(other) ?? "") == receiver_name) found.push(m.node);
		}
	}
	else
	{
		switch (decl.kind)
		{
			case FN_DECL:
				for (FunctionInfo* f = context.registry.functions.get(qname) ?? null; f; f = f.next) if (!receiver_type_expr(f.node)) found.push(f.node);
			case MACRO_DECL:
				for (MacroInfo* f = context.registry.macros.get(qname) ?? null; f; f = f.next) if (!receiver_type_expr(f.node)) found.push(f.node);
			default:
				for (TypeInfo* t = context.registry.types.get(qname) ?? null; t; t = t.next) if (t.node.kind == decl.kind) found.push(t.node);
		}
	}
	if (found.len() > 1) out.push_all(found.array_view());
}
