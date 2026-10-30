module analyzer::core;

import std::collections::list;
import analyzer::lexer;

import std::io;

typedef FileID = ushort;

faultdef UNKNOWN_OP_OVERLOAD;

struct Range (Printable)
{
	Location start;
	Location end;
}

fn sz? Range.to_format(Range* self, Formatter* fmt) @dynamic
{
	return fmt.printf("start: %s, end: %s", self.start, self.end);
}

fn bool Range.eq(self, Range other) @operator(==)
{
	return self.start == other.start && self.end == other.end;
}

fn bool Range.contains(self, Location loc)
{
	if (loc.line < self.start.line || loc.line > self.end.line)
	{
		return false;
	}

	if (loc.line == self.start.line && loc.column < self.start.column)
	{
		return false;
	}

	if (loc.line == self.end.line && loc.column >= self.end.column)
	{
		return false;
	}

	return true;
}

fn bool Range.contains_range(self, Range other)
{
	bool start_le = (self.start.line < other.start.line) ||
	(self.start.line == other.start.line &&
	self.start.column <= other.start.column);

	bool end_ge = (self.end.line > other.end.line) ||
	(self.end.line == other.end.line &&
	self.end.column >= other.end.column);

	return start_le && end_ge;
}

struct Location (Printable)
{
	int line;
	int column;
}

fn sz? Location.to_format(Location* self, Formatter* fmt) @dynamic
{
	return fmt.printf("(Line: %d, Column: %d)", self.line + 1, self.column + 1);
}

