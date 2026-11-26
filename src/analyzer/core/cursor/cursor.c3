module analyzer::cursor;
import analyzer, std::collections::list, std::io;

<*
 Name of the declaration `node`.
*>
fn Ident*? decl_name(Node* node)
{
	switch (node.kind)
	{
		case VAR_DECL: return node.as(VarDecl).name.get();
		case FN_DECL: return node.as(FnDecl).name.get();
		case MACRO_DECL: return node.as(MacroDecl).name.get();
		case STRUCT_DECL: return node.as(StructDecl).name.get();
		case ENUM_DECL: return node.as(EnumDecl).name.get();
		case TYPEDEF_DECL: return node.as(TypedefDecl).name.get();
		case ALIAS_DECL: return node.as(AliasDecl).name.get();
		case FAULT_DECL: return node.as(FaultDecl).name.get();
		case INTERFACE_DECL: return node.as(InterfaceDecl).name.get();
		case ATTRDEF_DECL: return node.as(AttrdefDecl).name.get();
		default: return NOT_FOUND~;
	}
}

<*
 Type whose fields and methods a struct takes through its inline member `vd`.
 Only a member of a plain or generic type gives them, not a pointer, array, slice or vector.
*>
fn String? inline_type(VarDecl* vd)
{
	if (!vd.var_flags.is_inline) return NOT_FOUND~;
	Node* type = vd.type.get()!;
	if (type.kind != TYPE_EXPR) return NOT_FOUND~;
	switch (type.as(TypeExpr).type_kind)
	{
		case TYPE_IDENTIFIER:
		case TYPE_GENERIC:
			return instance_name(type);
		default:
			return NOT_FOUND~;
	}
}

<*
 Spelling of the field's node, or "" when there is none.
*>
fn String NullableNode.spelling(self, Allocator allocator = tmem) => spelling(self.get(), allocator) ?? "";

<*
 Get the spelling/text for the current node. Always returns a valid String view.
