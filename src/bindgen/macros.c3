module lsp::bindgen;

import std;

const String MACRO_PROBE_PREFIX = "__c3_probe_";
const String[2] MACRO_PROBE_PASSES = { "__c3_probe_a_", "__c3_probe_b_" };
const String MACRO_PROBE_RELOCATED_FILE = "c3_probe_b.c";

faultdef UNSUPPORTED_MACRO_VALUE;

struct MacroDefinition
{
	String name;
	String body;
}

<*
 Object-like #define constants from target files in `clang -E -dD` output, in first-seen order with
 the last definition's body. Skips names that are not C3 constant names or are already constants, and
 bodies with unbalanced brackets, which could swallow the probe declarations after them.
*>
fn MacroDefinition[] collect_macro_definitions(Allocator allocator, CTranslationUnit* tu, String preprocessed, BindgenOptions options)
{
	HashSet{String} known_names;
	known_names.tinit();
	foreach (&c : tu.constants) known_names.add(c.name);

	HashMap{String, String} bodies;
	bodies.tinit();
	List{String} names;
	names.tinit();
	String current_file;
	foreach (line : preprocessed.tsplit("\n"))
	{
		if (line.starts_with("# "))
		{
			String[] quoted = line.tsplit("\"");
			if (quoted.len >= 3) current_file = quoted[1];
			continue;
		}
		if (!line.starts_with("#define ") || !is_target_file(current_file, options)) continue;

		String definition = line["#define ".len..];
		sz name_len;
		while (name_len < definition.len && (definition[name_len].is_alnum() || definition[name_len] == '_')) name_len++;
		String name = definition[:name_len];
		String body = definition[name_len..];
		if (body.starts_with("(") || !is_c3_constant_name(name) || known_names.contains(name)) continue;

		body = body.trim();
		if (body.len == 0 || !has_balanced_brackets(body)) continue;
		if (!bodies.has_key(name)) names.push(name);
		bodies.set(name, body);
	}

	List{MacroDefinition} macros;
	macros.init(allocator);
	foreach (name : names) macros.push({ name.copy(allocator), bodies.get(name)!!.copy(allocator) });
	return macros.array_view();
}

<*
 C source that includes the header and declares one `__auto_type` variable per macro, so clang
 reports each macro's type and value. Macros that are not expressions produce invalid declarations.
 The declarations are repeated under another file name and line numbers, so values that depend on
 where the macro expands, such as `__FILE__`, `__LINE__` or `__COUNTER__`, differ between the passes.
*>
fn String build_macro_probe(String header_path, MacroDefinition[] macros)
{
	DString out;
	out.tinit();
	out.appendf("#include \"%s\"\n", header_path);
	foreach (i, prefix : MACRO_PROBE_PASSES)
	{
		if (i > 0) out.appendf("#line 1 \"%s\"\n", MACRO_PROBE_RELOCATED_FILE);
		foreach (m : macros) out.appendf("static const __auto_type %s%s = (%s);\n", prefix, m.name, m.name);
	}
	return out.str_view();
}

<*
 Emits a typed constant for each macro whose probe declaration clang accepted and whose value C3 can express.
*>
fn void parse_macro_probe(Allocator allocator, CTranslationUnit* tu, MacroDefinition[] macros, Object* probe_root, BindgenOptions options)
{
	HashMap{String, Object*} probes;
	probes.tinit();
	foreach (node : inner_nodes(probe_root))
	{
		String name = node.get_string("name") ?? "";
		if ((node.get_string("kind") ?? "") != "VarDecl" || !name.starts_with(MACRO_PROBE_PREFIX) || (node.get_bool("isInvalid") ?? false)) continue;
		probes.set(name, node);
	}

	foreach (m : macros)
	{
		Object*? decl = probes.get(string::tformat("%s%s", MACRO_PROBE_PASSES[0], m.name));
		Object*? relocated = probes.get(string::tformat("%s%s", MACRO_PROBE_PASSES[1], m.name));
		if (catch decl, relocated) continue;

		String? c3_type = macro_constant_type(allocator, decl, options, tu);
		String? value = macro_value_expr(allocator, first_inner(decl), options, tu);
		String? relocated_value = macro_value_expr(tmem, first_inner(relocated), options, tu);
		if (catch c3_type, value, relocated_value) continue;
		if (value != relocated_value) continue;

		tu.constants.push({ .name = m.name.copy(allocator), .value = c3_number_literal(allocator, m.body) ?? value, .c3_type = c3_type });
	}
}

