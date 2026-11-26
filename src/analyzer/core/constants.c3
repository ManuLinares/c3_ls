module analyzer::core::constants;
import analyzer::core, analyzer::lexer;

enum PrimitiveKind : char
{
	VOID,
	BOOL,
	INT,
	FLOAT,
	SPECIAL,
	COMPILE_TIME
}

<*
 `size` is in bytes; 0 means pointer-sized, which depends on the target.
*>
enum PrimitiveType : int (String name, TokenKind token, sz size, PrimitiveKind kind, TypeKind type_kind, bool is_signed, String doc)
{
	VOID     { "void",     VOID_TYPE,     1, VOID,    TYPE_VOID,   false, "No value. `void*` is a wildcard pointer that implicitly converts to any other pointer." },
	BOOL     { "bool",     BOOL_TYPE,     1, BOOL,    TYPE_BOOL,   false, "`true` or `false`, stored in a byte." },
	CHAR     { "char",     CHAR_TYPE,     1, INT,     TYPE_U8,     false, "Unsigned 8-bit integer (0 to 255)." },
	ICHAR    { "ichar",    ICHAR_TYPE,    1, INT,     TYPE_I8,     true,  "Signed 8-bit integer (-128 to 127)." },
	SHORT    { "short",    SHORT_TYPE,    2, INT,     TYPE_I16,    true,  "Signed 16-bit integer." },
	USHORT   { "ushort",   USHORT_TYPE,   2, INT,     TYPE_U16,    false, "Unsigned 16-bit integer." },
	INT      { "int",      INT_TYPE,      4, INT,     TYPE_I32,    true,  "Signed 32-bit integer. Decimal literals are `int` unless they do not fit." },
	UINT     { "uint",     UINT_TYPE,     4, INT,     TYPE_U32,    false, "Unsigned 32-bit integer. Literal suffix `u`." },
	LONG     { "long",     LONG_TYPE,     8, INT,     TYPE_I64,    true,  "Signed 64-bit integer. Literal suffix `l`." },
	ULONG    { "ulong",    ULONG_TYPE,    8, INT,     TYPE_U64,    false, "Unsigned 64-bit integer. Literal suffix `ul`." },
	INT128   { "int128",   INT128_TYPE,  16, INT,     TYPE_I128,   true,  "Signed 128-bit integer. Literal suffix `ll`." },
	UINT128  { "uint128",  UINT128_TYPE, 16, INT,     TYPE_U128,   false, "Unsigned 128-bit integer. Literal suffix `ull`." },
	FLOAT16  { "float16",  FLOAT16_TYPE,  2, FLOAT,   TYPE_F16,    true,  "16-bit floating point, widened to `float` before arithmetic. Support is incomplete; not all systems have native support." },
	BFLOAT   { "bfloat",   BFLOAT_TYPE,   2, FLOAT,   TYPE_BF16,   true,  "16-bit floating point in bfloat16 format. Support is incomplete; not all systems have native support." },
	FLOAT    { "float",    FLOAT_TYPE,    4, FLOAT,   TYPE_F32,    true,  "32-bit floating point. Literal suffix `f`." },
	DOUBLE   { "double",   DOUBLE_TYPE,   8, FLOAT,   TYPE_F64,    true,  "64-bit floating point. Floating point literals are `double` by default; suffix `d`." },
	FLOAT128 { "float128", FLOAT128_TYPE,16, FLOAT,   TYPE_F128,   true,  "128-bit floating point. Support is incomplete; not all systems have native support." },
	IPTR     { "iptr",     IPTR_TYPE,     0, INT,     TYPE_IPTR,   true,  "Signed integer with as many bits as a `void*`." },
	UPTR     { "uptr",     UPTR_TYPE,     0, INT,     TYPE_UPTR,   false, "Unsigned integer with as many bits as a `void*`." },
	SZ       { "sz",       SZ_TYPE,       0, INT,     TYPE_SZ,     true,  "Signed integer with as many bits as the maximum difference between two pointers. Usually 64 bits on 64-bit targets." },
	USZ      { "usz",      USZ_TYPE,      0, INT,     TYPE_USZ,    false, "Unsigned counterpart of `sz`. Usually 64 bits on 64-bit targets." },
	ANY      { "any",      ANY_TYPE,     16, SPECIAL, TYPE_STRUCT, false, "Variant: a `typeid` plus a `void*` to a value. Read the type with `.type`; convert with `anycast`." },
	TYPEID   { "typeid",   TYPEID_TYPE,   0, SPECIAL, TYPE_IPTR,   false, "Runtime representation of a type, obtained with `Type::typeid`. Pointer-sized." },
	FAULT    { "fault",    FAULT_TYPE,    0, SPECIAL, TYPE_IPTR,   false, "Why an Optional is empty. Values are defined with `excuse`, are pointer-sized and globally unique; `.description` gives the name." },
	UNTYPEDLIST { "untypedlist", UNTYPEDLIST_TYPE, 0, COMPILE_TIME, TYPE_VOID,   false, "Type of an untyped initializer list such as `{ 1, 2 }`. Compile-time only: usable in type checks like `$Typeof(x) == untypedlist`; no value can have this type." }
}

fn bool PrimitiveType.is_int(self) => self.kind == INT;
fn bool PrimitiveType.is_float(self) => self.kind == FLOAT;

fn bool is_primitive(String name) => @ok(PrimitiveType::lookup_field(name, name));

bitstruct KeywordFlags : uint
{
	bool is_top_level;
	bool is_statement;
	bool is_expression;
	bool is_container;
	bool is_type_decl;
	bool has_type_colon;
}

<*
 `snippet` is the completion text in snippet syntax; when empty the name is inserted.