*>
fn String spelling(Node* node, Allocator allocator = tmem)
{
	if (!node) return "";
	if (try name = decl_name(node)) return name.text;
	switch (node.kind)
	{
		case TYPE_EXPR:
			{
				TypeExpr* type_data = node.as(TypeExpr);
				switch (type_data.type_kind)
				{
				case TYPE_IDENTIFIER:
					{
						Ident*? name = type_data.unresolved.name.get();
						if (catch name) return "";
						String type_name = name.text;
						if (try prefix_path = type_data.unresolved.path.get())
						{
							String prefix_str = prefix_path.as(PathExpr).path.text;
							return string::format(allocator, "%s%s%s", prefix_str, type_name, type_data.optional ? "?" : "");
						}
						return type_data.optional ? string::format(allocator, "%s?", type_name) : type_name;
					}
				case TYPE_POINTER:
					{
						String base = spelling(type_data.modify.base, allocator);
						return string::format(allocator, "%s*%s", base, type_data.optional ? "?" : "");
					}
				case TYPE_SLICE:
					{
						String base = spelling(type_data.modify.base, allocator);
						return string::format(allocator, "%s[]%s", base, type_data.optional ? "?" : "");
					}
				case TYPE_ARRAY:
					{
						String base = spelling(type_data.array.base, allocator);
						String len = type_data.array.len_expr.spelling(allocator) ?: "*";
						return string::format(allocator, "%s[%s]%s", base, len, type_data.optional ? "?" : "");
					}
				case TYPE_VECTOR:
					{
						String base = spelling(type_data.array.base, allocator);
						String len = type_data.array.len_expr.spelling(allocator) ?: "*";
						return string::format(allocator, "%s[<%s>]%s", base, len, type_data.optional ? "?" : "");
					}
				case TYPE_GENERIC:
					{
						String base = spelling(type_data.generic.base, allocator);
						DString gen; gen.tinit();
						gen.appendf("%s{", base);
						foreach (i, p : type_data.generic.params)
						{
							if (i > 0) gen.append(", ");
							gen.append(spelling(p, allocator));
						}
						gen.append("}");
						if (type_data.optional) gen.append("?");
						return gen.str_view().copy(allocator);
					}
				case TYPE_TYPEOF:
					{
						String expr_str = spelling(type_data.expr, allocator);
						return string::format(allocator, "$Typeof(%s)", expr_str);
					}
				case TYPE_TYPEFROM:
					{
						String expr_str = spelling(type_data.expr, allocator);
						return string::format(allocator, "$Typefrom(%s)", expr_str);
					}
				case TYPE_FUNCTION:
					{
						String ret = spelling(type_data.func.ret_type, allocator) ?: "void";
						DString fn_str; fn_str.tinit();
						fn_str.appendf("fn %s(", ret);
						foreach (i, p : type_data.func.params)
						{
							if (i > 0) fn_str.append(", ");
							if (p && p.kind == VAR_DECL)
							{
								VarDecl* vd = p.as(VarDecl);
								String pt = vd.type.spelling(allocator);
								String pn = vd.name.text();
								if (pt.len > 0 && pn.len > 0)
								{
									fn_str.appendf("%s %s", pt, pn);
								}
								else if (pn.len > 0)
								{
									fn_str.append(pn);
								}
								else
								{
									fn_str.append(pt);
								}
							}
						}
						fn_str.append(")");
						return fn_str.str_view().copy(allocator);
					}
				default:
					return "";
			}
		}
		case IDENT_EXPR:
			{
				IdentExpr* ident = node.as(IdentExpr);
				return ident.ident.text;
			}
		case LITERAL_EXPR:
			{
				LiteralExpr* lit = node.as(LiteralExpr);
				switch (lit.literal_kind)
				{
				case INT_LITERAL:
					return string::format(allocator, "%d", lit.integer);
				case REAL_LITERAL:
					return (lit.real == (double)(long)lit.real)
					? string::format(allocator, "%.1f", lit.real)
					: string::format(allocator, "%g", lit.real);
				case STRING_LITERAL:
					return string::format(allocator, "\"%s\"", lit.string);
				case BOOL_LITERAL:
					return lit.boolean ? "true" : "false";
				case NULL_LITERAL:
					return "null";
				default:
					return "";
			}
		}
		case TRY_EXPR:
			{
				TryExpr* te = node.as(TryExpr);
				if (te.variable.kind == IDENT_EXPR)
				{
					IdentExpr* ie = te.variable.as(IdentExpr);
					return ie.ident.text;
				}
				return "";
			}
		case CATCH_EXPR:
			{
				CatchExpr* ce = node.as(CatchExpr);
				if (try variable = ce.variable.get() && variable.kind == IDENT_EXPR) return variable.as(IdentExpr).ident.text;
				return "";
			}
		case ATTRIBUTE_DECL:
			{
				AttributeDecl* ad = node.as(AttributeDecl);
				return ad.name.text();
			}
		default:
			return "";
	}
}

<*
 Attributes written on `node`, or none.
*>
fn NodeArray attributes(Node* node)
{
	if (!node) return {};
	switch (node.kind)
	{
		case STRUCT_DECL: return node.as(StructDecl).attributes;
		case INTERFACE_DECL: return node.as(InterfaceDecl).attributes;
		case FN_DECL: return node.as(FnDecl).attributes;
		case IMPORT_DECL: return node.as(ImportDecl).attributes;
		case PATH_EXPR: return node.as(PathExpr).attributes;
		case MACRO_DECL: return node.as(MacroDecl).attributes;
		case VAR_DECL: return node.as(VarDecl).attributes;
		case ENUM_DECL: return node.as(EnumDecl).attributes;
		case FAULT_DECL: return node.as(FaultDecl).attributes;
		case ALIAS_DECL: return node.as(AliasDecl).attributes;
		case TYPEDEF_DECL: return node.as(TypedefDecl).attributes;
		case ATTRDEF_DECL: return node.as(AttrdefDecl).attributes;
		case MODULE_DECL: return node.as(ModuleDecl).attributes;
		case CT_EXPAND_DECL: return node.as(CtExpandDecl).attributes;
		case SWITCH_STMT: return node.as(SwitchStmt).attributes;
		case CALL_EXPR: return node.as(CallExpr).attributes;
		case LAMBDA_EXPR: return node.as(LambdaExpr).attributes;
		default: return {};
	}
}

