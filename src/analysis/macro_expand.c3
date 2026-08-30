module lsp::analysis::macro_expand;

import analyzer::core;
import analyzer::core::ast;
import analyzer::cursor;
import analyzer::sema::lookup;
import analyzer::sema::query;
import lsp::analysis;

import std::collections::list;
import std::collections::map;
import std::io;

struct MacroSubstitutions
{
	HashMap{String, String} params;
	String body_block;
}

<*
 Extracts the exact source text of a node from the SourceFile buffer.
*>
fn String get_node_source_text(SourceFile* sf, Node* node)
{
	if (!sf || !node) return "";
	if (node.range.start.line < 0 || node.range.end.line < 0) return cursor::spelling(node, tmem);

	sz start_off = analysis::compute_byte_offset(sf.content, (uint)node.range.start.line, (uint)node.range.start.column);
	sz end_off = analysis::compute_byte_offset(sf.content, (uint)node.range.end.line, (uint)node.range.end.column);

	if (start_off < end_off && end_off <= sf.content.len)
	{
		return sf.content[start_off : end_off - start_off].trim();
	}
	return cursor::spelling(node, tmem);
}

fn String binary_op_to_string(OperatorKind op)
{
	switch (op)
	{
		case OP_ADD: return "+";
		case OP_SUB: return "-";
		case OP_MULT: return "*";
		case OP_DIV: return "/";
		case OP_MOD: return "%";
		case OP_SHL: return "<<";
		case OP_SHR: return ">>";
		case OP_BIT_AND: return "&";
		case OP_BIT_OR: return "|";
		case OP_BIT_XOR: return "^";
		case OP_AND: return "&&";
		case OP_OR: return "||";
		case OP_ASSIGN: return "=";
		case OP_ADD_ASSIGN: return "+=";
		case OP_SUB_ASSIGN: return "-=";
		case OP_MULT_ASSIGN: return "*=";
		case OP_DIV_ASSIGN: return "/=";
		case OP_MOD_ASSIGN: return "%=";
		case OP_BIT_AND_ASSIGN: return "&=";
		case OP_BIT_OR_ASSIGN: return "|=";
		case OP_BIT_XOR_ASSIGN: return "^=";
		case OP_SHL_ASSIGN: return "<<=";
		case OP_SHR_ASSIGN: return ">>=";
		case OP_EQ: return "==";
		case OP_NE: return "!=";
		case OP_LT: return "<";
		case OP_LE: return "<=";
		case OP_GT: return ">";
		case OP_GE: return ">=";
		case OP_ELSE: return "??";
		case OP_ELVIS: return "?:";
		case OP_CT_CONCAT: return "+++";
		case OP_CT_CONCAT_ASSIGN: return "+++=";
		case OP_CT_AND: return "&&&";
		case OP_CT_OR: return "|||";
		default: return "";
	}
}

fn String unary_op_to_string(UnaryOpKind op)
{
	switch (op)
	{
		case UNARYOP_NOT: return "!";
		case UNARYOP_BITNEG: return "~";
		case UNARYOP_NEG: return "-";
		case UNARYOP_PLUS: return "+";
		case UNARYOP_ADDR: return "&";
		case UNARYOP_TADDR: return "&&";
		case UNARYOP_DEREF: return "*";
		case UNARYOP_INC: return "++";
		case UNARYOP_DEC: return "--";
		default: return "";
	}
}

fn void append_indent(DString* out, int indent)
{
	for (int i = 0; i < indent; i++)
	{
		out.append("  ");
	}
}

<*
 Recursively formats an AST node with macro parameter substitutions.