*>
enum Keyword : int (String name, TokenKind token, KeywordFlags flags, String snippet, String docs)
{
	ALIAS      { "alias",      ALIAS,      { .is_top_level, .is_type_decl }, "", "" },
	ASSERT     { "assert",     ASSERT,     { .is_statement }, "", "" },
	ASM        { "asm",        ASM,        { .is_statement }, "", "" },
	ATTRDEF    { "attrdef",    ATTRDEF,    { .is_top_level }, "", "" },
	ATTRMACRO  { "attrmacro",  ATTRDEF,    { .is_top_level }, "", "" },
	BITSTRUCT  { "bitstruct",  BITSTRUCT,  { .is_top_level, .is_type_decl, .has_type_colon }, "", "" },
	BREAK      { "break",      BREAK,      { .is_statement }, "", "" },
	CASE       { "case",       CASE,       { .is_statement }, "", "" },
	CATCH      { "catch",      CATCH,      { .is_statement }, "", "" },
	CONST      { "const",      CONST,      { .is_top_level, .is_statement }, "", "" },
	CONSTDEF   { "constdef",   CONSTDEF,   { .is_top_level, .is_type_decl, .has_type_colon }, "", "" },
	CONSTSET   { "constset",   CONSTDEF,   { .is_top_level, .is_type_decl, .has_type_colon }, "", "" },
	CONTINUE   { "continue",   CONTINUE,   { .is_statement }, "", "" },
	DEFAULT    { "default",    DEFAULT,    { .is_statement }, "", "" },
	DEFER      { "defer",      DEFER,      { .is_statement }, "", "" },
	DO         { "do",         DO,         { .is_statement }, "", "" },
	ELSE       { "else",       ELSE,       { .is_statement }, "", "" },
	ENUM       { "enum",       ENUM,       { .is_top_level, .is_type_decl, .has_type_colon }, "", "" },
	EXCUSE     { "excuse",     FAULTDEF,   { .is_top_level }, "", "" },
	EXTERN     { "extern",     EXTERN,     { .is_top_level }, "", "" },
	FALSE      { "false",      FALSE,      { .is_expression }, "", "" },
	FAULTDEF   { "faultdef",   FAULTDEF,   { .is_top_level }, "", "" },
	FN         { "fn",         FN,         { .is_top_level }, "", "" },
	FOR        { "for",        FOR,        { .is_statement }, "", "" },
	FOREACH    { "foreach",    FOREACH,    { .is_statement }, "", "" },
	FOREACH_R  { "foreach_r",  FOREACH_R,  { .is_statement }, "", "" },
	IF         { "if",         IF,         { .is_statement }, "", "" },
	INLINE     { "inline",     INLINE,     { .is_container }, "", "" },
	IMPORT     { "import",     IMPORT,     { .is_top_level }, "", "" },
	INTERFACE  { "interface",  INTERFACE,  { .is_top_level, .is_type_decl, .has_type_colon }, "", "" },
	LENGTHOF   { "lengthof",   LENGTHOF,   { .is_statement, .is_expression }, "", "" },
	MACRO      { "macro",      MACRO,      { .is_top_level }, "", "" },
	MODULE     { "module",     MODULE,     { .is_top_level }, "", "module declaration" },
	NEXTCASE   { "nextcase",   NEXTCASE,   { .is_statement }, "", "" },
	NULL       { "null",       NULL,       { .is_expression }, "", "" },
	RETURN     { "return",     RETURN,     { .is_statement }, "", "" },
	STATIC     { "static",     STATIC,     { .is_top_level }, "", "" },
	STRUCT     { "struct",     STRUCT,     { .is_top_level, .is_type_decl }, "", "" },
	SWITCH     { "switch",     SWITCH,     { .is_statement }, "", "" },
	TLOCAL     { "tlocal",     TLOCAL,     { .is_top_level, .is_container }, "", "" },
	TRUE       { "true",       TRUE,       { .is_expression }, "", "" },
	TRY        { "try",        TRY,        { .is_statement }, "", "" },
	TYPEDEF    { "typedef",    TYPEDEF,    { .is_top_level, .is_type_decl }, "", "" },
	UNION      { "union",      UNION,      { .is_top_level, .is_type_decl }, "", "" },
	VAR        { "var",        VAR,        { .is_statement }, "", "" },
	WHILE      { "while",      WHILE,      { .is_statement }, "", "" },
	CT_ASSERT     { "$assert",     CT_ASSERT,     { .is_top_level, .is_statement }, "\\$assert ${1:cond};", "Checks a constant condition at compile time; compilation fails when it is false. An optional message, with format arguments, follows a `:`, as in `$assert $x > 0 : \"bad %s\", $name;`." },
	CT_CASE       { "$case",       CT_CASE,       { .is_statement }, "\\$case ${1:value}:", "A branch of `$switch`: taken when the constant equals the `$switch` value, or, in a `$switch` without a value, when the constant condition is true." },
	CT_DEFAULT    { "$default",    CT_DEFAULT,    { .is_statement }, "\\$default:", "The branch of `$switch` taken when no `$case` matches." },
	CT_DEFINED    { "$defined",    CT_DEFINED,    { .is_expression }, "\\$defined(${1:expr})", "`true` when every expression or type inside is defined and valid; a declaration such as `$defined(int a = foo)` checks that it may be declared. Invalid syntax inside is still an error." },
	CT_ECHO       { "$echo",       CT_ECHO,       { .is_top_level, .is_statement }, "\\$echo ${1:message};", "Prints a constant message to stdout while compiling." },
	CT_ELSE       { "$else",       CT_ELSE,       { .is_statement }, "", "Starts the branch of `$if` kept when the condition is false." },
	CT_EMBED      { "$embed",      CT_EMBED,      { .is_expression }, "\\$embed(${1:path})", "Includes the contents of a file as a constant byte array, which converts like a string literal to `char*`, `void*`, `char[]`, `char[*]` or `String`. An optional second argument limits the number of bytes." },
	CT_ENDFOR     { "$endfor",     CT_ENDFOR,     { .is_statement }, "", "Ends a `$for` loop." },
	CT_ENDFOREACH { "$endforeach", CT_ENDFOREACH, { .is_statement }, "", "Ends a `$foreach` loop." },
	CT_ENDIF      { "$endif",      CT_ENDIF,      { .is_statement }, "", "Ends an `$if`." },
	CT_ENDSWITCH  { "$endswitch",  CT_ENDSWITCH,  { .is_statement }, "", "Ends a `$switch`." },
	CT_ERROR      { "$error",      CT_ERROR,      { .is_top_level, .is_statement }, "\\$error ${1:message};", "Fails compilation with a constant message, followed by optional format arguments." },
	CT_EVAL       { "$eval",       CT_EVAL,       { .is_expression }, "\\$eval(${1:name})", "Converts a compile time string to the variable or function it names, as in `$eval(\"x\") = 3;`." },
	CT_EXEC       { "$exec",       CT_EXEC,       { .is_top_level }, "\\$exec(${1:script});", "Runs a command or script at compile time and compiles its output in place, at the top level. Takes the command, then optionally a `String[]` of arguments and a stdin string. Requires `--trust=full`." },
	CT_EXPAND     { "$expand",     CT_EXPAND,     { .is_top_level, .is_statement }, "\\$expand(${1:code});", "Compiles a constant string as code in place." },
	CT_FEAT       { "$feat",       CT_FEATURE,    { .is_expression }, "\\$feat(${1:NAME})", "`true` when the feature list holds, built from features set with `-D <FEATURE>` combined with `&`, `|`, `!` and parentheses." },
	CT_FEATURE    { "$feature",    CT_FEATURE,    { .is_expression }, "\\$feature(${1:NAME})", "Deprecated: use `$feat`. `true` when the feature, set with `-D <FEATURE>`, is enabled." },
	CT_FOR        { "$for",        CT_FOR,        { .is_statement }, "\\$for ${1:init}; ${2:cond}; ${3:step}:\n\t$0\n\\$endfor", "Compile time `for` loop over compile time variables; the body is repeated for each iteration and must hold complete statements." },
	CT_FOREACH    { "$foreach",    CT_FOREACH,    { .is_statement }, "\\$foreach ${1:\\$x} : ${2:list}:\n\t$0\n\\$endforeach", "Compile time `foreach` over a constant list, such as an enum's `values`; the body is repeated for each element and must hold complete statements." },
	CT_IF         { "$if",         CT_IF,         { .is_statement }, "\\$if ${1:cond}:\n\t$0\n\\$endif", "Keeps the code of the branch the constant condition selects and discards the other, which is not semantically checked." },
	CT_INCLUDE    { "$include",    CT_INCLUDE,    { .is_top_level }, "\\$include(${1:path});", "Compiles the text of a file in place at the top level; the file may not contain a `module` statement. Requires `--trust=include` or `--trust=full`." },
	CT_REFLECT    { "$reflect",    CT_REFLECT,    { .is_expression }, "\\$reflect(${1:value})", "The reflection properties of a value, such as `$reflect(x).name`." },
	CT_STRINGIFY  { "$stringify",  CT_STRINGIFY,  { .is_expression }, "\\$stringify(${1:expr})", "The source text of an expression as a string; mostly used with `#` expression parameters of macros." },
	CT_SWITCH     { "$switch",     CT_SWITCH,     { .is_statement }, "\\$switch ${1:expr}:\n\t$0\n\\$endswitch", "Compile time `switch`: keeps the code of the first matching `$case`, or of `$default`. Without a value, each `$case` holds a constant condition, like an if-else chain." },
	CT_TYPEFROM   { "$Typefrom",   CT_TYPEFROM,   { .is_expression }, "\\$Typefrom(${1:typeid})", "The type a constant `typeid`, or a compile time string, names." },
	CT_TYPEOF     { "$Typeof",     CT_TYPEOF,     { .is_expression }, "\\$Typeof(${1:expr})", "The type of an expression, which is not evaluated, so it has no side effects." },
	CT_VAARG      { "$vaarg",      CT_VAARG,      { .is_expression }, "", "The raw variadic arguments of a `macro m(...)`: `$vaarg[i]` is an argument, `$vaarg.len` their count and `...$vaarg` splats them into a call." },
}

