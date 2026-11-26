module analyzer::sema::query;
import analyzer, std::collections::list;

<*
 Module section declaration of `sf` that contains `loc`, or null before the first one.
*>
fn Node*? section_node_at(SourceFile* sf, Location loc)
{
	sz index = section_at(sf, loc);
	return index >= 0 ? sf.ast.statements[sf.ast.module_decls[index]] : NOT_FOUND~;
}

<*
 Whether `decl` or its module section carries a `@feat`.
*>
fn bool has_feat(AnalyzerContext* context, Node* decl)
{
	return cursor::has_attribute(decl, FEAT, null) || (cursor::has_attribute(section_node_at(source_file::file_of(context, decl), decl.range.start), FEAT, null) ?? false);
}

<*
 The `@feat` attributes deciding whether `decl` is compiled: its own and its module section's.
*>
fn void feat_attributes(AnalyzerContext* context, Node* decl, List{AttributeDecl*}* out)
{
	Node*? section = section_node_at(source_file::file_of(context, decl), decl.range.start);
	if (try section && section != decl) push_feat_attributes(section, out);
	push_feat_attributes(decl, out);
}

fn void push_feat_attributes(Node* owner, List{AttributeDecl*}* out) @local
{
	foreach (attr : cursor::attributes(owner))
	{
		if (attr && attr.kind == ATTRIBUTE_DECL && attr.as(AttributeDecl).attribute_kind == FEAT) out.push(attr.as(AttributeDecl));
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
			if (@ok(ie.path_expr.get()) || !ie.ident.text.len || !ie.ident.text[0].is_upper() || !lexer::is_all_upper(ie.ident.text)) return NOT_A_FEATURE_LIST~;
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
	Node*? at = node_at(sf, loc);
	if (catch at) return;
	foreach (node : ancestors_of(sf, at))
	{
		switch (node.kind)
		{
			case CT_IF_STMT:
				CtIfStmt* ct_if = node.as(CtIfStmt);
				if (ct_if.expr.kind != CT_FEATURE_EXPR) break;
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
	// A module declaration stands for its section.
	Node*? code = enclosing_top_level(sf, loc);
	if (try top = code && top.kind == MODULE_DECL) code = NOT_FOUND~;
	code = code ?? section_node_at(sf, loc);
	List{CtFeatureExpr*} branches;
	branches.tinit();
	if (catch code)
	{
		sets.push(context.features);
		return sets.array_view();
	}
	branch_features(sf, loc, &branches);
	if (code_holds(context, context.features, sf, code, branches.array_view()))
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
 Whether `decl` is compiled for a platform the code at `loc` in `sf` is built
 for. `platforms` keeps the platform feature sets of that code once computed.
*>
fn bool compiled_for(AnalyzerContext* context, SourceFile* sf, Location loc, Node* decl, String[][]* platforms)
{
	if (!has_feat(context, decl)) return true;
	if (!platforms.len) *platforms = platform_feature_sets(context, sf, loc);
	return variant_rank(context, sf, *platforms, decl) > 0;
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
 Runs `body` for each declaration registered in `map` under `name`, following the entries' `next` chain.
*>
macro @each_declaration(#map, String name; @body(entry))
{
	for (var entry = #map.get(name) ?? ($Typeof(#map.get(name)!!))null; entry; entry = entry.next) @body(entry);
}

<*
 Every platform variant of `decl`: the declarations of the same name in its
 module, of the same kind, and for a method of the same receiver type. Adds
 nothing when `decl` has no other variant.
*>
fn void platform_variants(AnalyzerContext* context, Node* decl, List{Node*}* out)
{
	if (!context.registry || !decl) return;
	SourceFile*? sf = source_file::file_of(context, decl);
	if (catch sf) return;
	String name = cursor::spelling(decl, tmem);
	if (!name.len) return;
	String qname = string::tformat("%s::%s", get_module_name_at_location(sf, decl.range.start), name.strip_prefix("@"));
	List{Node*} found;
	found.tinit();
	if (try receiver = receiver_type_expr(decl))
	{
		String receiver_name = cursor::raw_type_identifier(receiver) ?? "";
		@each_declaration(context.registry.methods_by_type, method_key(receiver_name); MethodInfo* m)
		{
			if (m.node.kind == decl.kind && cursor::spelling(m.node, tmem) == name && (cursor::raw_type_identifier(receiver_type_expr(m.node)) ?? "") == receiver_name) found.push(m.node);
		};
	}
	else
	{
		switch (decl.kind)
		{
			case FN_DECL:
				@each_declaration(context.registry.functions, qname; FunctionInfo* f)
				{
					if (!@ok(receiver_type_expr(f.node))) found.push(f.node);
				};
			case MACRO_DECL:
				@each_declaration(context.registry.macros, qname; MacroInfo* f)
				{
					if (!@ok(receiver_type_expr(f.node))) found.push(f.node);
				};
			default:
				@each_declaration(context.registry.types, qname; TypeInfo* t)
				{
					if (t.node.kind == decl.kind) found.push(t.node);
				};
		}
	}
	if (found.len() > 1) out.push_all(found.array_view());
}

<*
 Whether every `@if` on the method `decl` holds for a receiver of type
 `target`, such as `List{int}`. A condition that cannot be evaluated holds.
*>
fn bool if_conditions_hold(AnalyzerContext* context, Node* decl, String target)
{
	CtCondition condition = { context, decl, ast::@nullable(generic_params(context, decl)), generic_args(target) };
	foreach (attr : cursor::attributes(decl))
	{
		if (!attr || attr.kind != ATTRIBUTE_DECL || attr.as(AttributeDecl).attribute_kind != IF) continue;
		foreach (expr : attr.as(AttributeDecl).exprs)
		{
			if (!(condition.value(expr, 0) ?? true)) return false;
		}
	}
	return true;
}

<*
 An `@if` condition of `decl`, with the generic parameters of `decl` bound to `args`.
*>
struct CtCondition
{
	AnalyzerContext* context;
	Node* decl;
	NullableGenerics params;
	String[] args;
}

<*
 Value of the condition `expr`: booleans, `!`, `&&`, `||`, constants of the
 module section of `decl` and `Type::kind` compared with a kind name.
*>
fn bool? CtCondition.value(&self, Node* expr, int depth)
{
	if (depth > MAX_ALIAS_DEPTH) return NOT_FOUND~;
	switch (expr.kind)
	{
		case LITERAL_EXPR:
			LiteralExpr* lit = expr.as(LiteralExpr);
			if (lit.literal_kind != BOOL_LITERAL) return NOT_FOUND~;
			return lit.boolean;
		case GROUP_EXPR:
			return self.value(expr.as(GroupExpr).inner, depth);
		case UNARY_EXPR:
			UnaryExpr* ue = expr.as(UnaryExpr);
			if (ue.operator != UNARYOP_NOT) return NOT_FOUND~;
			return !self.value(ue.expr, depth)!;
		case BINARY_EXPR:
			BinaryExpr* be = expr.as(BinaryExpr);
			switch (be.op)
			{
				case OP_AND:
				case OP_OR:
					// `true` decides `||` and `false` decides `&&`, even when the other side is unknown.
					bool decisive = be.op == OP_OR;
					bool? left = self.value(be.left, depth);
					bool? right = self.value(be.right, depth);
					if ((left ?? !decisive) == decisive || (right ?? !decisive) == decisive) return decisive;
					if (!@ok(left) || !@ok(right)) return NOT_FOUND~;
					return !decisive;
				case OP_EQ:
				case OP_NE:
					if (be.right.kind != IDENT_EXPR) return NOT_FOUND~;
					String kind = self.kind_of(be.left)!;
					return (kind == be.right.as(IdentExpr).ident.text) == (be.op == OP_EQ);
				default:
					return NOT_FOUND~;
			}
		case IDENT_EXPR:
			IdentExpr* ie = expr.as(IdentExpr);
			if (@ok(ie.path_expr.get())) return NOT_FOUND~;
			return self.value(self.constant(ie.ident.text)!, depth + 1);
		default:
			return NOT_FOUND~;
	}
}

<*
 `TypeKind` name of `T` in the condition `T::kind`.
*>
fn String? CtCondition.kind_of(&self, Node* expr)
{
	if (expr.kind != ACCESS_EXPR) return NOT_FOUND~;
	AccessExpr* acc = expr.as(AccessExpr);
	if (acc.access_kind != STATIC || acc.member.spelling() != "kind" || acc.left.kind != TYPE_EXPR) return NOT_FOUND~;
	return type_kind_name(self.context, substitute(cursor::instance_name(acc.left), self.params, self.args));
}

<*
 Value of the constant `name` declared in the module section of `decl`.
*>
fn Node*? CtCondition.constant(&self, String name)
{
	SourceFile* sf = source_file::file_of(self.context, self.decl)!;
	sz section = section_at(sf, self.decl.range.start);
	foreach (stmt : sf.ast.statements)
	{
		if (!stmt || stmt.kind != VAR_DECL || section_at(sf, stmt.range.start) != section) continue;
		VarDecl* vd = stmt.as(VarDecl);
		if (vd.var_flags.is_const && vd.name.is(name)) return vd.init_expr.get();
	}
	return NOT_FOUND~;
}

<*
 `TypeKind` name of `type`, as `Type::kind` gives it, when known.
*>
fn String? type_kind_name(AnalyzerContext* context, String type) @local
{
	switch
	{
		case type.ends_with("*"): return "POINTER";
		case type.ends_with("?"): return "OPTIONAL";
		case type.ends_with("[]"): return "SLICE";
		case type.ends_with(">]"): return "VECTOR";
		case type.ends_with("]"): return "ARRAY";
	}
	if (try primitive = PrimitiveType::lookup_field(name, type))
	{
		switch (primitive.kind)
		{
			case VOID: return "VOID";
			case BOOL: return "BOOL";
			case INT: return primitive.is_signed ? "SIGNED_INT" : "UNSIGNED_INT";
			case FLOAT: return "FLOAT";
			case SPECIAL:
				switch (type)
				{
					case "typeid": return "TYPEID";
					case "any": return "ANY";
					case "fault": return "FAULT";
					default: return NOT_FOUND~;
				}
			case COMPILE_TIME: return NOT_FOUND~;
		}
	}
	Node* decl = find_type_node_in_context(context, null, generic_base(type))!;
	switch (decl.kind)
	{
		case STRUCT_DECL:
			StructDecl* sd = decl.as(StructDecl);
			return sd.is_union ? "UNION" : sd.is_bitstruct ? "BITSTRUCT" : "STRUCT";
		case ENUM_DECL: return decl.as(EnumDecl).is_constdef ? "CONSTDEF" : "ENUM";
		case TYPEDEF_DECL: return "TYPEDEF";
		case INTERFACE_DECL: return "INTERFACE";
		default: return NOT_FOUND~;
	}
}