*>
fn void format_node_with_substitutions(DString* out, Node* node, MacroSubstitutions* subs, int indent = 0)
{
	if (!node || node.kind == ERROR) return;

	switch (node.kind)
	{
		case COMPOUND_STMT:
			{
				CompoundStmt* comp = node.as(CompoundStmt);
				out.append("{\n");
				foreach (stmt : comp.statements)
				{
					append_indent(out, indent + 1);
					format_node_with_substitutions(out, stmt, subs, indent + 1);
					out.append("\n");
				}
				append_indent(out, indent);
				out.append("}");
			}

		case EXPR_STMT:
			{
				ExprStmt* ex = node.as(ExprStmt);
				format_node_with_substitutions(out, ex.expr_stmt, subs, indent);
				out.append(";");
			}

		case RETURN_STMT:
			{
				ReturnStmt* ret = node.as(ReturnStmt);
				if (ret.expr)
				{
					out.append("return ");
					format_node_with_substitutions(out, ret.expr, subs, indent);
					out.append(";");
				}
				else
				{
					out.append("return;");
				}
			}

		case IF_STMT:
			{
				IfStmt* if_st = node.as(IfStmt);
				out.append("if (");
				format_node_with_substitutions(out, if_st.condition, subs, indent);
				out.append(") ");
				format_node_with_substitutions(out, if_st.then_body, subs, indent);
				if (if_st.else_body)
				{
					out.append(" else ");
					format_node_with_substitutions(out, if_st.else_body, subs, indent);
				}
			}

		case CT_IF_STMT:
			{
				CtIfStmt* ct_if = node.as(CtIfStmt);
				out.append("$if ");
				format_node_with_substitutions(out, ct_if.expr, subs, indent);
				out.append(":\n");
				foreach (stmt : ct_if.then_stmts)
				{
					append_indent(out, indent + 1);
					format_node_with_substitutions(out, stmt, subs, indent + 1);
					out.append("\n");
				}
				if (ct_if.else_stmts.len > 0)
				{
					append_indent(out, indent);
					out.append("$else\n");
					foreach (stmt : ct_if.else_stmts)
					{
						append_indent(out, indent + 1);
						format_node_with_substitutions(out, stmt, subs, indent + 1);
						out.append("\n");
					}
				}
				append_indent(out, indent);
				out.append("$endif");
			}

		case FOR_STMT:
			{
				ForStmt* fs = node.as(ForStmt);
				out.append("for (");
				if (try init_node = fs.init.get())
				{
					DString init_str;
					init_str.tinit();
					format_node_with_substitutions(&init_str, init_node, subs, indent);
					out.append(init_str.str_view().strip_suffix(";"));
				}
				out.append("; ");
				if (try cond_node = fs.cond.get())
				{
					DString cond_str;
					cond_str.tinit();
					format_node_with_substitutions(&cond_str, cond_node, subs, indent);
					out.append(cond_str.str_view().strip_suffix(";"));
				}
				out.append("; ");
				if (try incr_node = fs.incr.get())
				{
					DString incr_str;
					incr_str.tinit();
					format_node_with_substitutions(&incr_str, incr_node, subs, indent);
					out.append(incr_str.str_view().strip_suffix(";"));
				}
				out.append(") ");
				if (fs.body)
				{
					format_node_with_substitutions(out, fs.body, subs, indent);
				}
			}

		case CT_FOR_STMT:
			{
				CtForStmt* ct_for = node.as(CtForStmt);
				out.append("$for ");
				if (try init_node = ct_for.init.get())
				{
					DString s; s.tinit();
					format_node_with_substitutions(&s, init_node, subs, indent);
					out.append(s.str_view().strip_suffix(";"));
				}
				out.append("; ");
				if (ct_for.cond)
				{
					DString s; s.tinit();
					format_node_with_substitutions(&s, ct_for.cond, subs, indent);
					out.append(s.str_view().strip_suffix(";"));
				}
				out.append("; ");
				if (try incr_node = ct_for.incr.get())
				{
					DString s; s.tinit();
					format_node_with_substitutions(&s, incr_node, subs, indent);
					out.append(s.str_view().strip_suffix(";"));
				}
				out.append(":\n");
				if (ct_for.body)
				{
					format_node_with_substitutions(out, ct_for.body, subs, indent + 1);
					out.append("\n");
				}
				append_indent(out, indent);
				out.append("$endfor");
			}

		case CT_FOREACH_STMT:
			{
				CtForeachStmt* ct_fe = node.as(CtForeachStmt);
				out.append("$foreach ");
				if (ct_fe.index)
				{
					format_node_with_substitutions(out, ct_fe.index, subs, indent);
					out.append(", ");
				}
				if (ct_fe.value)
				{
					format_node_with_substitutions(out, ct_fe.value, subs, indent);
				}
				out.append(" : ");
				format_node_with_substitutions(out, ct_fe.expr, subs, indent);
				out.append(":\n");
				if (ct_fe.body)
				{
					format_node_with_substitutions(out, ct_fe.body, subs, indent + 1);
					out.append("\n");
				}
				append_indent(out, indent);
				out.append("$endforeach");
			}

		case WHILE_STMT:
			{
				WhileStmt* ws = node.as(WhileStmt);
				out.append("while (");
				if (ws.cond)
				{
					format_node_with_substitutions(out, ws.cond, subs, indent);
				}
				out.append(") ");
				if (ws.body)
				{
					format_node_with_substitutions(out, ws.body, subs, indent);
				}
			}

		case SWITCH_STMT:
			{
				SwitchStmt* sw = node.as(SwitchStmt);
				out.append("switch (");
				if (sw.cond) format_node_with_substitutions(out, sw.cond, subs, indent);
				out.append(") {\n");
				foreach (c : sw.cases)
				{
					append_indent(out, indent + 1);
					format_node_with_substitutions(out, c, subs, indent + 1);
					out.append("\n");
				}
				append_indent(out, indent);
				out.append("}");
			}

		case CT_SWITCH_STMT:
			{
				CtSwitchStmt* sw = node.as(CtSwitchStmt);
				out.append("$switch");
				if (sw.cond)
				{
					out.append(" ");
					format_node_with_substitutions(out, sw.cond, subs, indent);
				}
				out.append(":\n");
				foreach (c : sw.cases)
				{
					append_indent(out, indent + 1);
					format_node_with_substitutions(out, c, subs, indent + 1);
					out.append("\n");
				}
				append_indent(out, indent);
				out.append("$endswitch");
			}

		case CASE_STMT:
			{
				CaseStmt* cs = node.as(CaseStmt);
				out.append("case ");
				format_node_with_substitutions(out, cs.expr, subs, indent);
				if (cs.to_expr)
				{
					out.append(" .. ");
					format_node_with_substitutions(out, cs.to_expr, subs, indent);
				}
				out.append(":\n");
				if (cs.body)
				{
					format_node_with_substitutions(out, cs.body, subs, indent + 1);
				}
			}

		case DEFAULT_STMT:
			{
				DefaultStmt* ds = node.as(DefaultStmt);
				out.append("default:\n");
				if (ds.body)
				{
					format_node_with_substitutions(out, ds.body, subs, indent + 1);
				}
			}

		case DEFER_STMT:
			{
				DeferStmt* ds = node.as(DeferStmt);
				out.append("defer ");
				if (ds.body) format_node_with_substitutions(out, ds.body, subs, indent);
			}

		case EXPR_LIST:
			{
				ExprList* el = node.as(ExprList);
				foreach (i, e : el.exprs)
				{
					if (i > 0) out.append(", ");
					format_node_with_substitutions(out, e, subs, indent);
				}
			}

		case COND_EXPR:
			{
				CondExpr* ce = node.as(CondExpr);
				foreach (i, e : ce.exprs)
				{
					if (i > 0) out.append(", ");
					format_node_with_substitutions(out, e, subs, indent);
				}
			}

		case VAR_DECL:
			{
				VarDecl* vd = node.as(VarDecl);
				String vtype = vd.type ? cursor::spelling(vd.type, tmem) : (vd.var_flags.is_const ? "const" : "var");
				if (vd.var_flags.is_const && vd.type) out.append("const ");
				if (vtype.len > 0)
				{
					out.append(vtype);
					out.append(" ");
				}
				String vname = vd.name ? vd.name.text : "";
				if (try rep = subs.params.get(vname))
				{
					out.append(rep);
				}
				else
				{
					out.append(vname);
				}
				if (vd.init_expr)
				{
					out.append(" = ");
					format_node_with_substitutions(out, vd.init_expr, subs, indent);
				}
				out.append(";");
			}

		case BINARY_EXPR:
			{
				BinaryExpr* bin = node.as(BinaryExpr);
				format_node_with_substitutions(out, bin.left, subs, indent);
				out.appendf(" %s ", binary_op_to_string(bin.op));
				format_node_with_substitutions(out, bin.right, subs, indent);
			}

		case UNARY_EXPR:
			{
				UnaryExpr* un = node.as(UnaryExpr);
				out.append(unary_op_to_string(un.operator));
				format_node_with_substitutions(out, un.expr, subs, indent);
			}

		case POST_UNARY_EXPR:
			{
				PostUnaryExpr* post = node.as(PostUnaryExpr);
				format_node_with_substitutions(out, post.unary.expr, subs, indent);
				out.append(unary_op_to_string(post.unary.operator));
			}

		case IDENT_EXPR:
			{
				IdentExpr* ie = node.as(IdentExpr);
				String name = ie.ident ? ie.ident.text : "";
				String stripped = (name.starts_with("#") || name.starts_with("$")) ? name[1..] : name;

				if (try rep = subs.params.get(name))
				{
					out.append(rep);
				}
				else if (try rep = subs.params.get(stripped))
				{
					out.append(rep);
				}
				else
				{
					out.append(name);
				}
			}

		case BUILTIN_EXPR:
			{
				BuiltinExpr* be = node.as(BuiltinExpr);
				out.appendf("$$%s", be.name ? be.name.text : "");
			}

		case COMPILER_CONST_EXPR:
			{
				CompilerConstExpr* cce = node.as(CompilerConstExpr);
				out.appendf("$$%s", cce.expr.name ? cce.expr.name.text : "");
			}

		case CALL_EXPR:
			{
				CallExpr* call = node.as(CallExpr);
				String callee_name = call.callee ? cursor::spelling(call.callee, tmem) : "";
				if ((callee_name == "@body" || callee_name == "body") && subs.body_block.len > 0)
				{
					out.append(subs.body_block);
					return;
				}

				format_node_with_substitutions(out, call.callee, subs, indent);
				out.append("(");
				foreach (i, arg : call.args)
				{
					if (i > 0) out.append(", ");
					format_node_with_substitutions(out, arg, subs, indent);
				}
				out.append(")");
			}

		case ACCESS_EXPR:
			{
				AccessExpr* acc = node.as(AccessExpr);
				format_node_with_substitutions(out, acc.left, subs, indent);
				out.append(acc.access_kind == STATIC ? "::" : ".");
				format_node_with_substitutions(out, acc.member, subs, indent);
			}

		case LITERAL_EXPR:
			{
				LiteralExpr* lit = node.as(LiteralExpr);
				switch (lit.literal_kind)
				{
				case INT_LITERAL:
					out.appendf("%d", lit.integer);
				case REAL_LITERAL:
					out.appendf("%f", lit.real);
				case STRING_LITERAL:
					out.appendf("\"%s\"", lit.string);
				case BOOL_LITERAL:
					out.append(lit.boolean ? "true" : "false");
				case NULL_LITERAL:
					out.append("null");
				case BYTES_LITERAL:
					out.append("<bytes>");
			}
		}

		case GROUP_EXPR:
			{
				GroupExpr* grp = node.as(GroupExpr);
				out.append("(");
				format_node_with_substitutions(out, grp.inner, subs, indent);
				out.append(")");
			}

		case CAST_EXPR:
			{
				CastExpr* cst = node.as(CastExpr);
				out.append("(");
				format_node_with_substitutions(out, cst.inner, subs, indent);
				out.append(")");
				format_node_with_substitutions(out, cst.operand, subs, indent);
			}

		case TERNARY_EXPR:
			{
				TernaryExpr* ter = node.as(TernaryExpr);
				format_node_with_substitutions(out, ter.cond, subs, indent);
				out.append(" ? ");
				format_node_with_substitutions(out, ter.then_expr, subs, indent);
				out.append(" : ");
				format_node_with_substitutions(out, ter.else_expr, subs, indent);
			}

		case INITIALIZER_LIST_EXPR:
			{
				InitializerListExpr* init = node.as(InitializerListExpr);
				out.append("{ ");
				foreach (i, expr : init.exprs)
				{
					if (i > 0) out.append(", ");
					format_node_with_substitutions(out, expr, subs, indent);
				}
				out.append(" }");
			}

		case TYPE_EXPR:
			{
				out.append(cursor::spelling(node, tmem));
			}

		default:
			{
				out.append(cursor::spelling(node, tmem));
			}
	}
}