<*
 The keyword as written: its snippet with placeholders shown by name and the cursor stop as `...`.
*>
fn String Keyword.syntax(self)
{
	if (!self.snippet.len) return self.name;
	DString out;
	out.tinit();
	String text = self.snippet;
	for (sz i = 0; i < text.len; i++)
	{
		char c = text[i];
		if (c == '\\' && i + 1 < text.len)
		{
			out.append_char(text[++i]);
		}
		else if (c == '$' && i + 1 < text.len && text[i + 1] == '{')
		{
			// Skip `${n:`; the default text follows. A bare `${n}` is skipped whole.
			i += 2;
			while (i < text.len && text[i].is_digit()) i++;
		}
		else if (c == '$' && i + 1 < text.len && text[i + 1].is_digit())
		{
			out.append("...");
			i++;
		}
		else if (c != '}')
		{
			out.append_char(c);
		}
	}
	return out.str_view();
}

fn bool is_keyword(String name) => @ok(Keyword::lookup_field(name, name));

fn bool is_type_decl_keyword(String name)
{
	if (try kw = Keyword::lookup_field(name, name)) return kw.flags.is_type_decl;
	return false;
}

fn bool keyword_has_type_colon(String name)
{
	if (try kw = Keyword::lookup_field(name, name)) return kw.flags.has_type_colon;
	return false;
}

fn bool is_valid_name(String name)
{
	if (is_primitive(name)) return false;
	if (is_keyword(name)) return false;
	return true;
}

<* Type Property Metadata *>
enum TypeProperty : int (String name, String type_desc, String doc)
{
	ALIGNMENT     { "alignment",     "sz",                  "The standard alignment of the type in bytes." },
	KIND          { "kind",          "TypeKind",            "The category / TypeKind of the type (e.g. POINTER, STRUCT, SIGNED_INT)." },
	NAME          { "name",          "String",              "The short unqualified name of the type as a string." },
	QNAME         { "qname",         "String",              "The fully qualified path name of the type as a string." },
	CNAME         { "cname",         "String",              "The external C linkage name of the type as a string." },
	SIZE          { "size",          "sz",                  "The storage size of the type in bytes." },
	TYPEID        { "typeid",        "typeid",              "The unique runtime / compile-time type identifier." },
	METHODS       { "methods",       "any[]",               "Array of method names implemented for this type." },
	HAS_EQUALS    { "has_equals",    "bool",                "True if the type implements '==' and '!='." },
	IS_ORDERED    { "is_ordered",    "bool",                "True if the type implements comparisons (<, <=, etc.)." },
	INNER         { "inner",         "typeid",              "Returns a typeid to an inner / pointee / base type." },
	GENERIC_ARGS  { "generic_args",  "typeid[]",            "List of typeids representing the generic arguments used to instantiate this generic type." },
	GENERIC_QNAME { "generic_qname", "String",              "Qualified name of the generic template." },
	IS_GENERIC    { "is_generic",    "fn bool(any)",        "Returns true if the type was instantiated from the given generic template." },
	MAX           { "max",           "any",                 "The maximum value for the numeric type." },
	MIN           { "min",           "any",                 "The minimum value for the numeric type." },
	NAN           { "nan",           "any",                 "Representation of floating point NaN." },
	INF           { "inf",           "any",                 "Representation of floating point Infinity." },
	MEMBERS       { "members",       "any[]",               "Compile-time list of members in the struct, union, or enum." },
	GET_TAG       { "get_tag",       "fn any(String)",      "Retrieve the value of a compile-time @tag on the type." },
	HAS_TAG       { "has_tag",       "fn bool(String)",     "Check if a compile-time @tag exists on the type." },
	IS_SUBSTRUCT  { "is_substruct",  "bool",                "True if the struct has an inline member." },
	PARENT        { "parent",        "typeid",              "The typeid of the inline member if present." },
	VALUES        { "values",        "any[]",               "List containing all variants of the enum or constset." },
	LEN           { "len",           "sz",                  "Number of elements in the enum, constset, array, or vector." },
	NAMES         { "names",         "String[]",            "Array of the names of all enum variants." },
	FROM_ORDINAL  { "from_ordinal",  "fn type(sz)",         "Converts an integer ordinal to the corresponding enum variant." },
	LOOKUP_FIELD  { "lookup_field",  "fn any(String, any)", "Lookup an enum variant by associated field value." },
	PARAMS        { "params",        "any[]",               "Function pointer parameter types." },
	RETURNS       { "returns",       "typeid",              "Function pointer return type." },
	PARAM_STRUCT  { "param_struct",  "typeid",              "Struct type mirroring the parameter list." },
}

<* Properties the language gives values of some types, such as `len` of a slice. *>
enum ValueProperty : int (String name, String doc)
{
	LEN     { "len",     "Number of elements in the array, slice, vector or string." },
	PTR     { "ptr",     "Pointer to the elements of the slice or string, or to the value of the `any` or interface." },
	TYPE    { "type",    "Type of the value held by the `any` or interface, or of the fault." },
	ORDINAL { "ordinal", "Position of the value in its enum." },
	DESCRIPTION { "description", "Name of the enum value or fault." },
	KIND    { "kind",    "Kind of the type the `typeid` identifies." },
	SIZE    { "size",    "Size in bytes of the type the `typeid` identifies." },
	PARENT  { "parent",  "Inline member type of the typedef or struct the `typeid` identifies." },
	INNER   { "inner",   "Inner type of the type the `typeid` identifies, for types that have one." },
	NAMES   { "names",   "Names of the values of the enum the `typeid` identifies." },
}

<*
 Compiler builtin functions, called as `$$name(...)`.
 `params` lists the parameters as written in a call; `...` marks further arguments and `= value` a default.