fn bool Location.eq(self, Location other) @operator(==)
{
	return self.line == other.line && self.column == other.column;
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
	PRIVATE          { "@private",            { .is_function, .is_type, .is_variable, .is_enum, .is_module, .is_import }, "Restricts visibility to current module." },
	PUBLIC           { "@public",             { .is_function, .is_type, .is_variable, .is_enum, .is_module, .is_import }, "Exports symbol with public visibility across modules." },
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

fn AttributeKind get_attribute_from_string(String str)
{
	return AttributeKind::lookup_field(str, str) ?? AttributeKind.NONE;
}

bitstruct TypeFlags : uint
{
	bool is_none;
	bool is_vector;
	bool is_comptime;
	bool is_optional;
}

bitstruct VarDeclFlags : uint
{
	bool is_const;
	bool is_local;
	bool is_extern;
	bool is_thread_local;
	bool is_inline;
	bool is_static;

	bool is_ref;
	// for params
	bool is_self;
	bool is_self_by_ref;
	bool is_variadic;
	bool is_macro_optional_ellipsis;  // For `param = ...`
}

bitstruct ContractFlags : char
{
	bool is_pure;
}

bitstruct ContractParamFlags : char
{
	bool is_ref;
}

bitstruct AsmFlags : char
{
	bool is_volatile;
	bool is_string_style;
}

enum AsmArgKind : char
{
	ARG_REG,  // A register
	ARG_ADDR,  // [...]
	ARG_REGVAR,  // foo - variable in a register, r/=r/+r
	ARG_MEMADDR,  // &foo - address to a variable
	ARG_MEMVAR,  // [&foo]
	ARG_VALUE,  // -1, (expr), 1, 3.0
	ARG_INT,  // Converted from VALUE
}

enum AsmOffsetKind : char
{
	SCALE_1,  // *
	SCALE_2,
	SCALE_4,
	SCALE_8,
	SCALE_SHR,  // >>
	SCALE_SHL,  // <<
	SCALE_ASHL,  // >>>
	SCALE_ROR,  // ror
	SCALE_RRX,  // rrx
}

bitstruct AsmArgBits : uint
{
	bool arg_bits_8;
	bool arg_bits_16;
	bool arg_bits_32;
	bool arg_bits_64;
	bool arg_bits_128;
	bool arg_bits_256;
	bool arg_bits_512;
	bool arg_bits_80;
	bool arg_bits_5;
	bool arg_bits_12;
	bool arg_bits_20;
}

enum AsmRegisterKind : char
{
	REG_INT,
	REG_FLOAT,
	REG_IVEC,
	REF_FVEC,
}

enum OverloadKind : char
{
	UNKNOWN,
	OV_ELEMENT_AT,
	OV_ELEMENT_REF,
	OV_ELEMENT_SET,
	OV_LEN,
	OV_NEGATE,
	OV_UNARY_MINUS,
	OV_PLUS,
	OV_MINUS,
	OV_MULTIPLY,
	OV_DIVIDE,
	OV_REMINDER,
	OV_AND,
	OV_OR,
	OV_XOR,
	OV_SHL,
	OV_SHR,
	OV_EQUAL,
	OV_LESS_THAN,
	OV_PLUS_ASSIGN,
	OV_MINUS_ASSIGN,
	OV_MULTIPLY_ASSIGN,
	OV_DIVIDE_ASSIGN,
	OV_REMINDER_ASSIGN,
	OV_AND_ASSIGN,
	OV_OR_ASSIGN,
	OV_XOR_ASSIGN,
	OV_SHL_ASSIGN,
	OV_SHR_ASSIGN,
}

fn OverloadKind get_overload_kind(TokenKind kind)
{
	switch (kind)
	{
		case PLUS:           return OV_PLUS;
		case PLUS_ASSIGN:    return OV_PLUS_ASSIGN;
		case MINUS:          return OV_MINUS;
		case MINUS_ASSIGN:   return OV_MINUS_ASSIGN;
		case ASTERISK:       return OV_MULTIPLY;
		case MULT_ASSIGN:    return OV_MULTIPLY_ASSIGN;
		case DIV:            return OV_DIVIDE;
		case MOD:            return OV_REMINDER;
		case MOD_ASSIGN:     return OV_REMINDER_ASSIGN;
		case AMP:            return OV_AND;
		case BIT_AND_ASSIGN: return OV_AND_ASSIGN;
		case BIT_OR:         return OV_OR;
		case BIT_OR_ASSIGN:  return OV_OR_ASSIGN;
		case BIT_XOR:        return OV_XOR;
		case BIT_XOR_ASSIGN: return OV_XOR_ASSIGN;
		case LSHIFT:         return OV_SHL;
		case LSHIFT_ASSIGN:  return OV_SHL_ASSIGN;
		case RSHIFT:         return OV_SHR;
		case RSHIFT_ASSIGN:  return OV_SHR_ASSIGN;
		case BIT_NOT:        return OV_NEGATE;
		case EQEQ:           return OV_EQUAL;
		case LESS:           return OV_LESS_THAN;
		default:
			return UNKNOWN;
	}
}

enum InOutModifier : char
{
	ANY,
	IN,
	OUT,
	INOUT,
	OWN,
	DROP,
	INIT,
}

enum Visibility : char
{
	PUBLIC,
	PRIVATE,
	LOCAL
}

<*
 Type expression variants.

 Payload mapping:
- TYPE_IDENTIFIER: TypeExpr.unresolved
- TYPE_POINTER and TYPE_SLICE: TypeExpr.modify
- TYPE_ARRAY and TYPE_VECTOR: TypeExpr.array
- TYPE_GENERIC: TypeExpr.generic
- TYPE_FUNCTION: TypeExpr.func
*>
enum TypeExprKind : char
{
	TYPE_IDENTIFIER,
	TYPE_POINTER,
	TYPE_ARRAY,
	TYPE_SLICE,
	TYPE_VECTOR,
	TYPE_GENERIC,
	TYPE_TYPEOF,
	TYPE_TYPEFROM,
	TYPE_FUNCTION
}

enum DesignatorKind : char
{
	PERIOD,
	INDEX,
	RANGE,
}

enum AccessKind : char
{
	INSTANCE,  // field.
	STATIC  // Type::
}