<*
 Expands a macro invocation given its call site and declaration node.
*>
fn String expand_macro(AnalyzerContext* ctx, SourceFile* sf, CallExpr* call, MacroDecl* mac)
{
	if (!call || !mac || !mac.body) return "";

	MacroSubstitutions subs;
	subs.params.tinit();

	for (sz i = 0; i < mac.params.len; i++)
	{
		Node* p = mac.params[i];
		if (!p || p.kind != VAR_DECL) continue;
		VarDecl* vd = p.as(VarDecl);
		String pname = vd.name ? vd.name.text : "";
		if (pname.len == 0) continue;

		String arg_text = "";
		if (i < call.args.len)
		{
			arg_text = get_node_source_text(sf, call.args[i]);
		}
		else if (vd.init_expr)
		{
			arg_text = get_node_source_text(sf, vd.init_expr);
		}

		subs.params.set(pname, arg_text);
		if (pname.starts_with("#") || pname.starts_with("$"))
		{
			subs.params.set(pname[1..], arg_text);
		}
	}

	if (call.macro_body_expr && call.macro_body_expr.body)
	{
		DString body_str;
		body_str.tinit();
		MacroSubstitutions empty_subs;
		empty_subs.params.tinit();
		format_node_with_substitutions(&body_str, call.macro_body_expr.body, &empty_subs, 1);
		subs.body_block = body_str.str_view();
	}

	DString result;
	result.tinit();
	format_node_with_substitutions(&result, mac.body, &subs, 0);

	String res_str = result.str_view().trim();
	if (res_str == "{}" || res_str == "{\n}") return "";

	return result.str_view();
}