*>
enum Builtin : int (String name, String params, String doc)
{
	MAX                     { "max",                     "a, b", "Returns the larger of two values of the same type: integer, float, or a vector of either, applied per lane. Integers compare signed or unsigned by type." },
	MIN                     { "min",                     "a, b", "Returns the smaller of two values of the same type: integer, float, or a vector of either, applied per lane. Integers compare signed or unsigned by type." },
	ABS                     { "abs",                     "x", "Returns the absolute value of an integer, float, or vector of either, with the argument's type." },
	ACOS                    { "acos",                    "x", "Returns the arc cosine in radians of a float or float vector, per lane, with the argument's type." },
	ASIN                    { "asin",                    "x", "Returns the arc sine in radians of a float or float vector, per lane, with the argument's type." },
	ATAN                    { "atan",                    "x", "Returns the arc tangent in radians of a float or float vector, per lane, with the argument's type." },
	ANY_MAKE                { "any_make",                "ptr, type", "Builds an `any` from a pointer and a `typeid`. The pointer is not checked against the type." },
	ATOMIC_LOAD             { "atomic_load",             "ptr, is_volatile, ordering, align", "Atomically loads and returns the pointee of a typed (non-`void*`) pointer. `is_volatile`, `ordering` (0-6) and `align` (0 or a power of two, 0 means ABI alignment) must be compile-time constants; release and acquire-release orderings are rejected." },
	ATOMIC_STORE            { "atomic_store",            "ptr, value, is_volatile, ordering, align", "Atomically stores `value`, converted to the pointee type, at `ptr`, and evaluates to `value`. Arguments after `value` must be compile-time constants; acquire and acquire-release orderings are rejected." },
	ATOMIC_FETCH_ADD        { "atomic_fetch_add",        "ptr, value, is_volatile, ordering, align", "Atomically adds `value` (integer or float) to `*ptr` and returns the previous value. Arguments after `value` must be compile-time constants; `unordered` is rejected." },
	ATOMIC_FETCH_EXCHANGE   { "atomic_fetch_exchange",   "ptr, value, is_volatile, ordering, align", "Atomically replaces `*ptr` with `value` and returns the previous value. The value cannot be larger than a pointer; the other arguments must be compile-time constants." },
	ATOMIC_FETCH_SUB        { "atomic_fetch_sub",        "ptr, value, is_volatile, ordering, align", "Atomically subtracts `value` (integer or float) from `*ptr` and returns the previous value. Arguments after `value` must be compile-time constants." },
	ATOMIC_FETCH_MAX        { "atomic_fetch_max",        "ptr, value, is_volatile, ordering, align", "Atomically sets `*ptr` to the larger of `*ptr` and `value` and returns the previous value. The comparison is signed, unsigned or float, by the value's type." },
	ATOMIC_FETCH_MIN        { "atomic_fetch_min",        "ptr, value, is_volatile, ordering, align", "Atomically sets `*ptr` to the smaller of `*ptr` and `value` and returns the previous value. The comparison is signed, unsigned or float, by the value's type." },
	ATOMIC_FETCH_AND        { "atomic_fetch_and",        "ptr, value, is_volatile, ordering, align", "Atomically sets `*ptr` to `*ptr & value` (integer or bool) and returns the previous value." },
	ATOMIC_FETCH_NAND       { "atomic_fetch_nand",       "ptr, value, is_volatile, ordering, align", "Atomically sets `*ptr` to `~(*ptr & value)` (integer or bool) and returns the previous value." },
	ATOMIC_FETCH_OR         { "atomic_fetch_or",         "ptr, value, is_volatile, ordering, align", "Atomically sets `*ptr` to `*ptr | value` (integer or bool) and returns the previous value." },
	ATOMIC_FETCH_XOR        { "atomic_fetch_xor",        "ptr, value, is_volatile, ordering, align", "Atomically sets `*ptr` to `*ptr ^ value` (integer or bool) and returns the previous value." },
	ATOMIC_FETCH_INC_WRAP   { "atomic_fetch_inc_wrap",   "ptr, limit, is_volatile, ordering, align", "Atomically increments the unsigned `*ptr`, wrapping to 0 once the old value is at least `limit`, and returns the previous value. The pointee and `limit` must be unsigned integers." },
	ATOMIC_FETCH_DEC_WRAP   { "atomic_fetch_dec_wrap",   "ptr, limit, is_volatile, ordering, align", "Atomically decrements the unsigned `*ptr`, setting it to `limit` when the old value is 0 or greater than `limit`, and returns the previous value. The pointee and `limit` must be unsigned integers." },
	BITREVERSE              { "bitreverse",              "x", "Reverses the bit order of an integer or of each lane of an integer vector, with the argument's type." },
	BREAKPOINT              { "breakpoint",              "", "Breaks into an attached debugger." },
	BSWAP                   { "bswap",                   "x", "Reverses the byte order of an integer or of each lane of an integer vector. With 1-byte elements the argument is returned unchanged." },
	CEIL                    { "ceil",                    "x", "Rounds a float or float vector up to the nearest integral value, with the argument's type." },
	COMPARE_EXCHANGE        { "compare_exchange",        "ptr, expected, desired, is_volatile, is_weak, success_ordering, failure_ordering, align", "Atomically stores `desired` at `ptr` if it holds `expected` and returns the old value. The bools and orderings must be compile-time constants; both orderings must be at least relaxed, and the failure ordering cannot be release or acquire-release." },
	COPYSIGN                { "copysign",                "mag, sgn", "Returns `mag` with the sign of `sgn`. Takes floats or float vectors and returns the type of the first argument." },
	COS                     { "cos",                     "x", "Returns the cosine of a float or float vector, in radians, per lane." },
	COSH                    { "cosh",                    "x", "Returns the hyperbolic cosine of a float or float vector, per lane." },
	CLZ                     { "clz",                     "x", "Counts the leading zero bits of an integer or of each lane of an integer vector, with the argument's type. A zero input gives the bit width." },
	CTZ                     { "ctz",                     "x", "Counts the trailing zero bits of an integer or of each lane of an integer vector, with the argument's type. A zero input gives the bit width." },
	ADD                     { "add",                     "a, b", "Adds two integers of the same type, wrapping on overflow, without the overflow checks `+` gets." },
	DIV                     { "div",                     "a, b", "Divides two integers of the same type, signed or unsigned by type, without division-by-zero or overflow checks." },
	MOD                     { "mod",                     "a, b", "Returns the remainder of two integers of the same type, signed or unsigned by type, without a division-by-zero check." },
	MUL                     { "mul",                     "a, b", "Multiplies two integers of the same type, wrapping on overflow, without the overflow checks `*` gets." },
	NEG                     { "neg",                     "a", "Negates an integer or integer vector, wrapping on overflow, with the argument's type." },
	SUB                     { "sub",                     "a, b", "Subtracts two integers of the same type, wrapping on overflow, without the overflow checks `-` gets." },
	EXP                     { "exp",                     "x", "Returns e raised to a float or float vector, per lane." },
	EXP2                    { "exp2",                    "x", "Returns 2 raised to a float or float vector, per lane." },
	EXP10                   { "exp10",                   "x", "Returns 10 raised to a float or float vector, per lane." },
	EXPECT                  { "expect",                  "value, expected", "Returns `value` and tells the optimizer it usually equals `expected`. Both must be bool or integer of the same type." },
	EXPECT_WITH_PROBABILITY { "expect_with_probability", "value, expected, probability", "Returns `value` and tells the optimizer it equals `expected` with the given probability, a constant `double` from 0 to 1." },
	FENCE                   { "fence",                   "ordering", "Emits a memory fence. `ordering` must be a constant from 3 to 6 (acquire, release, acquire-release, seq_cst)." },
	FLOOR                   { "floor",                   "x", "Rounds a float or float vector down to the nearest integral value, per lane." },
	FMA                     { "fma",                     "a, b, c", "Computes `a * b + c` with a single rounding. Takes three floats or float vectors of the same type." },
	FMULADD                 { "fmuladd",                 "a, b, c", "Computes `a * b + c`, fused or not as the target prefers. Takes three floats of the same type." },
	FRAMEADDRESS            { "frameaddress",            "level", "Returns, as `void*`, the frame address of the function `level` frames up the call stack (0 is the current one). `level` must be a constant integer." },
	FSHL                    { "fshl",                    "hi, lo, shift", "Joins `hi:lo`, shifts left by `shift` modulo the bit width and returns the high half. Takes integers or integer vectors of the same type; `$$fshl(x, x, n)` rotates left." },
	FSHR                    { "fshr",                    "hi, lo, shift", "Joins `hi:lo`, shifts right by `shift` modulo the bit width and returns the low half. Takes integers or integer vectors of the same type; `$$fshr(x, x, n)` rotates right." },
	GATHER                  { "gather",                  "ptrs, mask, passthru, align", "Loads each lane through a vector of pointers where `mask` is true and takes the `passthru` lane elsewhere. `align` must be 0 or a constant power of two." },
	GET_ROUNDING_MODE       { "get_rounding_mode",       "", "Returns the current floating-point rounding mode as an `int`." },
	INT_TO_MASK             { "int_to_mask",             "value, len", "Turns the low `len` bits of an integer into a `bool[<len>]` mask. `len` must be a nonzero constant no larger than the integer's bit width." },
	LOG                     { "log",                     "x", "Returns the natural logarithm of a float or float vector, per lane." },
	LOG2                    { "log2",                    "x", "Returns the base-2 logarithm of a float or float vector, per lane." },
	LOG10                   { "log10",                   "x", "Returns the base-10 logarithm of a float or float vector, per lane." },
	MASK_TO_INT             { "mask_to_int",             "mask", "Packs a bool vector of at most 128 lanes into an unsigned integer, at least 8 bits wide and a power of two." },
	MASKED_LOAD             { "masked_load",             "ptr, mask, passthru, align", "Loads a vector from `ptr`, taking `passthru` lanes where `mask` is false. `align` must be 0 or a constant power of two." },
	MASKED_STORE            { "masked_store",            "ptr, value, mask, align", "Stores the lanes of vector `value` to `ptr` only where `mask` is true. `align` must be 0 or a constant power of two." },
	MATRIX_MUL              { "matrix_mul",              "a, b, rows, inner, cols", "Multiplies a `rows x inner` matrix by an `inner x cols` matrix, both flat column-major vectors with the same element type, and returns a `rows * cols` vector. The dimensions must be constants." },
	MATRIX_TRANSPOSE        { "matrix_transpose",        "m, rows, cols", "Transposes a `rows x cols` matrix stored as a flat vector. `rows` and `cols` must be constants." },
	MEMCPY                  { "memcpy",                  "dst, src, len, is_volatile, dst_align, src_align", "Copies `len` bytes between regions that must not overlap. `is_volatile` and both alignments (0 or a power of two) must be constants." },
	MEMCPY_INLINE           { "memcpy_inline",           "dst, src, len, is_volatile, dst_align, src_align", "Same as `$$memcpy` but with a constant `len`, always expanded inline." },
	MEMMOVE                 { "memmove",                 "dst, src, len, is_volatile, dst_align, src_align", "Copies `len` bytes between regions that may overlap. `is_volatile` and both alignments must be constants." },
	MEMSET                  { "memset",                  "dst, value, len, is_volatile, align", "Fills `len` bytes at `dst` with the `char` `value`. `is_volatile` and `align` must be constants." },
	MEMSET_INLINE           { "memset_inline",           "dst, value, len, is_volatile, align", "Same as `$$memset` but with a constant `len`, always expanded inline." },
	NEARBYINT               { "nearbyint",               "x", "Rounds a float or float vector to an integral value in the current rounding mode, without raising the inexact exception." },
	OVERFLOW_ADD            { "overflow_add",            "a, b, out", "Stores `a + b` in `*out` and returns whether it overflowed. Takes integers or integer vectors of the same type; vectors give a bool vector." },
	OVERFLOW_SUB            { "overflow_sub",            "a, b, out", "Stores `a - b` in `*out` and returns whether it overflowed. Takes integers or integer vectors of the same type; vectors give a bool vector." },
	OVERFLOW_MUL            { "overflow_mul",            "a, b, out", "Stores `a * b` in `*out` and returns whether it overflowed. Takes integers or integer vectors of the same type; vectors give a bool vector." },
	POPCOUNT                { "popcount",                "x", "Counts the set bits of an integer or of each lane of an integer vector, with the argument's type." },
	POW                     { "pow",                     "base, exp", "Raises a float or float vector to a power of the same type, per lane." },
	POW_INT                 { "pow_int",                 "base, exp", "Raises a float or float vector to an integer power." },
	PREFETCH                { "prefetch",                "ptr, rw, locality", "Hints that the data at `ptr` should be cached. `rw` is a constant 0 (read) or 1 (write), `locality` a constant from 0 to 3." },
	REDUCE_ADD              { "reduce_add",              "vec", "Returns the sum of all lanes of an integer or bool vector." },
	REDUCE_AND              { "reduce_and",              "vec", "Returns the bitwise and of all lanes of an integer or bool vector." },
	REDUCE_FADD             { "reduce_fadd",             "vec, start", "Returns `start` plus every lane of a float vector." },
	REDUCE_FMUL             { "reduce_fmul",             "vec, start", "Returns `start` times every lane of a float vector." },
	REDUCE_MAX              { "reduce_max",              "vec", "Returns the largest lane of an integer, float or bool vector, comparing signed, unsigned or float by element type." },
	REDUCE_MIN              { "reduce_min",              "vec", "Returns the smallest lane of an integer, float or bool vector, comparing signed, unsigned or float by element type." },
	REDUCE_MUL              { "reduce_mul",              "vec", "Returns the product of all lanes of an integer or bool vector." },
	REDUCE_OR               { "reduce_or",               "vec", "Returns the bitwise or of all lanes of an integer or bool vector." },
	REDUCE_XOR              { "reduce_xor",              "vec", "Returns the bitwise xor of all lanes of an integer or bool vector." },
	REVERSE                 { "reverse",                 "vec", "Returns a vector with its lanes in reverse order." },
	RETURNADDRESS           { "returnaddress",           "level", "Returns, as `void*`, the return address of the function `level` frames up the call stack (0 is the current one). `level` must be a constant integer." },
	RINT                    { "rint",                    "x", "Rounds a float or float vector to an integral value in the current rounding mode, possibly raising the inexact exception." },
	RND                     { "rnd",                     "", "A random compile-time constant `double` in [0, 1), not cryptographically secure." },
	ROUND                   { "round",                   "x", "Rounds a float or float vector to the nearest integral value, halfway cases away from zero." },
	ROUNDEVEN               { "roundeven",               "x", "Rounds a float or float vector to the nearest integral value, halfway cases to even." },
	SAT_ADD                 { "sat_add",                 "a, b", "Adds two integers or integer vectors of the same type, clamping to the type's minimum or maximum instead of wrapping." },
	SAT_MUL                 { "sat_mul",                 "a, b", "Multiplies two integers or integer vectors of the same type, clamping to the type's minimum or maximum instead of wrapping." },
	SAT_SHL                 { "sat_shl",                 "a, b", "Shifts `a` left by `b`, clamping to the type's minimum or maximum when bits would be lost. Takes integers or integer vectors of the same type." },
	SAT_SUB                 { "sat_sub",                 "a, b", "Subtracts `b` from `a` for integers or integer vectors of the same type, clamping to the type's minimum or maximum instead of wrapping." },
	SCATTER                 { "scatter",                 "ptrs, value, mask, align", "Stores each lane of `value` through the matching pointer of a pointer vector, only where `mask` is true. `align` must be 0 or a constant power of two." },
	SELECT                  { "select",                  "mask, a, b", "Returns a vector taking each lane from `a` where `mask` is true and from `b` elsewhere." },
	SET_ROUNDING_MODE       { "set_rounding_mode",       "mode", "Sets the floating-point rounding mode from an integer." },
	SIN                     { "sin",                     "x", "Returns the sine of a float or float vector, in radians, per lane." },
	SINH                    { "sinh",                    "x", "Returns the hyperbolic sine of a float or float vector, per lane." },
	STR_HASH                { "str_hash",                "s", "Returns the a5hash of a constant string as a constant `uint`." },
	STR_UPPER               { "str_upper",               "s", "Returns a constant string with ASCII letters in upper case." },
	STR_LOWER               { "str_lower",               "s", "Returns a constant string with ASCII letters in lower case." },
	STR_FIND                { "str_find",                "haystack, needle", "Returns the byte index of the first `needle` in `haystack` as a constant `sz`, or -1. Both must be constant strings." },
	STR_PASCALCASE          { "str_pascalcase",          "s", "Converts a constant string to PascalCase, dropping non-alphanumeric characters." },
	STR_SNAKECASE           { "str_snakecase",           "s", "Converts a constant string to snake_case." },
	STR_REPLACE             { "str_replace",             "s, pattern, replacement, limit", "Replaces up to `limit` occurrences (0 for all) of `pattern` in a constant string. All arguments must be constants." },
	SWIZZLE                 { "swizzle",                 "vec, i0, ...", "Returns a vector of the lanes of `vec` at the given constant indices, one lane per index." },
	SWIZZLE2                { "swizzle2",                "a, b, i0, ...", "Returns a vector of the lanes of `a` and `b` joined end to end, at the given constant indices." },
	SPRINTF                 { "sprintf",                 "fmt, args...", "Formats constant arguments into a constant string. Only `%s` and `%%` are supported, and every argument must be used." },
	SQRT                    { "sqrt",                    "x", "Returns the square root of a float or float vector, per lane." },
	SYSCALL                 { "syscall",                 "nr, args...", "Makes a system call with up to 6 `uptr` arguments and returns its result as `uptr`. Supported on AArch64, x86, x86_64 and RISC-V." },
	SYSCLOCK                { "sysclock",                "", "Returns the CPU cycle counter as a `ulong`." },
	TAN                     { "tan",                     "x", "Returns the tangent of a float or float vector, in radians, per lane." },
	TANH                    { "tanh",                    "x", "Returns the hyperbolic tangent of a float or float vector, per lane." },
	TRAP                    { "trap",                    "", "Aborts execution with a trap instruction." },
	TRUNC                   { "trunc",                   "x", "Rounds a float or float vector toward zero to an integral value, per lane." },
	VECCOMPLT               { "veccomplt",               "a, b", "Compares two numeric vectors lane by lane with `<` and returns a bool vector." },
	VECCOMPLE               { "veccomple",               "a, b", "Compares two numeric vectors lane by lane with `<=` and returns a bool vector." },
	VECCOMPGT               { "veccompgt",               "a, b", "Compares two numeric vectors lane by lane with `>` and returns a bool vector." },
	VECCOMPGE               { "veccompge",               "a, b", "Compares two numeric vectors lane by lane with `>=` and returns a bool vector." },
	VECCOMPEQ               { "veccompeq",               "a, b", "Compares two numeric vectors lane by lane with `==` and returns a bool vector." },
	VECCOMPNE               { "veccompne",               "a, b", "Compares two numeric vectors lane by lane with `!=` and returns a bool vector." },
	UNREACHABLE             { "unreachable",             "", "Marks a point that is never reached; it does not return." },
	UNALIGNED_LOAD          { "unaligned_load",          "ptr, align, is_volatile", "Loads the pointee of a typed pointer, assuming only the constant power-of-two alignment `align`." },
	UNALIGNED_STORE         { "unaligned_store",         "ptr, value, align, is_volatile", "Stores `value` at `ptr`, assuming only the constant power-of-two alignment `align`, and evaluates to `value`." },
	VOLATILE_LOAD           { "volatile_load",           "ptr", "Loads the pointee of a typed pointer with a volatile load." },
	VOLATILE_STORE          { "volatile_store",          "ptr, value", "Stores `value` at `ptr` with a volatile store and evaluates to `value`." },
	WASM_MEMORY_GROW        { "wasm_memory_grow",        "mem_index, delta", "Grows WebAssembly memory `mem_index` by `delta` pages and returns the previous size as `iptr`, or -1 on failure or on other targets." },
	WASM_MEMORY_SIZE        { "wasm_memory_size",        "mem_index", "Returns the size of WebAssembly memory `mem_index` in pages, or 0 on other targets." },
	WSTR16                  { "wstr16",                  "s, zero_terminate = true", "Converts a constant UTF-8 string to a constant `ushort[]` of UTF-16 code units. Codepoints above U+FFFF are rejected." },
	WSTR32                  { "wstr32",                  "s, zero_terminate = true", "Converts a constant UTF-8 string to a constant `uint[]` of codepoints." },
}