<*
 Whether `node` has an attribute of `kind`, stored in `out_attribute` when given.
*>
fn bool has_attribute(Node* node, AttributeKind kind, Node** out_attribute)
{
	foreach (attr : attributes(node))
	{
		if (!attr || attr.kind != ATTRIBUTE_DECL || attr.as(AttributeDecl).attribute_kind != kind) continue;
		if (out_attribute) *out_attribute = attr;
		return true;
	}
	return false;
}

<*
 Type `node` names, with generic arguments, pointers and array, slice and
 vector suffixes, without optional: `List{Timer}[]*?` is `List{Timer}[]*`.
 Types that are not named, such as `$Typeof(x)`, are spelled as written.
*>
fn String instance_name(Node* node)
{
	DString out;
	out.tinit();
	append_type(&out, node);
	return out.str_view();
}

fn void append_type(DString* out, Node* node) @local
{
	if (!node) return;
	if (node.kind != TYPE_EXPR)
	{
		out.append(spelling(node, tmem));
		return;
	}
	TypeExpr* te = node.as(TypeExpr);
	switch (te.type_kind)
	{
		case TYPE_IDENTIFIER:
			if (try name = te.unresolved.name.get()) out.append(name.text);
		case TYPE_POINTER:
			append_type(out, te.modify.base);
			out.append('*');
		case TYPE_SLICE:
			append_type(out, te.modify.base);
			out.append("[]");
		case TYPE_ARRAY:
			append_type(out, te.array.base);
			out.appendf("[%s]", te.array.len_expr.spelling(tmem) ?: "*");
		case TYPE_VECTOR:
			append_type(out, te.array.base);
			out.appendf("[<%s>]", te.array.len_expr.spelling(tmem) ?: "*");
		case TYPE_GENERIC:
			append_type(out, te.generic.base);
			out.append('{');
			foreach (i, arg : te.generic.params)
			{
				if (i > 0) out.append(", ");
				out.append(spelling(arg, tmem));
			}
			out.append('}');
		case TYPE_TYPEOF:
		case TYPE_TYPEFROM:
		case TYPE_FUNCTION:
			out.append(spelling(node, tmem));
	}
}

<*
 Extracts the raw, un-prefixed identifier string from a TYPE_EXPR node.
 Example: 'List*' -> 'List'
*>
fn String? raw_type_identifier(Node* node)
{
	if (!node || node.kind != TYPE_EXPR) return NOT_FOUND~;

	Node* current = node;

	while (current && current.kind == TYPE_EXPR)
	{
		TypeExpr* data = current.as(TypeExpr);

		switch (data.type_kind)
		{
			case TYPE_IDENTIFIER:
				{
					return data.unresolved.name.text();
				}
			case TYPE_POINTER:
			case TYPE_SLICE:
				current = data.modify.base;
				break;
			case TYPE_ARRAY:
			case TYPE_VECTOR:
				current = data.array.base;
				break;
			case TYPE_GENERIC:
				current = data.generic.base;
				break;
			default:
				current = null;
				break;
		}
	}

	return NOT_FOUND~;
}

struct FindAtContext
{
	Range target;
	Node* best_match;
	int best_span;
}

fn ChildVisitResult find_at_callback(Node* cursor, Node* parent, void* user_data)
{
	if (!cursor || cursor.kind == ERROR) return CONTINUE;

	FindAtContext* ctx = (FindAtContext*)user_data;
	Node* node = cursor;

	if (node.range.contains_range(ctx.target))
	{
		int current_span = (node.range.end.line - node.range.start.line) * 1000 +
		(node.range.end.column - node.range.start.column);

		if (ctx.best_match == null || current_span <= ctx.best_span)
		{
			ctx.best_match = cursor;
			ctx.best_span = current_span;
		}

		return RECURSE;
	}

	return CONTINUE;
}

fn Node*? find_at(Node*[] slice, Range range)
{
	FindAtContext ctx = {
		.target = range,
		.best_match = {},
		.best_span = 99999999
	};

	foreach (node : slice)
	{
		if (!node || node.kind == ERROR) continue;
		Node* root_cursor = node;

		if (!visit(root_cursor, {}, {.on_enter = &find_at_callback }, &ctx))
		{
			break;
		}
	}

	return ctx.best_match ?: NOT_FOUND~;
}

