module lsp::bindgen;

import std;
import analyzer::core::constants;

const sz MAX_MODULE_NAME_LEN = 31;
const sz MAX_IDENTIFIER_LEN = 127;

<*
 Configuration options passed to the bindgen generator.
*>
struct BindgenOptions
{
	String header_path;
	String output_path;
	String module_name;
	String type_prefix;
	String strip_func_prefix;
	String strip_enum_prefix;
	String clang_path;
	String target;
	String[] include_dirs;
	String[] defines;
}

<*
 Parameter in a C function declaration.
*>
struct CParam
{
	String name;
	String c_type;
	String c3_type;
	bool is_noalias;
}

<*
 Function declaration model.
*>
struct CFunction
{
	String c_name;
	String c3_name;
	String ret_type_c;
	String ret_type_c3;
	List{CParam} params;
	bool is_variadic;
	String comment;
}

<*
 Field in a struct or union.
*>
struct CField
{
	String c_name;
	String c3_name;
	String c_type;
	String c3_type;
	int bit_width;
	int bit_offset;
	String comment;
}

<*
 Struct, union, or bitstruct definition.
*>
struct CStruct
{
	String c_name;
	String c3_name;
	bool is_union;
	bool is_opaque;
	bool is_bitfield;
	List{CField} fields;
	String comment;
}

<*
 Variant inside an enum or constdef.
*>
struct CEnumVariant
{
	String c_name;
	String c3_name;
	long value;
	bool has_explicit_value;
	String comment;
}

<*
 Enum or constdef declaration.
*>
struct CEnum
{
	String c_name;
	String c3_name;
	bool is_constdef;
	String backing_type;
	List{CEnumVariant} variants;
	String comment;
}

<*
 Typedef or alias declaration.
*>
struct CTypedef
{
	String c_name;
	String c3_name;
	String underlying_c;
	String underlying_c3;
	bool is_func_ptr;
	String comment;
}