fn String Builtin.signature(self) => string::tformat("$$%s(%s)", self.name, self.params);

<*
 Compiler builtin constants, written `$$NAME`.
*>
enum BuiltinConstant : int (String name, String doc)
{
	DATE                    { "DATE",                    "The compile date in local time, as a constant `YYYY-MM-DD` string." },
	FILE                    { "FILE",                    "The name of the current source file, as a constant string." },
	FILEPATH                { "FILEPATH",                "The full path of the current source file, as a constant string." },
	FUNCTION                { "FUNCTION",                "The enclosing function itself, as if its name were written here." },
	FUNC                    { "FUNC",                    "The name of the enclosing function as a constant string: `Type.method` for methods, `<GLOBAL>` outside functions." },
	LINE                    { "LINE",                    "The current source line as a constant `sz`. In a macro it is the line of the outermost call." },
	LINE_RAW                { "LINE_RAW",                "The line where `$$LINE_RAW` is written, as a constant `sz`, even in a macro body." },
	MODULE                  { "MODULE",                  "The name of the current module as a constant string. In a macro it is the module of the calling code." },
	PANIC_FN                { "PANIC_FN",                "The panic function, `fn void(String, String, String, int, String, any[])`, set with `--panicfn`." },
	TIME                    { "TIME",                    "The compile time in local time, as a constant `HH:MM:SS` string." },
	BENCHMARK_NAMES         { "BENCHMARK_NAMES",         "The names of all benchmarks as a `String[]` in a benchmark build, empty otherwise." },
	BENCHMARK_FNS           { "BENCHMARK_FNS",           "Pointers to all benchmark functions as a `void*[]`, in the order of `$$BENCHMARK_NAMES`." },
	TEST_NAMES              { "TEST_NAMES",              "The names of all tests as a `String[]` in a test build, empty otherwise." },
	TEST_FNS                { "TEST_FNS",                "Pointers to all test functions as a `void*[]`, in the order of `$$TEST_NAMES`." },
	C_SHORT_SIZE            { "C_SHORT_SIZE",            "Size in bits of the C `short` type on the target, as an `int`." },
	C_INT_SIZE              { "C_INT_SIZE",              "Size in bits of the C `int` type on the target, as an `int`." },
	C_LONG_SIZE             { "C_LONG_SIZE",             "Size in bits of the C `long` type on the target, as an `int`." },
	C_LONG_LONG_SIZE        { "C_LONG_LONG_SIZE",        "Size in bits of the C `long long` type on the target, as an `int`." },
	C_CHAR_IS_SIGNED        { "C_CHAR_IS_SIGNED",        "Whether the C `char` type is signed on the target, as a `bool`." },
	REGISTER_SIZE           { "REGISTER_SIZE",           "Size in bits of an integer register on the target, as an `int`." },
	MAX_VECTOR_SIZE         { "MAX_VECTOR_SIZE",         "Largest vector size in bits the build allows, as an `int`." },
	JMP_BUF_SIZE            { "JMP_BUF_SIZE",            "Number of `uptr` elements in a C `jmp_buf` on the target, as an `int`. Sizes `libc::JmpBuf`." },
	ARCH_TYPE               { "ARCH_TYPE",               "The target architecture as an ordinal of `env::ArchType`, as an `int`. `env::ARCH_TYPE` holds the enum value." },
	OS_TYPE                 { "OS_TYPE",                 "The target operating system as an ordinal of `env::OsType`, as an `int`. `env::OS_TYPE` holds the enum value." },
	MEMORY_ENVIRONMENT      { "MEMORY_ENVIRONMENT",      "The memory environment as an ordinal of `env::MemoryEnvironment` (`NORMAL`, `SMALL`, `TINY`, `NONE`), as an `int`. `env::MEMORY_ENV` holds the enum value." },
	COMPILER_OPT_LEVEL      { "COMPILER_OPT_LEVEL",      "The optimization level, 0 to 3 for `-O0` to `-O3`, as an `int`. `env::COMPILER_OPT_LEVEL` holds it as an `env::CompilerOptLevel`." },
	COMPILER_SIZE_OPT_LEVEL { "COMPILER_SIZE_OPT_LEVEL", "The size optimization, 0 for none, 1 for `-Os` and 2 for `-Oz`, as an `int`." },
	LLVM_VERSION            { "LLVM_VERSION",            "Major version of the LLVM the compiler uses, as an `int`, or 0 without LLVM." },
	VERSION                 { "VERSION",                 "The compiler version, as a constant string." },
	PRERELEASE              { "PRERELEASE",              "Whether the compiler is a pre-release, as a `bool`." },
	LANGUAGE_DEV_VERSION    { "LANGUAGE_DEV_VERSION",    "The development version of the language the compiler implements, as an `int`." },
	BUILD_HASH              { "BUILD_HASH",              "The git hash the compiler was built from, as a constant string." },
	BUILD_DATE              { "BUILD_DATE",              "The date the compiler was built, as a constant `YYYY-MM-DD` string." },
	PROJECT_PATH            { "PROJECT_PATH",            "The directory of the project being compiled, as a constant string." },
	PROJECT_VERSION         { "PROJECT_VERSION",         "The version of the project being compiled, as a constant string." },
	AUTHORS                 { "AUTHORS",                 "The names of the project's authors, as a list of constant strings." },
	AUTHOR_EMAILS           { "AUTHOR_EMAILS",           "The emails of the project's authors, in the order of `$$AUTHORS`, empty for an author without one." },
}