fn Node*? contract(Node* node)
{
	if (!node) return NOT_FOUND~;
	switch (node.kind)
	{
		case MODULE_DECL:
			{
				ModuleDecl* decl = node.as(ModuleDecl);
				if (try val = decl.contract.get())
				{
					return val;
				}
			}
		case FN_DECL:
			{
				FnDecl* decl = node.as(FnDecl);
				if (try val = decl.contract.get())
				{
					return val;
				}
			}
		case MACRO_DECL:
			{
				MacroDecl* decl = node.as(MacroDecl);
				if (try val = decl.contract.get())
				{
					return val;
				}
			}
		case STRUCT_DECL:
			{
				StructDecl* decl = node.as(StructDecl);
				if (try val = decl.contract.get())
				{
					return val;
				}
			}
		case INTERFACE_DECL:
			{
				InterfaceDecl* decl = node.as(InterfaceDecl);
				if (try val = decl.contract.get())
				{
					return val;
				}
			}
		case VAR_DECL:
			{
				VarDecl* decl = node.as(VarDecl);
				if (try val = decl.contract.get())
				{
					return val;
				}
			}
		case FAULTDEF_DECL:
			{
				FaultdefDecl* decl = node.as(FaultdefDecl);
				if (try val = decl.contract.get())
				{
					return val;
				}
			}
		case FAULT_DECL:
			{
				FaultDecl* decl = node.as(FaultDecl);
				if (try val = decl.contract.get()) return val;
			}
		case ENUM_DECL:
			{
				EnumDecl* decl = node.as(EnumDecl);
				if (try val = decl.contract.get()) return val;
			}
		case ALIAS_DECL:
			{
				AliasDecl* decl = node.as(AliasDecl);
				if (try val = decl.contract.get()) return val;
			}
		case TYPEDEF_DECL:
			{
				TypedefDecl* decl = node.as(TypedefDecl);
				if (try val = decl.contract.get()) return val;
			}
		default:
			break;
	}

	return NOT_FOUND~;
}

fn String? docs(Node* node)
{
	if (!node) return "";

	if (try val = contract(node))
	{
		if (val.kind == CONTRACT_DECL)
		{
			ContractDecl* cdecl = val.as(ContractDecl);
			if (try comment = cdecl.comment.get())
			{
				return comment.text;
			}
		}
	}

	return "";
}

fn Node*? find_member_in_type(Node* node, String name)
{
	if (!node) return NOT_FOUND~;
	switch (node.kind)
	{
		case STRUCT_DECL:
			{
				StructDecl* sd = node.as(StructDecl);
				foreach (field : sd.fields)
				{
					if (!field) continue;
					if (field.kind == VAR_DECL)
					{
						VarDecl* vd = field.as(VarDecl);
						while (vd != null)
						{
							if (vd.name.is(name)) return (Node*)vd;
							vd = vd.next ? vd.next.as(VarDecl) : null;
						}
					}
					else if (field.kind == STRUCT_DECL)
					{
						StructDecl* sub = field.as(StructDecl);
						if (try sub_name = sub.name.get())
						{
							if (sub_name.text == name) return field;
						}
						else if (try nested = find_member_in_type(field, name))
						{
							return nested;
						}
					}
				}
				return NOT_FOUND~;
			}
		case ENUM_DECL:
			{
				EnumDecl* decl = node.as(EnumDecl);
				foreach (variant : decl.variants)
				{
					if (!variant || variant.kind != VAR_DECL) continue;
					VarDecl* vd = variant.as(VarDecl);
					if (vd.name.is(name))
					{
						return variant;
					}
				}
				foreach (param : decl.assoc_params)
				{
					if (!param || param.kind != VAR_DECL) continue;
					VarDecl* vd = param.as(VarDecl);
					if (vd.name.is(name))
					{
						return param;
					}
				}
				return NOT_FOUND~;
			}
		default:
			return NOT_FOUND~;
	}
}
