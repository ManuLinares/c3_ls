module analyzer::cursor;
import analyzer::core;
import analyzer::sema;

import std::collections::list;
import std::io;

faultdef
INVALID_NODE,
UNEXPECTED_KIND,
NOT_FOUND
;
<*
 Get the spelling/text for the current node. Always returns a valid String view.
*>
fn String spelling(Node* node, Allocator allocator = tmem)
{
	if (!node) return "";
	switch (node.kind)
	{
		case STRUCT_DECL:
			{
				StructDecl* s = node.as(StructDecl);
				return s.name ? s.name.text : "";
			}
		case ENUM_DECL:
			{
				EnumDecl* ed = node.as(EnumDecl);
				return ed.name ? ed.name.text : "";
			}
		case VAR_DECL:
			{
				VarDecl* v = node.as(VarDecl);
				return v.name ? v.name.text : "";
			}
		case FN_DECL:
			{
				FnDecl* func = node.as(FnDecl);
				return func.name ? func.name.text : "";
			}
		case MACRO_DECL:
			{
				MacroDecl* mac = node.as(MacroDecl);
				return mac.name ? mac.name.text : "";
			}
		case TYPEDEF_DECL:
			{
				TypedefDecl* td = node.as(TypedefDecl);
				return td.name ? td.name.text : "";
			}
		case ALIAS_DECL:
			{
				AliasDecl* ad = node.as(AliasDecl);
				return ad.name ? ad.name.text : "";
			}
		case INTERFACE_DECL:
			{
				InterfaceDecl* id = node.as(InterfaceDecl);
				return id.name ? id.name.text : "";
			}
		case TYPE_EXPR:
			{
				TypeExpr* type_data = node.as(TypeExpr);
				switch (type_data.type_kind)
				{
				case TYPE_IDENTIFIER:
					{
						if (!type_data.unresolved.name) return "";
						String type_name = type_data.unresolved.name.text;
						if (type_data.unresolved.path != null)
						{
							PathExpr* prefix_path = type_data.unresolved.path.as(PathExpr);
							String prefix_str     = (prefix_path && prefix_path.path) ? prefix_path.path.text : "";
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
						String len = type_data.array.len_expr ? spelling(type_data.array.len_expr, allocator) : "*";
						return string::format(allocator, "%s[%s]%s", base, len, type_data.optional ? "?" : "");
					}
				case TYPE_VECTOR:
					{
						String base = spelling(type_data.array.base, allocator);
						String len = type_data.array.len_expr ? spelling(type_data.array.len_expr, allocator) : "*";
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
								String pt = vd.type ? spelling(vd.type, allocator) : "";
								String pn = vd.name ? vd.name.text : "";
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
				return ident.ident ? ident.ident.text : "";
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
				if (te.variable && te.variable.kind == IDENT_EXPR)
				{
					IdentExpr* ie = te.variable.as(IdentExpr);
					return ie.ident ? ie.ident.text : "";
				}
				return "";
			}
		case CATCH_EXPR:
			{
				CatchExpr* ce = node.as(CatchExpr);
				if (ce.variable && ce.variable.kind == IDENT_EXPR)
				{
					IdentExpr* ie = ce.variable.as(IdentExpr);
					return ie.ident ? ie.ident.text : "";
				}
				return "";
			}
		case ATTRIBUTE_DECL:
			{
				AttributeDecl* ad = node.as(AttributeDecl);
				return ad.name ? ad.name.text : "";
			}
		default:
			return "";
	}
}

<*
 Checks if cursor has a specific attribute
*>
fn bool has_attribute(Node* node, AttributeKind kind, Node**out_attribute)
{
	if (!node) return false;
	NodeArray temp;
	switch (node.kind)
	{
		case STRUCT_DECL:
			StructDecl* s = node.as(StructDecl);
			temp = s.attributes;
			break;
		case INTERFACE_DECL:
			InterfaceDecl* inter = node.as(InterfaceDecl);
			temp = inter.attributes;
			break;
		case FN_DECL:
			FnDecl* func = node.as(FnDecl);
			temp = func.attributes;
			break;
		default:
			return false;
	}

	foreach (attr : temp)
	{
		if (!attr || attr.kind != ATTRIBUTE_DECL) continue;
		AttributeDecl* attr_decl = attr.as(AttributeDecl);
		if (attr_decl.attribute_kind == kind)
		{
			if (out_attribute)
			{
				*out_attribute = attr;
			}

			return true;
		}
	}

	return false;
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
					if (!data.unresolved.name) return "";
					return data.unresolved.name.text;
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

fn Node* find_at(Node*[] slice, Range range)
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

	return ctx.best_match;
}

fn Node*? contract(Node* node)
{
	if (!node) return null;
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
		case ENUM_DECL:
			{
				EnumDecl* decl = node.as(EnumDecl);
				if (try val = decl.contract.get()) return val;
			}
		default:
			break;
	}

	return null;
}

fn String? docs(Node* node)
{
	if (!node) return "";

	if (try val = contract(node) && val)
	{
		if (val.kind == CONTRACT_DECL)
		{
			ContractDecl* cdecl = val.as(ContractDecl);
			if (cdecl.comment)
			{
				return cdecl.comment.text;
			}
		}
	}

	return "";
}

fn Node* find_member_in_type(Node* node, String name)
{
	if (!node) return null;
	switch (node.kind)
	{
		case STRUCT_DECL:
			{
				StructDecl* current_st = node.as(StructDecl);
				while (current_st != null)
				{
					foreach (field : current_st.fields)
					{
						if (!field) continue;
						if (field.kind == VAR_DECL)
						{
							VarDecl* vd = field.as(VarDecl);
							while (vd != null)
							{
								if (vd.name && vd.name.text == name)
								{
									return (Node*)vd;
								}
								vd = vd.next ? vd.next.as(VarDecl) : null;
							}
						}
						else if (field.kind == STRUCT_DECL)
						{
							Node* nested = find_member_in_type(field, name);
							if (nested) return nested;
						}
					}
					current_st = current_st.next ? current_st.next.as(StructDecl) : null;
				}
				return null;
			}
		case ENUM_DECL:
			{
				EnumDecl* decl = node.as(EnumDecl);
				foreach (variant : decl.variants)
				{
					if (!variant || variant.kind != VAR_DECL) continue;
					VarDecl* vd = variant.as(VarDecl);
					if (vd.name && vd.name.text == name)
					{
						return variant;
					}
				}
				return null;
			}
		default:
			return null;
	}
}

fn Node* get_type(Node* node)
{
	if (!node) return null;
	switch (node.kind)
	{
		case STRUCT_DECL:
			StructDecl* decl = node.as(StructDecl);
			return decl.type;
		case FN_DECL:
			FnDecl* decl = node.as(FnDecl);
			return decl.associated_type == null ? decl.ret_type : decl.associated_type;
		case ENUM_DECL:
			EnumDecl* decl = node.as(EnumDecl);
			return decl.backing_type;
		case VAR_DECL:
			VarDecl* decl = node.as(VarDecl);
			return decl.type;
		default:
			return null;
	}
}