<*
 Tags of a doc contract, such as `@param`.
*>
enum DocTag : int (String name, String syntax, String doc)
{
	PARAM      { "param",      "@param [<ref>] <param> [: <description>]",                          "Documents a parameter. For a pointer, `[in]` forbids writing through it, `[out]` reading, `[inout]` allows both, and `&` (`[&in]`) also requires it to be non-null. `[own]`, `[drop]` and `[init]` say the function keeps the pointer, invalidates what it points to, or initializes it." },
	RETURN     { "return",     "@return <description>",                                             "Documents the return value." },
	RETURN_OPT { "return?",    "@return? [<func>!], [<fault1>, <fault2>, ...] [: <description>]",   "Documents the faults the function may return. `<func>!` includes every fault `<func>` returns." },
	REQUIRE    { "require",    "@require [<param>] <expr1>, <expr2>, ... [: <description>]",        "Pre-condition: each expression must be true when the function is called. `[<param>]` names the parameter a violation is reported against." },
	ENSURE     { "ensure",     "@ensure <expr1>, <expr2>, ... [: <description>]",                   "Post-condition: each expression must be true when the function returns, where `return` is the returned value." },
	DEPRECATED { "deprecated", "@deprecated [<description>]",                                       "Marks the declaration as deprecated: using it gives a warning." },
	PURE       { "pure",       "@pure",                                                             "Declares that the function does not change global variables, so it may not call a function known to be impure. The compiler might not detect a wrong `@pure`." },
}