<*
 Evaluates compile-time expressions ($stringify, $Typeof, Type::size, etc.)
*>
fn String evaluate_compile_time(AnalyzerContext* ctx, SourceFile* sf, Node* node)
{
	if (!node || node.kind == ERROR) return "";

	switch (node.kind)
	{
		case CT_STRINGIFY_EXPR:
			{
				CtStringifyExpr* se = node.as(CtStringifyExpr);
				String text = get_node_source_text(sf, se.inner_expr);
				return string::tformat("\"%s\"", text);
			}

		case CALL_EXPR:
			{
				CallExpr* call = node.as(CallExpr);
				if (call.callee && cursor::spelling(call.callee, tmem) == "$Typeof" && call.args.len > 0)
				{
					String resolved = query::get_type_of_expr(ctx, sf, call.args[0]);
					if (resolved.len > 0)
					{
						return string::tformat("typeid (%s)", resolved);
					}
				}
				if (call.callee && cursor::spelling(call.callee, tmem) == "$stringify" && call.args.len > 0)
				{
					String text = get_node_source_text(sf, call.args[0]);
					return string::tformat("\"%s\"", text);
				}
			}

		case TYPE_EXPR:
			{
				TypeExpr* te = node.as(TypeExpr);
				if (te.type_kind == TYPE_TYPEOF && te.expr)
				{
					String resolved = query::get_type_of_expr(ctx, sf, te.expr);
					if (resolved.len > 0)
					{
						return string::tformat("typeid (%s)", resolved);
					}
				}
			}

		case ACCESS_EXPR:
			{
				AccessExpr* acc = node.as(AccessExpr);
				if (acc.access_kind == STATIC)
				{
					String left_name = cursor::spelling(acc.left, tmem);
					String member_name = cursor::spelling(acc.member, tmem);

					if (member_name == "size" || member_name == "alignment")
					{
						if (ctx && ctx.lookup)
						{
							Type* ty = lookup::get_type_by_name(ctx.lookup, left_name);
							if (ty && ty.status == RESOLVED)
							{
								if (member_name == "size")
								{
									int sz_bytes = ty.size > 0 ? (int)ty.size : (int)ty.data.builtin.bytesize;
									return string::tformat("%d (bytes)", sz_bytes);
								}
								int align_bytes = ty.data.builtin.abi_alignment > 0 ? (int)ty.data.builtin.abi_alignment : (int)ty.data.builtin.bytesize;
								return string::tformat("%d (bytes)", align_bytes);
							}
						}

						return string::tformat("reflection property %s::%s", left_name, member_name);
					}

					if (member_name == "typeid")
					{
						return string::tformat("typeid (%s)", left_name);
					}

					if (member_name == "has_equals" || member_name == "is_ordered")
					{
						return "true (bool)";
					}

					if (member_name == "nan")
					{
						return "NaN (float)";
					}

					if (member_name == "inf")
					{
						return "Infinity (float)";
					}

					if (member_name == "min")
					{
						switch (left_name)
						{
							case "ichar": return "-128";
							case "char":
							case "ushort":
							case "uint":
							case "ulong":
							case "uint128":
							case "usz":
							case "uptr": return "0";
							case "short": return "-32768";
							case "int": return "-2147483648";
							case "long":
							case "sz":
							case "iptr": return "-9223372036854775808";
							default: return string::tformat("%s::min", left_name);
						}
					}

					if (member_name == "max")
					{
						switch (left_name)
						{
							case "ichar": return "127";
							case "char": return "255";
							case "short": return "32767";
							case "ushort": return "65535";
							case "int": return "2147483647";
							case "uint": return "4294967295";
							case "long":
							case "sz":
							case "iptr": return "9223372036854775807";
							case "ulong":
							case "usz":
							case "uptr": return "18446744073709551615";
							default: return string::tformat("%s::max", left_name);
						}
					}

					Node* type_node = null;
					if (ctx)
					{
						if (ctx.registry)
						{
							if (try ty_info = ctx.registry.types.get(left_name))
							{
								type_node = ty_info.node;
							}
						}
						if (!type_node)
						{
							ctx.modules.@each(; mod_name, mod)
							{
								if (!type_node && mod)
								{
									foreach (n : mod.nodes)
									{
										if (!n || n.kind == ERROR) continue;
										if (cursor::spelling(n, tmem) == left_name)
										{
											type_node = n;
											break;
										}
									}
								}
							};
						}
					}

					if (type_node)
					{
						if (type_node.kind == ENUM_DECL && member_name == "len")
						{
							EnumDecl* ed = type_node.as(EnumDecl);
							return string::tformat("%d (variants)", ed.variants.len);
						}
						if (type_node.kind == STRUCT_DECL && member_name == "members")
						{
							StructDecl* sd = type_node.as(StructDecl);
							return string::tformat("%d (members)", sd.fields.len);
						}
					}
				}
				else
				{
					String left_str = cursor::spelling(acc.left, tmem);
					bool is_reflect = (acc.left && (acc.left.kind == CT_REFLECT_EXPR || left_str.starts_with("$reflect")));
					if (is_reflect)
					{
						String member_name = cursor::spelling(acc.member, tmem);
						Node* inner_node = null;
						if (acc.left.kind == CT_REFLECT_EXPR)
						{
							inner_node = acc.left.as(CtReflectExpr).inner_expr;
						}
						else if (acc.left.kind == CALL_EXPR && acc.left.as(CallExpr).args.len > 0)
						{
							inner_node = acc.left.as(CallExpr).args[0];
						}

						String inner_text = inner_node ? get_node_source_text(sf, inner_node) : "";

						if (member_name == "bitoffset" || member_name == "bitsize")
						{
							String struct_name = "";
							String field_name = inner_text;
							if (try dot_idx = inner_text.rindex_of_char('.'))
							{
								struct_name = inner_text[:dot_idx].trim();
								field_name = inner_text[dot_idx + 1..].trim();
							}

							Node* target_field = query::find_member_in_type(ctx, struct_name, field_name);
							if (target_field && target_field.kind == VAR_DECL)
							{
								VarDecl* vd = target_field.as(VarDecl);
								if (member_name == "bitoffset")
								{
									if (vd.init_expr && vd.init_expr.kind == LITERAL_EXPR)
									{
										return string::tformat("%d (bits)", (int)vd.init_expr.as(LiteralExpr).integer);
									}
									return "0 (bits)";
								}
								else if (member_name == "bitsize")
								{
									if (vd.bit_end && vd.bit_end.kind == LITERAL_EXPR && vd.init_expr && vd.init_expr.kind == LITERAL_EXPR)
									{
										int start_bit = (int)vd.init_expr.as(LiteralExpr).integer;
										int end_bit = (int)vd.bit_end.as(LiteralExpr).integer;
										return string::tformat("%d (bits)", end_bit - start_bit + 1);
									}
									return "1 (bits)";
								}
							}
						}

						if (member_name == "offset")
						{
							String struct_name = "";
							String field_name = inner_text;
							if (try dot_idx = inner_text.rindex_of_char('.'))
							{
								struct_name = inner_text[:dot_idx].trim();
								field_name = inner_text[dot_idx + 1..].trim();
							}

							Node* target_field = query::find_member_in_type(ctx, struct_name, field_name);
							if (target_field)
							{
								return string::tformat("offset of %s in %s", field_name, struct_name);
							}
						}

						if (member_name == "name")
						{
							if (try dot_idx = inner_text.rindex_of_char('.'))
							{
								return string::tformat("\"%s\"", inner_text[dot_idx + 1..].trim());
							}
							return string::tformat("\"%s\"", inner_text);
						}

						if (member_name == "qname")
						{
							return string::tformat("\"%s\"", inner_text);
						}

						if (member_name == "size" || member_name == "alignment")
						{
							return string::tformat("%s of %s", member_name, inner_text);
						}

						if (member_name == "param_struct")
						{
							return string::tformat("typeid (param_struct_%s)", inner_text);
						}
					}
				}
			}

		default:
			break;
	}

	return "";
}