fn bool is_c3_constant_name(String name) @local
{
	if (name.len == 0 || !name[0].is_upper()) return false;
	foreach (c : name)
	{
		if (!c.is_upper() && !c.is_digit() && c != '_') return false;
	}
	return true;
}

<*
 Whether every (, [ and { outside string and character literals is closed in order.
*>
fn bool has_balanced_brackets(String s) @local
{
	List{char} open;
	open.tinit();
	char quote;
	for (sz i = 0; i < s.len; i++)
	{
		char c = s[i];
		if (quote)
		{
			if (c == '\\') i++;
			if (c == quote) quote = 0;
			continue;
		}
		switch (c)
		{
			case '"':
			case '\'':
				quote = c;
			case '(': open.push(')');
			case '[': open.push(']');
			case '{': open.push('}');
			case ')':
			case ']':
			case '}':
				if (open.len() == 0 || open.pop()!! != c) return false;
		}
	}
	return open.len() == 0 && !quote;
}

<*
 Innermost node below parentheses and implicit casts.
*>
fn Object* core_expr(Object* node) @local
{
	while (true)
	{
		String kind = node.get_string("kind") ?? "";
		if (kind != "ParenExpr" && kind != "ImplicitCastExpr" && kind != "ConstantExpr") return node;
		Object*? child = first_inner(node);
		if (catch child) return node;
		node = child;
	}
}

<*
 C3 type of a probe declaration: ZString for string literals, otherwise the declared type without its
 top-level const. Pointer and array types are unsupported.
*>
fn String? macro_constant_type(Allocator allocator, Object* decl, BindgenOptions options, CTranslationUnit* tu) @local
{
	if ((core_expr(first_inner(decl)!).get_string("kind") ?? "") == "StringLiteral") return "ZString";
	if (is_indirect_type(decl)) return UNSUPPORTED_MACRO_VALUE~;
	RawTypeInfo t = extract_type_info(decl);
	return map_c_type_to_c3(allocator, t.qual_type.strip_prefix("const "), options.type_prefix, tu, false, t.desugared_type.strip_prefix("const "));
}

<*
 A macro body that is a single numeric literal, respelled for C3: suffixes dropped, since the declared
 type carries them, and C octal turned into `0o`. Keeps hexadecimal flags readable.
*>
fn String? c3_number_literal(Allocator allocator, String body) @local
{
	String s = body;
	while (s.starts_with("(") && s.ends_with(")")) s = s[1..^2].trim();
	if (s.len == 0 || (!s[0].is_digit() && s[0] != '.')) return UNSUPPORTED_MACRO_VALUE~;
	foreach (i, c : s)
	{
		bool is_exponent_sign = (c == '+' || c == '-') && i > 0 && "eEpP".contains_char(s[i - 1]);
		if (!c.is_alnum() && c != '.' && !is_exponent_sign) return UNSUPPORTED_MACRO_VALUE~;
	}

	bool is_hex = s.starts_with("0x") || s.starts_with("0X");
	if (is_hex && (s.contains("p") || s.contains("P"))) return UNSUPPORTED_MACRO_VALUE~;
	bool is_float = !is_hex && (s.contains(".") || s.contains("e") || s.contains("E"));
	s = s.trim_right(is_float ? "fFlL" : "uUlL");
	if (!is_float && s.len > 1 && s[0] == '0' && s[1].is_digit()) return string::format(allocator, "0o%s", s[1..]);
	return s.copy(allocator);
}

<*
 C3 expression for a probe initializer. Binary operations are parenthesized because C3 operator
 precedence differs from C; literals whose C type is not int or double carry it explicitly.
*>
fn String? macro_value_expr(Allocator allocator, Object* node, BindgenOptions options, CTranslationUnit* tu) @local
{
	String kind = node.get_string("kind") ?? "";
	String c_type = node.get("type").get_string("qualType") ?? "";
	switch (kind)
	{
		case "ParenExpr":
		case "ImplicitCastExpr":
		case "ConstantExpr":
		case "CompoundLiteralExpr":
			return macro_value_expr(allocator, first_inner(node), options, tu);
		case "IntegerLiteral":
			String value = node.get_string("value")!;
			if (c_type == "int") return value.copy(allocator);
			return string::format(allocator, "(%s)%s", map_c_type_to_c3(tmem, c_type, options.type_prefix, tu), value);
		case "CharacterLiteral":
			return string::format(allocator, "%d", node.get_long("value")!);
		case "FloatingLiteral":
			String value = node.get_string("value")!;
			if (!value[0].is_digit()) return UNSUPPORTED_MACRO_VALUE~;
			if (!value.contains(".") && !value.contains("e")) value = string::tformat("%s.0", value);
			switch (c_type)
			{
				case "double": return value.copy(allocator);
				case "float": return string::format(allocator, "%sf", value);
				default: return UNSUPPORTED_MACRO_VALUE~;
			}
		case "StringLiteral":
			String value = node.get_string("value")!;
			if (!value.starts_with("\"")) return UNSUPPORTED_MACRO_VALUE~;
			return c3_string_literal(allocator, value);
		case "UnaryOperator":
			String op = node.get_string("opcode")!;
			if (op != "-" && op != "+" && op != "~") return UNSUPPORTED_MACRO_VALUE~;
			return string::format(allocator, "%s%s", op, macro_value_expr(allocator, first_inner(node), options, tu)!);
		case "BinaryOperator":
			String op = node.get_string("opcode")!;
			if (!is_arithmetic_operator(op)) return UNSUPPORTED_MACRO_VALUE~;
			Object*[] operands = inner_nodes(node);
			if (operands.len != 2) return UNSUPPORTED_MACRO_VALUE~;
			String lhs = macro_value_expr(allocator, operands[0], options, tu)!;
			String rhs = macro_value_expr(allocator, operands[1], options, tu)!;
			return string::format(allocator, "(%s %s %s)", lhs, op, rhs);
		case "CStyleCastExpr":
			if (is_indirect_type(node)) return UNSUPPORTED_MACRO_VALUE~;
			String operand = macro_value_expr(allocator, first_inner(node), options, tu)!;
			return string::format(allocator, "(%s)(%s)", map_c_type_to_c3(tmem, c_type, options.type_prefix, tu), operand);
		case "InitListExpr":
			DString out;
			out.init(allocator);
			out.append("{ ");
			foreach (i, element : inner_nodes(node))
			{
				if (i > 0) out.append(", ");
				out.append(macro_value_expr(allocator, element, options, tu)!);
			}
			out.append(" }");
			return out.str_view();
		default:
			return UNSUPPORTED_MACRO_VALUE~;
	}
}

<*
 Whether a node's type, sugared or desugared, is a pointer, array or function type.
*>
fn bool is_indirect_type(Object* node) @local
{
	RawTypeInfo t = extract_type_info(node);
	foreach (String c_type : { t.qual_type, t.desugared_type })
	{
		if (c_type.contains("*") || c_type.contains("[") || c_type.contains("(")) return true;
	}
	return false;
}

fn bool is_arithmetic_operator(String op) @local
{
	foreach (String candidate : { "+", "-", "*", "/", "%", "<<", ">>", "&", "|", "^" })
	{
		if (op == candidate) return true;
	}
	return false;
}

<*
 Respells a C string literal for C3, which lacks octal escapes: `\ooo` becomes `\xHH`, except a lone `\0`.
*>
fn String c3_string_literal(Allocator allocator, String literal) @local
{
	DString out;
	out.init(allocator);
	for (sz i = 0; i < literal.len; i++)
	{
		if (literal[i] != '\\' || i + 1 == literal.len)
		{
			out.append_char(literal[i]);
			continue;
		}
		sz digits;
		int code;
		while (digits < 3 && i + 1 + digits < literal.len && literal[i + 1 + digits].is_odigit())
		{
			code = code * 8 + literal[i + 1 + digits] - '0';
			digits++;
		}
		switch
		{
			case digits == 0: out.append(literal[i:2]);
			case digits == 1 && code == 0: out.append("\\0");
			default: out.appendf("\\x%02x", code);
		}
		i += digits == 0 ? 1 : digits;
	}
	return out.str_view();
}
