module analyzer::sema::query;
import analyzer, std::collections::list;

<*
 Attributes written on the declaration `node`, or none.
*>
fn NodeArray declaration_attributes(Node* node)
{
	if (!node) return {};
	switch (node.kind)
	{
		case FN_DECL: return node.as(FnDecl).attributes;
		case MACRO_DECL: return node.as(MacroDecl).attributes;
		case STRUCT_DECL: return node.as(StructDecl).attributes;
		case ENUM_DECL: return node.as(EnumDecl).attributes;
		case TYPEDEF_DECL: return node.as(TypedefDecl).attributes;
		case ALIAS_DECL: return node.as(AliasDecl).attributes;
		case INTERFACE_DECL: return node.as(InterfaceDecl).attributes;
		case VAR_DECL: return node.as(VarDecl).attributes;
		case FAULT_DECL: return node.as(FaultDecl).attributes;
		case MODULE_DECL: return node.as(ModuleDecl).attributes;
		default: return {};
	}
}

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
	Node* section = sf ? section_node_at(sf, decl.range.start) : null;
	foreach (owner : (Node*[2]){ section, decl })
	{
		foreach (attr : declaration_attributes(owner))
		{
			if (attr && attr.kind == ATTRIBUTE_DECL && attr.as(AttributeDecl).attribute_kind == FEAT) return true;
		}
	}
	return false;
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
		foreach (attr : declaration_attributes(owner))
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

<*
 Value of the feature list `expr` of a `@feat`: feature names combined with
 `&`, `|`, `!` and parentheses.
*>
fn bool feature_list_holds(String[] features, SourceFile* caller, Node* expr)
{
	if (!expr) return true;
	switch (expr.kind)
	{
		case IDENT_EXPR:
			Ident* ident = expr.as(IdentExpr).ident;
			return ident && has_feature(features, caller, ident.text);
		case UNARY_EXPR:
			UnaryExpr* ue = expr.as(UnaryExpr);
			return ue.operator == UNARYOP_NOT ? !feature_list_holds(features, caller, ue.expr) : feature_list_holds(features, caller, ue.expr);
		case BINARY_EXPR:
			BinaryExpr* be = expr.as(BinaryExpr);
			bool left = feature_list_holds(features, caller, be.left);
			bool right = feature_list_holds(features, caller, be.right);
			switch (be.op)
			{
				case OP_BIT_AND:
				case OP_AND: return left && right;
				case OP_BIT_OR:
				case OP_OR: return left || right;
				default: return true;
			}
		case GROUP_EXPR:
			return feature_list_holds(features, caller, expr.as(GroupExpr).inner);
		default:
			return true;
	}
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
		bool holds;
		foreach (expr : attr.exprs) holds = holds || feature_list_holds(features, caller, expr);
		if (attr.exprs.len && !holds) return false;
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
			positive_features(ue.expr, negated != (ue.operator == UNARYOP_NOT), out);
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
		bool holds;
		foreach (expr : branch.expr_list) holds = holds || feature_list_holds(features, sf, expr);
		if (branch.expr_list.len && !holds) return false;
	}
	return true;
}

<*
 Features of the platform the code at `loc` in `sf` is written for: the
 target's when that code is compiled for it, else those of the first common
 c3c platform that compiles it, as macOS code seen on Linux. Features the
 code's `@feat`, and the `$if $feat`/`$case $feat` branches around it, ask
 for that no platform defines, such as WAYLAND, are assumed set, the target
 being tried first.
*>
fn String[] platform_features_at(AnalyzerContext* context, SourceFile* sf, Location loc)
{
	Node* code = enclosing_top_level(sf, loc);
	if (!code || code.kind == MODULE_DECL) code = section_node_at(sf, loc);
	if (!code) return context.features;
	List{CtFeatureExpr*} branches;
	branches.tinit();
	branch_features(sf, loc, &branches);
	if (code_holds(context, context.features, sf, code, branches.array_view())) return context.features;
	Target[*] platforms = {
		{ .os = LINUX, .arch = X86_64 }, { .os = MACOS, .arch = AARCH64 }, { .os = WIN32, .arch = X86_64 },
		{ .os = FREEBSD, .arch = X86_64 }, { .os = OPENBSD, .arch = X86_64 }, { .os = NETBSD, .arch = X86_64 },
		{ .os = IOS, .arch = AARCH64 }, { .os = ANDROID, .arch = AARCH64 }, { .os = EMSCRIPTEN, .arch = WASM32 },
		{ .os = WASI, .arch = WASM32 },
	};
	List{String} platform_defined;
	platform_defined.tinit();
	foreach (platform : platforms) platform_defined.push_all(arch::features(tmem, platform));
	List{AttributeDecl*} attrs;
	attrs.tinit();
	feat_attributes(context, code, &attrs);
	List{String} named;
	named.tinit();
	foreach (attr : attrs) foreach (expr : attr.exprs) positive_features(expr, false, &named);
	foreach (branch : branches) foreach (expr : branch.expr_list) positive_features(expr, false, &named);
	List{String} custom;
	custom.tinit();
	foreach (f : named) if (!array::contains(platform_defined.array_view(), f) && !array::contains(custom.array_view(), f)) custom.push(f);

	List{String} with_custom;
	with_custom.tinit();
	with_custom.push_all(context.features);
	with_custom.push_all(custom.array_view());
	if (custom.len() && code_holds(context, with_custom.array_view(), sf, code, branches.array_view())) return with_custom.array_view();
	foreach (assume : (bool[2]){ true, false })
	{
		foreach (platform : platforms)
		{
			List{String} features;
			features.tinit();
			features.push_all(arch::features(tmem, platform));
			if (assume) features.push_all(custom.array_view());
			if (code_holds(context, features.array_view(), sf, code, branches.array_view())) return features.array_view();
		}
	}
	return context.features;
}

<*
 Entries of the variant chain `head` best first for code at `loc` in `sf`:
 variants compiled for the platform that code is written for, then those
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
	String[] platform = platform_features_at(context, sf, loc);
	for (int rank = 2; rank >= 0; rank--)
	{
		for (var curr = head; curr; curr = curr.next)
		{
			if (variant_rank(context, sf, platform, curr.node) == rank) out.push(curr);
		}
	}
	return out.array_view();
}

fn int variant_rank(AnalyzerContext* context, SourceFile* sf, String[] platform, Node* node)
{
	if (!node) return 0;
	if (platform.ptr != context.features.ptr && feat_enabled_with(context, platform, sf, node)) return 2;
	return feat_enabled(context, sf, node) ? 1 : 0;
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