<*
 Preprocessor constant (#define).
*>
struct CConstant
{
	String name;
	String value;
	String c3_type;
	String comment;
}

<*
 Global variable declaration.
*>
struct CVariable
{
	String c_name;
	String c3_name;
	String c_type;
	String c3_type;
	String comment;
}

<*
 Complete parsed translation unit containing all extracted C symbols.
*>
struct CTranslationUnit
{
	List{CConstant} constants;
	List{CTypedef} typedefs;
	List{CEnum} enums;
	List{CStruct} structs;
	List{CVariable} variables;
	List{CFunction} functions;
}

fn void CTranslationUnit.init(&self, Allocator allocator)
{
	self.constants.init(allocator);
	self.typedefs.init(allocator);
	self.enums.init(allocator);
	self.structs.init(allocator);
	self.variables.init(allocator);
	self.functions.init(allocator);
}

fn void CTranslationUnit.free(&self)
{
	self.constants.free();
	self.typedefs.free();
	self.enums.free();
	self.structs.free();
	self.variables.free();
	self.functions.free();
}

fn String deduplicate_name(HashSet{String}* seen, String name, Allocator allocator)
{
	String base = name;
	if (base.len > MAX_IDENTIFIER_LEN)
	{
		base = base[:MAX_IDENTIFIER_LEN];
	}

	if (seen.add(base))
	{
		return base;
	}

	int counter = 2;
	while (true)
	{
		String suffix = string::format(tmem, "_%d", counter);
		sz max_base_len = MAX_IDENTIFIER_LEN > suffix.len ? MAX_IDENTIFIER_LEN - suffix.len : (sz)0;
		String trimmed_base = base.len > max_base_len ? base[:max_base_len] : base;
		String unique_name = string::format(allocator, "%s%s", trimmed_base, suffix);
		if (seen.add(unique_name))
		{
			return unique_name;
		}
		counter++;
	}
}

fn List{String} clean_c_type_words(String s)
{
	List{String} clean_words;
	clean_words.tinit();
	String[] words = s.tsplit(" ");
	foreach (w : words)
	{
		String tw = w.trim().trim_right(",;");
		if (tw.len == 0)
		{
			continue;
		}
		if (tw == "const" || tw == "volatile" || tw == "__volatile" || tw == "__volatile__")
		{
			continue;
		}
		if (tw == "restrict" || tw == "__restrict" || tw == "__restrict__")
		{
			continue;
		}
		if (tw == "_Atomic")
		{
			continue;
		}
		clean_words.push(tw);
	}
	return clean_words;
}

fn String strip_clang_attributes(String raw)
{
	String s = raw;
	while (try attr_idx = s.index_of("__attribute__"))
	{
		sz p = attr_idx + 13;
		while (p < s.len && s[p] != '(')
		{
			p++;
		}
		if (p < s.len && s[p] == '(')
		{
			int depth = 1;
			p++;
			while (p < s.len && depth > 0)
			{
				if (s[p] == '(')
				{
					depth++;
				}
				else if (s[p] == ')')
				{
					depth--;
				}
				p++;
			}
			s = string::tformat("%s %s", s[:attr_idx], s[p..]).trim();
		}
		else
		{
			break;
		}
	}
	return s;
}

<*
 Normalizes a raw string into a valid C3 module identifier.
 Enforces lowercase alphanumeric, no hyphens, and keyword safety.
*>
fn String sanitize_module_name(Allocator allocator, String raw_name)
{
	if (raw_name.len == 0)
	{
		return "c_lib";
	}

	DString sb;
	sb.init(allocator);

	bool last_was_underscore = false;
	for (sz i = 0; i < raw_name.len; i++)
	{
		char c = raw_name[i];
		if (c >= 'A' && c <= 'Z')
		{
			sb.append_char((char)(c + 32));
			last_was_underscore = false;
			continue;
		}

		if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9'))
		{
			sb.append_char(c);
			last_was_underscore = false;
			continue;
		}

		if (c == ':' && i + 1 < raw_name.len && raw_name[i + 1] == ':')
		{
			sb.append("::");
			i++;
			last_was_underscore = true;
			continue;
		}

		if (!last_was_underscore && sb.len() > 0)
		{
			sb.append_char('_');
			last_was_underscore = true;
		}
	}

	String s = sb.str_view();
	while (s.starts_with("_"))
	{
		s = s[1..];
	}
	while (s.ends_with("_"))
	{
		s = s[:^1];
	}

	if (s.len == 0)
	{
		return "c_lib";
	}

	if (s[0] >= '0' && s[0] <= '9')
	{
		s = string::format(allocator, "c_%s", s);
	}

	if (is_c3_keyword(s) || constants::is_primitive(s))
	{
		s = string::format(allocator, "c_%s", s);
	}

	if (s.len > MAX_MODULE_NAME_LEN)
	{
		s = s[:MAX_MODULE_NAME_LEN];
		while (s.ends_with("_"))
		{
			s = s[:^1];
		}
	}

	return s.copy(allocator);
}

<*
 Converts a C PascalCase or camelCase identifier to idiomatic C3 snake_case.
 Handles uppercase acronym sequences and 2D/3D suffixes matching raylib vendor style.
*>
fn String to_snake_case(Allocator allocator, String name)
{
	if (name.len == 0)
	{
		return "";
	}

	DString sb;
	sb.init(allocator);

	for (sz i = 0; i < name.len; i++)
	{
		char c = name[i];

		if (c >= 'A' && c <= 'Z')
		{
			bool prev_is_lower = (i > 0 && name[i - 1] >= 'a' && name[i - 1] <= 'z');
			bool prev_is_digit = (i > 0 && name[i - 1] >= '0' && name[i - 1] <= '9');
			bool next_is_lower = (i + 1 < name.len && name[i + 1] >= 'a' && name[i + 1] <= 'z');
			bool prev_is_upper = (i > 0 && name[i - 1] >= 'A' && name[i - 1] <= 'Z');
			bool is_dimension_suffix = ((c == 'D' || c == 'd') && prev_is_digit);

			if (!is_dimension_suffix)
			{
				if (prev_is_lower || (prev_is_digit && next_is_lower) || (prev_is_upper && next_is_lower))
				{
					if (sb.len() > 0 && sb.char_at(sb.len() - 1) != '_')
					{
						sb.append_char('_');
					}
				}
			}

			sb.append_char((char)(c + 32));
		}
		else if (c == '-')
		{
			sb.append_char('_');
		}
		else
		{
			sb.append_char(c);
		}
	}

	String result = sb.str_view().copy(allocator);
	return sanitize_identifier(allocator, result);
}

<*
 Checks if an identifier collides with a C3 reserved keyword.
*>
fn bool is_c3_keyword(String s) => constants::is_keyword(s);

<*
 Sanitizes variable, parameter, or field names to prevent C3 syntax clashes.
 Prevents collision with keywords, primitives, and standard types.
 Guarantees variable names contain at least one valid identifier character after '_'.
*>
	fn String sanitize_identifier(Allocator allocator, String name)
	{
		if (name.len == 0)
		{
			return "arg";
		}
		String s = name;
		if (s.len > 127)
		{
			s = s[:127];
		}

		String trimmed_lead = s.trim_left("_");
		if (trimmed_lead.len == 0)
		{
			return "_unused";
		}
		if (trimmed_lead[0].is_digit())
		{
			s = string::format(allocator, "_v%s", trimmed_lead);
		}

		if (is_c3_keyword(s) || constants::is_primitive(s) || is_c3_type(s) || s == "main")
		{
			s = string::format(allocator, "%s_", s);
		}
		if (s.len > 127)
		{
			s = s[:127];
		}
		return s.copy(allocator);
	}

<*
 Checks if an identifier is a built-in or std::core::cinterop C3 type.
*>
fn bool is_c3_type(String s)
{
	if (constants::is_primitive(s))
	{
		return true;
	}

	const String[*] CINTEROP_TYPES = {
		"CChar", "CSChar", "CUChar", "CShort", "CUShort", "CInt", "CUInt",
		"CLong", "CULong", "CLongLong", "CULongLong", "CBool", "CVaList",
		"String", "ZString"
	};
	foreach (t : CINTEROP_TYPES)
	{
		if (s == t)
		{
			return true;
		}
	}
	return false;
}

<*
 Maps standard C primitives, stdint.h, stddef.h, and sys/types.h to C3 equivalents.
 Returns empty string if the type is not a standard C type.
*>
fn String map_c_standard_type(String s)
{
	switch (s)
	{
		case "void":                   return "void";
		case "_Bool":
		case "bool":                   return "bool";
		case "char":                   return "char";
		case "signed char":            return "ichar";
		case "unsigned char":          return "char";
		case "short":
		case "signed short":
		case "short int":
		case "signed short int":       return "short";
		case "unsigned short":
		case "unsigned short int":     return "ushort";
		case "int":
		case "signed int":             return "int";
		case "unsigned int":
		case "unsigned":               return "uint";
		case "long":
		case "signed long":
		case "long int":
		case "signed long int":        return "CLong";
		case "unsigned long":
		case "unsigned long int":      return "CULong";
		case "long long":
		case "signed long long":
		case "long long int":
		case "signed long long int":   return "long";
		case "unsigned long long":
		case "unsigned long long int": return "ulong";
		case "float":                  return "float";
		case "double":
		case "long double":            return "double";

		// C99 Complex types (mapped to 2-element arrays conforming to C ABI)
		case "_Complex":
		case "complex":
		case "_Complex double":
		case "double _Complex":
		case "complex double":
		case "Complex double":
		case "_Complex long double":
		case "long double _Complex":
		case "complex long double":
		case "Complex long double":    return "double[2]";

		case "_Complex float":
		case "float _Complex":
		case "complex float":
		case "Complex float":          return "float[2]";

		case "_Complex int":
		case "int _Complex":
		case "complex int":
		case "Complex int":            return "int[2]";

		case "_Complex short":
		case "short _Complex":
		case "complex short":
		case "Complex short":          return "short[2]";

		case "_Complex char":
		case "char _Complex":
		case "complex char":
		case "Complex char":           return "char[2]";

		case "_Imaginary float":
		case "float _Imaginary":       return "float";

		case "_Imaginary double":
		case "double _Imaginary":
		case "_Imaginary long double":
		case "long double _Imaginary": return "double";

		// stdint.h
		case "int8_t":                 return "ichar";
		case "uint8_t":                return "char";
		case "int16_t":                return "short";
		case "uint16_t":               return "ushort";
		case "int32_t":                return "int";
		case "uint32_t":               return "uint";
		case "int64_t":                return "long";
		case "uint64_t":               return "ulong";
		case "int128_t":
		case "__int128":
		case "__int128_t":             return "int128";
		case "uint128_t":
		case "unsigned __int128":
		case "__uint128_t":            return "uint128";
		case "intptr_t":               return "iptr";
		case "uintptr_t":              return "uptr";
		case "intmax_t":               return "long";
		case "uintmax_t":              return "ulong";

		// stddef.h & sys/types.h
		case "size_t":                 return "usz";
		case "ssize_t":
		case "ptrdiff_t":              return "sz";
		case "u_char":
		case "uchar":                  return "char";
		case "u_short":
		case "ushort":                 return "ushort";
		case "u_int":
		case "uint":                   return "uint";
		case "u_long":
		case "ulong":                  return "CULong";
		case "u_int8_t":               return "char";
		case "u_int16_t":              return "ushort";
		case "u_int32_t":              return "uint";
		case "u_int64_t":              return "ulong";

		// stdarg.h
		case "va_list":
		case "__va_list_tag":
		case "__builtin_va_list":      return "CVaList";

		default:
			return "";
	}
}

<*
 Checks if a type name is a fundamental C primitive keyword or standard typedef.
*>
fn bool is_fundamental_c_type(String s) => map_c_standard_type(s).len > 0;

<*
 Validates and formats a C type name into a C3-compliant type identifier.
 Guarantees PascalCase with at least one lowercase letter and strips leading underscores.
*>
fn String sanitize_c3_type_name(Allocator allocator, String raw_name, String type_prefix)
{
	if (raw_name.len == 0 || raw_name.contains("(") || raw_name.contains(")") || raw_name.contains(",") || raw_name.contains(";"))
	{
		return "void";
	}

	String std_c3 = map_c_standard_type(raw_name);
	if (std_c3.len > 0)
	{
		return std_c3.copy(allocator);
	}

	if (is_c3_type(raw_name) && raw_name[0].is_upper())
	{
		return raw_name.copy(allocator);
	}

	String s = raw_name.trim();

	while (s.starts_with("_"))
	{
		s = s[1..];
	}
	while (s.ends_with("_"))
	{
		s = s[:^1];
	}
	if (s.len == 0)
	{
		s = "UnknownType";
	}

	bool all_upper = true;
	bool has_alpha = false;
	for (sz i = 0; i < s.len; i++)
	{
		char c = s[i];
		if (c >= 'a' && c <= 'z')
		{
			all_upper = false;
			break;
		}
		if (c >= 'A' && c <= 'Z')
		{
			has_alpha = true;
		}
	}

	String pascal;
	if (all_upper && has_alpha)
	{
		if (s.contains("_"))
		{
			pascal = s.snake_to_pascal_copy(allocator);
		}
		else
		{
			DString sb;
			sb.init(allocator);
			sb.append_char(s[0]);
			for (sz i = 1; i < s.len; i++)
			{
				sb.append_char((char)(s[i] + 32));
			}
			if (s.len == 1)
			{
				sb.append("_t");
			}
			pascal = sb.str_view().copy(allocator);
		}
	}
	else if ((s[0] >= 'a' && s[0] <= 'z') || s.contains("_"))
	{
		pascal = s.snake_to_pascal_copy(allocator);
	}
	else
	{
		bool has_lower = false;
		for (sz i = 0; i < s.len; i++)
		{
			if (s[i] >= 'a' && s[i] <= 'z')
			{
				has_lower = true;
				break;
			}
		}
		pascal = has_lower ? s.copy(allocator) : string::format(allocator, "%s_t", s);
	}

	bool has_lower = false;
	for (sz i = 0; i < pascal.len; i++)
	{
		if (pascal[i] >= 'a' && pascal[i] <= 'z')
		{
			has_lower = true;
			break;
		}
	}
	if (!has_lower)
	{
		pascal = string::format(allocator, "%s_t", pascal);
	}

	if (type_prefix.len > 0 && !pascal.starts_with(type_prefix))
	{
		bool prefix_has_lower = false;
		for (sz i = 0; i < type_prefix.len; i++)
		{
			if (type_prefix[i] >= 'a' && type_prefix[i] <= 'z')
			{
				prefix_has_lower = true;
				break;
			}
		}
		if (all_upper && prefix_has_lower)
		{
			pascal = string::format(allocator, "%s_%s", type_prefix, raw_name);
		}
		else
		{
			pascal = string::format(allocator, "%s%s", type_prefix, pascal);
		}
	}

	if (pascal.len > 127)
	{
		pascal = pascal[:127];
	}

	return pascal;
}

<*
 Extracts base identifier from a type string (strips pointers, qualifiers, and macro attributes).
*>
fn String extract_base_type_name(String qual_type)
{
	String s = qual_type.trim();
	while (true)
	{
		s = s.trim();
		if (s.ends_with("*") || s.ends_with("&"))
		{
			s = s[:^1];
			continue;
		}
		if (s.ends_with("]"))
		{
			if (try open_b = s.rindex_of_char('['))
			{
				s = s[:open_b];
				continue;
			}
		}
		break;
	}

	List{String} clean_words = clean_c_type_words(s);
	if (clean_words.len() == 0)
	{
		return "";
	}

	// 1. Tagged type: struct X, union X, enum X
	for (sz i = 0; i < clean_words.len(); i++)
	{
		String w = clean_words.get(i);
		if ((w == "struct" || w == "union" || w == "enum") && i + 1 < clean_words.len())
		{
			return clean_words.get(i + 1);
		}
	}

	// 2. Suffix standard C type (e.g. "unsigned int", "char")
	for (sz i = 0; i < clean_words.len(); i++)
	{
		DString suffix_sb;
		suffix_sb.tinit();
		for (sz j = i; j < clean_words.len(); j++)
		{
			if (suffix_sb.len() > 0) suffix_sb.append_char(' ');
			suffix_sb.append(clean_words.get(j));
		}
		if (map_c_standard_type(suffix_sb.str_view()).len > 0)
		{
			return suffix_sb.str_view();
		}
	}

	// 3. Rightmost token (typedef name)
	return clean_words.get(clean_words.len() - 1);
}

const sz DEFAULT_VECTOR_BYTES = 16;
const sz DEFAULT_VECTOR_COUNT = 4;
const sz DEFAULT_ELEM_BYTES = 4;

<*
 Parses GCC/Clang vector attributes using balanced parenthesis matching.
*>
fn String parse_vector_attribute_type(Allocator allocator, String raw) @local
{
	String s = raw.trim();
	int pointer_depth = 0;

	while (true)
	{
		s = s.trim();
		if (s.ends_with("*"))
		{
			pointer_depth++;
			s = s[:^1].trim_right();
			continue;
		}
		if (s.ends_with("const"))
		{
			s = s[:^5].trim_right();
			continue;
		}
		if (s.ends_with("volatile"))
		{
			s = s[:^8].trim_right();
			continue;
		}
		if (s.ends_with("__volatile"))
		{
			s = s[:^10].trim_right();
			continue;
		}
		if (s.ends_with("__volatile__"))
		{
			s = s[:^12].trim_right();
			continue;
		}
		if (s.ends_with("restrict"))
		{
			s = s[:^8].trim_right();
			continue;
		}
		if (s.ends_with("__restrict"))
		{
			s = s[:^10].trim_right();
			continue;
		}
		if (s.ends_with("__restrict__"))
		{
			s = s[:^12].trim_right();
			continue;
		}
		break;
	}

	sz vec_bytes = 0;
	sz elem_count = 0;

	if (try ext_idx = s.index_of("ext_vector_type"))
	{
		sz p = ext_idx + 15;
		while (p < s.len && s[p] != '(')
		{
			p++;
		}
		if (p < s.len && s[p] == '(')
		{
			sz arg_start = p + 1;
			int depth = 1;
			p++;
			while (p < s.len && depth > 0)
			{
				if (s[p] == '(')
				{
					depth++;
				}
				else if (s[p] == ')')
				{
					depth--;
				}
				if (depth == 0)
				{
					break;
				}
				p++;
			}
			String arg = s[arg_start : p - arg_start].trim();
			if (try parsed = arg.to_ulong())
			{
				elem_count = (sz)parsed;
			}
		}
	}
	else if (try neon_idx = s.index_of("neon_vector_type"))
	{
		sz p = neon_idx + 16;
		while (p < s.len && s[p] != '(')
		{
			p++;
		}
		if (p < s.len && s[p] == '(')
		{
			sz arg_start = p + 1;
			int depth = 1;
			p++;
			while (p < s.len && depth > 0)
			{
				if (s[p] == '(')
				{
					depth++;
				}
				else if (s[p] == ')')
				{
					depth--;
				}
				if (depth == 0)
				{
					break;
				}
				p++;
			}
			String arg = s[arg_start : p - arg_start].trim();
			if (try parsed = arg.to_ulong())
			{
				elem_count = (sz)parsed;
			}
		}
	}
	else if (try vec_idx = s.index_of("vector_size"))
	{
		sz p = vec_idx + 11;
		while (p < s.len && s[p] != '(')
		{
			p++;
		}
		if (p < s.len && s[p] == '(')
		{
			sz arg_start = p + 1;
			int depth = 1;
			p++;
			while (p < s.len && depth > 0)
			{
				if (s[p] == '(')
				{
					depth++;
				}
				else if (s[p] == ')')
				{
					depth--;
				}
				if (depth == 0)
				{
					break;
				}
				p++;
			}
			String arg = s[arg_start : p - arg_start].trim();
			if (try parsed = arg.to_ulong())
			{
				vec_bytes = (sz)parsed;
			}
			else
			{
				String[] terms = arg.tsplit("*");
				sz product = 1;
				foreach (term : terms)
				{
					String t = term.trim().trim_left(" (").trim_right(" )");
					if (try val = t.to_ulong())
					{
						product *= (sz)val;
					}
					else if (t.contains("double"))
					{
						product *= 8;
					}
					else if (t.contains("float") || t.contains("int"))
					{
						product *= 4;
					}
					else if (t.contains("short"))
					{
						product *= 2;
					}
					else if (t.contains("char"))
					{
						product *= 1;
					}
				}
				if (product > 1)
				{
					vec_bytes = product;
				}
			}
		}
	}

	if (vec_bytes == 0 && elem_count == 0)
	{
		vec_bytes = DEFAULT_VECTOR_BYTES;
	}

	s = strip_clang_attributes(s);

	const String[*] VEC_ATTRS = { "__vector_size__", "vector_size", "ext_vector_type", "neon_vector_type" };
	foreach (va : VEC_ATTRS)
	{
		while (try va_idx = s.index_of(va))
		{
			sz p = va_idx + va.len;
			while (p < s.len && s[p] != '(')
			{
				p++;
			}
			if (p < s.len && s[p] == '(')
			{
				int depth = 1;
				p++;
				while (p < s.len && depth > 0)
				{
					if (s[p] == '(')
					{
						depth++;
					}
					else if (s[p] == ')')
					{
						depth--;
					}
					p++;
				}
				s = string::tformat("%s %s", s[:va_idx], s[p..]).trim();
			}
			else
			{
				break;
			}
		}
	}

	s = s.trim_left("() \t").trim_right("() \t");
	if (s.starts_with("__vector "))
	{
		s = s[9..].trim();
	}
	if (s.starts_with("vector "))
	{
		s = s[7..].trim();
	}

	String elem_c3 = map_c_type_to_c3(allocator, s, "");
	if (elem_c3.len == 0)
	{
		elem_c3 = "float";
	}

	sz elem_bytes = DEFAULT_ELEM_BYTES;
	switch (elem_c3)
	{
		case "char":
		case "ichar":
			elem_bytes = 1;
		case "short":
		case "ushort":
			elem_bytes = 2;
		case "int":
		case "uint":
		case "float":
			elem_bytes = 4;
		case "long":
		case "ulong":
		case "double":
			elem_bytes = 8;
		default:
			elem_bytes = DEFAULT_ELEM_BYTES;
	}

	if (elem_count == 0)
	{
		elem_count = vec_bytes / elem_bytes;
		if (elem_count == 0)
		{
			elem_count = DEFAULT_VECTOR_COUNT;
		}
	}

	DString res;
	res.init(allocator);
	res.appendf("%s[<%d>]", elem_c3, (int)elem_count);
	for (int p = 0; p < pointer_depth; p++)
	{
		res.append_char('*');
	}
	return res.str_view().copy(allocator);
}

<*
 Checks if a normalized C type string represents a function pointer or function type.
 Handles Optionals safely.
*>
fn bool is_c_function_pointer(String c_type)
{
	String s = c_type.trim();
	if (try idx = s.index_of("(*)"))
	{
		String rest = s[idx + 3..].trim();
		if (rest.starts_with("["))
		{
			return false;
		}
		if (rest.starts_with("("))
		{
			return true;
		}
	}
	if (try idx = s.index_of("(^)"))
	{
		String rest = s[idx + 3..].trim();
		if (rest.starts_with("["))
		{
			return false;
		}
		if (rest.starts_with("("))
		{
			return true;
		}
	}
	if (s.contains("(") && s.ends_with(")"))
	{
		return true;
	}
	return false;
}

<*
 Translates a C type signature to its C3 representation using systematic decomposition:
 - Pointers to arrays (float (*)[3] -> float[3]*)
 - Array dimensions ([N], [], [*])
 - Pointer depth (*)
 - C99 Complex (_Complex double -> double[2])
 - Standard C primitives
 - Qualifiers (const, volatile, restrict)
*>
fn String map_c_type_to_c3(
	Allocator allocator,
	String c_type,
	String type_prefix,
	bool is_param = false,
	String desugared_type = "",
	bool* out_is_noalias = null,
	bool is_field = false
)
{
	if (out_is_noalias)
	{
		*out_is_noalias = false;
	}

	String s = c_type.trim();
	if (s.len == 0)
	{
		return "void";
	}

	if (out_is_noalias && is_param && (s.contains("restrict") || s.contains("__restrict")))
	{
		*out_is_noalias = true;
	}

	// Function pointers passed as types in fields or nested params without AST collapse to void*
	if (is_c_function_pointer(s))
	{
		return "void*";
	}

	// 1. Pointers to arrays: e.g. "float (*)[3]" or "int (*)[10][20]"
	bool is_ptr_to_array = false;
	String arr_dims = "";
	if (try ptr_idx = s.index_of("(*)"))
	{
		String after = s[ptr_idx + 3..].trim();
		if (after.starts_with("["))
		{
			is_ptr_to_array = true;
			arr_dims = after;
			s = s[:ptr_idx].trim();
		}
	}

	// 2. Trailing array dimensions: e.g. "int[10]" -> dims="[10]", s="int"
	String trailing_dims = "";
	while (s.ends_with("]") && s.contains("["))
	{
		if (try open_b = s.rindex_of_char('['))
		{
			trailing_dims = string::tformat("%s%s", s[open_b..], trailing_dims);
			s = s[:open_b].trim();
		}
		else
		{
			break;
		}
	}
	if (trailing_dims == "[]" || trailing_dims == "[0]")
	{
		trailing_dims = is_field ? "[*]" : "[]";
	}

	// 3. Extract pointer depth and strip qualifiers around '*'
	int elem_pointer_depth = 0;
	while (true)
	{
		s = s.trim();
		if (s.ends_with("const"))        { s = s[:^5].trim_right(); continue; }
		if (s.ends_with("volatile"))     { s = s[:^8].trim_right(); continue; }
		if (s.ends_with("__volatile"))   { s = s[:^10].trim_right(); continue; }
		if (s.ends_with("__volatile__")) { s = s[:^12].trim_right(); continue; }
		if (s.ends_with("restrict"))     { s = s[:^8].trim_right(); continue; }
		if (s.ends_with("__restrict"))   { s = s[:^10].trim_right(); continue; }
		if (s.ends_with("__restrict__")) { s = s[:^12].trim_right(); continue; }
		if (s.ends_with("*"))
		{
			elem_pointer_depth++;
			s = s[:^1].trim_right();
			continue;
		}
		break;
	}

	// 4. Extract C99 complex qualifier
	bool is_complex = false;
	const String[*] COMPLEX_QUALIFIERS = { "_Complex", "complex", "Complex" };
	foreach (cq : COMPLEX_QUALIFIERS)
	{
		if (s.contains(cq))
		{
			is_complex = true;
			s = s.treplace(cq, "").trim();
		}
	}

	// 5. Clean out inline __attribute__((...))
	s = strip_clang_attributes(s);

	// 6. Extract base type using C type-specifier grammar
	String base_c3 = map_c_standard_type(s);
	List{String} clean_words = clean_c_type_words(s);

	if (base_c3.len == 0 && clean_words.len() > 0)
	{
		// Tagged type: struct X, union X, enum X
		for (sz i = 0; i < clean_words.len(); i++)
		{
			String w = clean_words.get(i);
			if ((w == "struct" || w == "union" || w == "enum") && i + 1 < clean_words.len())
			{
				base_c3 = sanitize_c3_type_name(allocator, clean_words.get(i + 1), type_prefix);
				break;
			}
		}

		if (base_c3.len == 0)
		{
			// Suffix standard C type (e.g. "unsigned int", "char")
			for (sz i = 0; i < clean_words.len(); i++)
			{
				DString suffix_sb;
				suffix_sb.tinit();
				for (sz j = i; j < clean_words.len(); j++)
				{
					if (suffix_sb.len() > 0)
					{
						suffix_sb.append_char(' ');
					}
					suffix_sb.append(clean_words.get(j));
				}
				String std_match = map_c_standard_type(suffix_sb.str_view());
				if (std_match.len > 0)
				{
					base_c3 = std_match;
					break;
				}
			}
		}
	
	}

	if (base_c3.len == 0 && desugared_type.len > 0 && desugared_type != c_type)
	{
		String desug_base = extract_base_type_name(desugared_type);
		String desug_std = map_c_standard_type(desug_base);
		if (desug_std.len > 0 && s.starts_with("_"))
		{
			base_c3 = desug_std;
		}
	}

	if (base_c3.len == 0 && clean_words.len() > 0)
	{
		String last_word = clean_words.get(clean_words.len() - 1);
		base_c3 = sanitize_c3_type_name(allocator, last_word, type_prefix);
	}

	if (base_c3.len == 0)
	{
		base_c3 = sanitize_c3_type_name(allocator, s, type_prefix);
	}

	if (is_complex)
	{
		base_c3 = string::format(allocator, "%s[2]", base_c3);
	}

	if (base_c3 == "char" && elem_pointer_depth == 1 && !is_ptr_to_array && c_type.contains("const"))
	{
		if (trailing_dims.len > 0 || arr_dims.len > 0)
		{
			return string::format(allocator, "ZString%s%s", trailing_dims, arr_dims);
		}
		return "ZString";
	}

	if (base_c3 == "void" && elem_pointer_depth == 0 && (trailing_dims.len > 0 || arr_dims.len > 0))
	{
		base_c3 = "char";
	}

	DString res;
	res.init(allocator);
	res.append(base_c3);
	for (int p = 0; p < elem_pointer_depth; p++)
	{
		res.append_char('*');
	}
	if (trailing_dims.len > 0)
	{
		res.append(trailing_dims);
	}
	if (arr_dims.len > 0)
	{
		res.append(arr_dims);
	}
	if (is_ptr_to_array)
	{
		res.append_char('*');
	}

	return res.str_view().copy(allocator);
}