<* Reflection Property Metadata *>
enum ReflectProperty : int (String name, String type_desc, String doc)
{
	ALIGNMENT    { "alignment",    "sz",             "The standard alignment of the expression in bytes." },
	BITOFFSET    { "bitoffset",    "sz",             "The bit offset of a bitstruct member within its backing type." },
	BITSIZE      { "bitsize",      "sz",             "The size in bits of a bitstruct member." },
	CNAME        { "cname",        "String",         "The external linker name of the symbol." },
	GET_TAG      { "get_tag",      "fn any(String)", "Retrieve the value of a compile-time tag on the expression." },
	HAS_TAG      { "has_tag",      "fn bool(String)","Check if a compile-time tag exists on the expression." },
	NAME         { "name",         "String",         "The unqualified local name of the symbol." },
	OFFSET       { "offset",       "sz",             "The byte offset of a member in a struct." },
	PARAM_STRUCT { "param_struct", "typeid",         "The parameter struct type for a function." },
	QNAME        { "qname",        "String",         "The fully qualified path name of the symbol." },
	SIZE         { "size",         "sz",             "The size of the expression in bytes." },
	TYPE         { "type",         "typeid",         "The runtime typeid of the reflected expression." },
}

bitstruct AttributeTargetMask : ushort
{
	bool is_function;
	bool is_type;
	bool is_variable;
	bool is_field;
	bool is_enum;
	bool is_enum_member;
	bool is_module;
	bool is_import;
	bool is_parameter;
	bool is_call;
	bool is_switch;
}

