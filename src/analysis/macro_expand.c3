module lsp::analysis::macro_expand;
import analyzer, lsp, std::collections::list, std::collections::map, std::io;

<*
 Extracts the exact source text of a node from the SourceFile buffer.
*>
fn String get_node_source_text(SourceFile* sf, Node* node)
{
	if (!sf || !node) return "";
	if (node.range.start.line < 0 || node.range.end.line < 0) return cursor::spelling(node, tmem);
	return source_text(sf, node.range).trim();
}

<*
 Body of the macro `mac` as `call` invokes it: its source with each
 parameter replaced by the argument bound to it and the body parameter's
 calls by the trailing block, formatted. Empty when there is no body.
*>
fn String expand_macro(AnalyzerContext* ctx, SourceFile* sf, CallExpr* call, MacroDecl* mac)
{
	SourceFile* mf = source_file::file_of(ctx, (Node*)mac);
	if (!call || !mac.body || !mf || !mf.lexer) return "";

	HashMap{String, String} args;
	args.tinit();
	bind_arguments(ctx, sf, mf, call, mac, &args);

	String body_name = mac.body_params ? source_text(mf, mac.body_params.range) : "";
	MacroBodyExpr* trailing = call.macro_body_expr ? call.macro_body_expr.as(MacroBodyExpr) : null;
	String block = trailing && trailing.body ? source_text(sf, trailing.body.range) : "";

	Token[] tokens = mf.lexer.tokens.array_view();
	OffsetCursor offsets = { .text = mf.content };
	DString out;
	out.tinit();
	sz previous_end = offsets.at(mac.body.range.start);
	for (sz i = mf.lexer.first_token_at(mac.body.range.start); i < tokens.len && tokens[i].range.start.before(mac.body.range.end); i++)
	{
		Token token = tokens[i];
		sz start = offsets.at(token.range.start);
		out.append(mf.content[previous_end:start - previous_end]);
		previous_end = offsets.at(token.range.end);
		String text = mf.content[start:previous_end - start];
		if (body_name.len && text == body_name && i + 1 < tokens.len && tokens[i + 1].kind == LPAREN)
		{
			int depth = 0;
			for (i++; i < tokens.len - 1; i++)
			{
				if (tokens[i].kind == LPAREN) depth++;
				if (tokens[i].kind == RPAREN && --depth == 0) break;
			}
			if (i + 1 < tokens.len && tokens[i + 1].kind == EOS) i++;
			previous_end = offsets.at(tokens[i].range.end);
			out.append(block);
			continue;
		}
		out.append(args.get(text) ?? text);
	}

	String expanded = out.str_view();
	Lexer* lexer = lexer::create(ctx, expanded);
	defer lexer::free(ctx, lexer);
	lexer::tokenize(lexer);
	sz count = lexer.tokens.len();
	if (count < 2) return "";
	FormattingOptions options = { .tab_size = 4, .insert_spaces = true };
	String formatted = formatting::format_tokens_range(tmem, expanded, lexer.tokens.array_view(), 0, count - 2, 0, options).trim();
	return formatted == "{}" ? "" : formatted;
}

<*
 Fills `args` with the text each parameter of `mac` takes in `call`: the
 receiver of a method call, positional and named arguments, then defaults.
 Arguments that are not a single operand are parenthesized, as macro
 arguments are evaluated as a whole.
*>
fn void bind_arguments(AnalyzerContext* ctx, SourceFile* sf, SourceFile* mf, CallExpr* call, MacroDecl* mac, HashMap{String, String}* args) @local
{
	CallTarget target = query::call_target(ctx, sf, call);
	NodeArray params = mac.params;
	if (target.first_param && params.len)
	{
		args.set(param_name(params[0]), operand_text(sf, call.callee.as(AccessExpr).left));
	}
	foreach (i, arg : call.args)
	{
		if (!arg) continue;
		if (arg.kind == NAMED_ARG_EXPR)
		{
			NamedArgExpr* named = arg.as(NamedArgExpr);
			if (named.name && named.value) args.set(named.name.text, operand_text(sf, named.value));
			continue;
		}
		sz index = i + target.first_param;
		if (index < params.len) args.set(param_name(params[index]), operand_text(sf, arg));
	}
	foreach (p : params)
	{
		String name = param_name(p);
		if (!name.len || args.has_key(name) || !p.as(VarDecl).init_expr) continue;
		args.set(name, operand_text(mf, p.as(VarDecl).init_expr));
	}
}

fn String param_name(Node* param) @local
{
	return param && param.kind == VAR_DECL && param.as(VarDecl).name ? param.as(VarDecl).name.text : "";
}

<*
 Source of `expr` in `sf`, in parentheses unless it is a single operand.
*>
fn String operand_text(SourceFile* sf, Node* expr) @local
{
	String text = source_text(sf, expr.range);
	switch (expr.kind)
	{
		case IDENT_EXPR:
		case LITERAL_EXPR:
		case CALL_EXPR:
		case ACCESS_EXPR:
		case DESIGNATOR_EXPR:
		case MAYBE_DEREF_EXPR:
		case GROUP_EXPR:
		case TYPE_EXPR:
		case INITIALIZER_LIST_EXPR:
		case COMPOUND_LITERAL_EXPR:
		case BUILTIN_EXPR:
		case COMPILER_CONST_EXPR:
			return text;
		default:
			return string::tformat("(%s)", text);
	}
}

fn String source_text(SourceFile* sf, Range range) @local
{
	OffsetCursor offsets = { .text = sf.content };
	sz start = offsets.at(range.start);
	return sf.content[start:offsets.at(range.end) - start];
}

<*
 Byte offsets of locations in `text`, for locations given in order.
*>
struct OffsetCursor
{
	String text;
	int line;
	sz line_start;
}

fn sz OffsetCursor.at(&self, Location loc)
{
	while (self.line < loc.line)
	{
		sz rest = self.text.len - self.line_start;
		self.line_start += (self.text[self.line_start..].index_of_char('\n') ?? (rest - 1)) + 1;
		self.line++;
	}
	return min(self.line_start + loc.column, self.text.len);
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
					String resolved = query::type_of(ctx, sf, call.args[0], {-1, -1});
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
					String resolved = query::type_of(ctx, sf, te.expr, {-1, -1});
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