enum AttributeKind : int (String str, AttributeTargetMask targets, String doc)
{
	ALIGN            { "@align",             { .is_type, .is_variable, .is_field, .is_function }, "Sets the minimum alignment in bytes." },
	ALLOW_DEPRECATED { "@allow_deprecated",   { .is_function }, "Suppresses deprecation warnings in this function." },
	ASMNAME          { "@asmname",            { .is_function, .is_variable }, "Sets external linkage name without platform decoration." },
	BENCHMARK        { "@benchmark",          { .is_function }, "Marks the function as a benchmark." },
	BIGENDIAN        { "@bigendian",          { .is_type }, "Lays out bitstruct fields in big-endian order." },
	BUILTIN          { "@builtin",            { .is_function, .is_variable }, "Allows symbol to be accessed without module path prefix." },
	CALLCONV         { "@callconv",           { .is_function }, "Sets calling convention ('cdecl', 'stdcall', 'veccall')." },
	CNAME            { "@cname",              { .is_function, .is_variable, .is_type, .is_enum }, "Sets external C symbol linkage name." },
	COMPACT          { "@compact",            { .is_type }, "Recursively removes all padding from struct or union." },
	CONST            { "@const",              { .is_function }, "Ensures a macro is always compile-time folded to a constant." },
	CONSTINIT        { "@constinit",          { .is_type, .is_enum, .is_variable }, "Allows typedef or constset initialization from literals without cast." },
	DEPRECATED       { "@deprecated",         { .is_function, .is_type, .is_variable, .is_field, .is_enum, .is_enum_member }, "Marks declaration as deprecated." },
	DYNAMIC          { "@dynamic",            { .is_function }, "Marks method for dynamic interface invocation." },
	EXPORT           { "@export",             { .is_function, .is_variable, .is_type, .is_enum }, "Exports symbol with public visibility in library binary." },
	EXTERN           { "@extern",             { .is_function, .is_variable }, "Declares external linkage." },
	FEAT             { "@feat",               { .is_function, .is_type, .is_variable, .is_field, .is_enum, .is_module }, "Conditionally compiles declaration based on feature flags." },
	FINALIZER        { "@finalizer",          { .is_function }, "Executes function on program shutdown." },
	FORMAT           { "@format",             { .is_function }, "Enables compile-time format string validation." },
	IF               { "@if",                 { .is_function, .is_type, .is_field, .is_enum_member }, "Conditionally includes declaration in generic context." },
	INLINE           { "@inline",             { .is_function, .is_call }, "Forces function or call-site inlining." },
	INIT             { "@init",               { .is_function }, "Executes function on program startup before main." },
	JUMP             { "@jump",               { .is_switch }, "Guarantees switch statement compiles to a jump table." },
	LINK             { "@link",               { .is_module, .is_function, .is_variable }, "Specifies library dependencies to link automatically." },
	LITTLEENDIAN     { "@littleendian",       { .is_type }, "Lays out bitstruct fields in little-endian order." },
	LOCAL            { "@local",              { .is_function, .is_type, .is_variable, .is_enum, .is_module }, "Restricts visibility to current module section." },
	MAYDISCARD       { "@maydiscard",         { .is_function }, "Allows discarding return value even if Optional." },
	MUSTINIT         { "@mustinit",           { .is_type }, "Disallows @noinit on variables of this type." },
	NAKED            { "@naked",              { .is_function }, "Disables function prologue and epilogue generation." },
	NOALIAS          { "@noalias",            { .is_parameter }, "Asserts pointer parameter does not alias any other pointer (C restrict)." },
	NODISCARD        { "@nodiscard",          { .is_function }, "Emits warning if function return value is discarded." },
	NOINIT           { "@noinit",             { .is_variable, .is_field }, "Disables zero-initialization for variable or field." },
	NOINLINE         { "@noinline",           { .is_function, .is_call }, "Prevents inlining of function or call site." },
	NOPADDING        { "@nopadding",          { .is_type }, "Ensures struct or union has zero padding bytes." },
	NORECURSE        { "@norecurse",          { .is_import }, "Imports module without recursively importing its submodules." },
	NOREDZONE        { "@noredzone",          { .is_function }, "Disables red zone usage for function." },
	NORETURN         { "@noreturn",           { .is_function }, "Declares that the function never returns." },
	NOSANITIZE       { "@nosanitize",         { .is_function }, "Disables sanitizers for function." },
	NOSTACKPROBE     { "@nostackprobe",       { .is_function }, "Disables stack probing for function." },
	NOSTACKPROTECTOR { "@nostackprotector",   { .is_function }, "Disables stack protector for function." },
	NOSTRIP          { "@nostrip",            { .is_function, .is_type, .is_variable, .is_enum }, "Prevents linker from stripping symbol." },
	OBFUSCATE        { "@obfuscate",          { .is_function, .is_type, .is_enum }, "Strips reflection strings and metadata." },
	OPERATOR         { "@operator",           { .is_function }, "Overloads an operator (+, -, *, [], len, etc.)." },
	OPERATOR_R       { "@operator_r",         { .is_function }, "Defines reverse operator overload." },
	OPERATOR_S       { "@operator_s",         { .is_function }, "Defines symmetric operator overload." },
	OPTIONAL         { "@optional",           { .is_function }, "Marks interface method as optional to implement." },
	OVERLAP          { "@overlap",            { .is_type }, "Allows overlapping bit ranges in bitstruct." },
	PACKED           { "@packed",             { .is_type }, "Sets struct/union member alignment to 1 byte." },
	PRIVATE          { "@private",            { .is_function, .is_type, .is_variable, .is_enum, .is_module }, "Restricts visibility to current module." },
	PUBLIC           { "@public",             { .is_function, .is_type, .is_variable, .is_enum, .is_module, .is_import }, "Exports symbol with public visibility across modules. On an import, also grants access to the imported modules' `@private` symbols." },
	PURE             { "@pure",               { .is_function, .is_call }, "Asserts function does not read or write global state." },
	REFLECT          { "@reflect",            { .is_function, .is_type, .is_variable, .is_enum }, "Enables extra reflection metadata." },
	SAFEINFER        { "@safeinfer",          { .is_function }, "Enables safe inference for function or macro." },
	SAFEMACRO        { "@safemacro",          { .is_function }, "Allows macro to drop leading @ prefix." },
	SECTION          { "@section",            { .is_function, .is_variable }, "Places function or global in specific binary section." },
	SIMD             { "@simd",               { .is_type }, "Conforms vector type to C SIMD ABI." },
	STRUCTLIKE       { "@structlike",         { .is_type }, "Marks type as struct-like." },
	TAG              { "@tag",                { .is_function, .is_type, .is_variable, .is_field, .is_parameter }, "Attaches a compile-time key-value tag." },
	TEST             { "@test",               { .is_function, .is_module }, "Marks function or module section as a test." },
	UNUSED           { "@unused",             { .is_function, .is_type, .is_variable, .is_field, .is_parameter, .is_enum_member }, "Suppresses unused warning." },
	USED             { "@used",               { .is_function, .is_type, .is_variable, .is_field, .is_parameter, .is_enum_member }, "Requires parameter or variable to be used." },
	WASM             { "@wasm",               { .is_function, .is_variable }, "WebAssembly export and import configuration." },
	WEAK             { "@weak",               { .is_function, .is_variable, .is_module }, "Emits symbol with weak linkage." },
	WINMAIN          { "@winmain",            { .is_function }, "Generates Windows WinMain entry point." },
	NONE             { "",                    {}, "" }
}
