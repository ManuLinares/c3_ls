module analyzer::core;
import analyzer::lexer;

faultdef UNKNOWN_OP_OVERLOAD;

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
	bool is_self;
	bool is_self_by_ref;
	bool is_variadic;
	bool is_macro_optional_ellipsis;
}

bitstruct ContractFlags : char
{
	bool is_pure;
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
	INSTANCE,
	STATIC
}

enum OperatorKind
{
	OP_ERROR,
	OP_MULT,
	OP_SUB,
	OP_ADD,
	OP_DIV,
	OP_MOD,
	OP_SHR,
	OP_SHL,
	OP_BIT_OR,
	OP_BIT_XOR,
	OP_BIT_AND,
	OP_AND,
	OP_OR,
	OP_ELSE,
	OP_CT_AND,
	OP_CT_OR,
	OP_CT_CONCAT,
	OP_CT_CONCAT_ASSIGN,

	OP_GT,
	OP_GE,
	OP_LT,
	OP_LE,
	OP_NE,
	OP_EQ,
	OP_VEC_GT,
	OP_VEC_GE,
	OP_VEC_LT,
	OP_VEC_LE,
	OP_VEC_NE,
	OP_VEC_EQ,
	OP_ELVIS,
	OP_ASSIGN,
	OP_ADD_ASSIGN,
	OP_BIT_AND_ASSIGN,
	OP_BIT_OR_ASSIGN,
	OP_BIT_XOR_ASSIGN,
	OP_DIV_ASSIGN,
	OP_MOD_ASSIGN,
	OP_MULT_ASSIGN,
	OP_SHR_ASSIGN,
	OP_SHL_ASSIGN,
	OP_SUB_ASSIGN,
}

fn OperatorKind binaryop_from_token(TokenKind kind)
{
	switch (kind)
	{
		case ASTERISK: return OP_MULT;
		case DIV: return OP_DIV;
		case PLUS: return OP_ADD;
		case MINUS: return OP_SUB;
		case MOD: return OP_MOD;
		case LSHIFT: return OP_SHL;
		case RSHIFT: return OP_SHR;
		case AND: return OP_AND;
		case OR: return OP_OR;
		case CT_AND_OP: return OP_CT_AND;
		case CT_OR_OP: return OP_CT_OR;
		case CT_CONCAT_OP: return OP_CT_CONCAT;
		case CT_CONCAT_ASSIGN: return OP_CT_CONCAT_ASSIGN;
		case QUESTQUEST: return OP_ELSE;
		case AMP: return OP_BIT_AND;
		case BIT_OR: return OP_BIT_OR;
		case BIT_XOR: return OP_BIT_XOR;
		case EQEQ: return OP_EQ;
		case NOT_EQUAL: return OP_NE;
		case LESS: return OP_LT;
		case LESS_EQ: return OP_LE;
		case GREATER: return OP_GT;
		case GREATER_EQ: return OP_GE;
		case EQ: return OP_ASSIGN;
		case MULT_ASSIGN: return OP_MULT_ASSIGN;
		case PLUS_ASSIGN: return OP_ADD_ASSIGN;
		case MINUS_ASSIGN: return OP_SUB_ASSIGN;
		case DIV_ASSIGN: return OP_DIV_ASSIGN;
		case MOD_ASSIGN: return OP_MOD_ASSIGN;
		case BIT_AND_ASSIGN: return OP_BIT_AND_ASSIGN;
		case BIT_OR_ASSIGN: return OP_BIT_OR_ASSIGN;
		case BIT_XOR_ASSIGN: return OP_BIT_XOR_ASSIGN;
		case RSHIFT_ASSIGN: return OP_SHR_ASSIGN;
		case LSHIFT_ASSIGN: return OP_SHL_ASSIGN;
		case ELVIS: return OP_ELVIS;
		default:
			unreachable("unknown binaryop kind: %s", kind);
	}
}

enum VaargKind
{
	VACOUNT,
	VAARG_INDEX
}

enum VarDeclKind : char
{
	VAR_LOCAL,
	VAR_GLOBAL,
	VAR_FIELD,
	VAR_BITFIELD,
	VAR_PARAM,
	VAR_PARAM_CT,
	VAR_PARAM_EXPR,
	VAR_PARAM_CT_TYPE,
}

enum UnaryOpKind : char
{
	UNARYOP_ERROR,
	UNARYOP_DEREF,
	UNARYOP_ADDR,
	UNARYOP_NEG,
	UNARYOP_PLUS,
	UNARYOP_BITNEG,
	UNARYOP_NOT,
	UNARYOP_INC,
	UNARYOP_DEC,
	UNARYOP_TADDR,
}

fn UnaryOpKind? unaryop_from_token(TokenKind kind)
{
	switch (kind)
	{
		case ASTERISK: return UNARYOP_DEREF;
		case AMP: return UNARYOP_ADDR;
		case AND: return UNARYOP_TADDR;
		case BIT_NOT: return UNARYOP_BITNEG;
		case BANG: return UNARYOP_NOT;
		case BANGBANG: return UNARYOP_NOT;
		case MINUS: return UNARYOP_NEG;
		case PLUS: return UNARYOP_PLUS;
		case PLUSPLUS: return UNARYOP_INC;
		case MINUSMINUS: return UNARYOP_DEC;
		default: return NOT_FOUND~;
	}
}

enum AliasDeclKind : char
{
	TYPE_ALIAS,
	MODULE_ALIAS,
	IDENT_ALIAS,
}

enum DeferKind : char
{
	NORMAL,
	TRY,
	CATCH,
	CATCH_VAR
}

enum RangeKind : char
{
	DYNAMIC,
	CONST_END,
	CONST_LEN,
	CONST_RANGE,
	SINGLE_ELEMENT,
}

enum TypeKind : char
{
	TYPE_VOID,
	TYPE_BOOL,
	TYPE_I8,
	TYPE_I16,
	TYPE_I32,
	TYPE_I64,
	TYPE_I128,
	TYPE_U8,
	TYPE_U16,
	TYPE_U32,
	TYPE_U64,
	TYPE_U128,
	TYPE_F16,
	TYPE_BF16,
	TYPE_F32,
	TYPE_F64,
	TYPE_F128,
	TYPE_SZ,
	TYPE_USZ,
	TYPE_IPTR,
	TYPE_UPTR,

	TYPE_STRUCT,
	TYPE_UNION,
	TYPE_BITSTRUCT,
	TYPE_ENUM,
}

enum BitSizes : char (uint bits)
{
	BIT1     { 8 },
	BITS8    { 8 },
	BITS16   { 16 },
	BITS32   { 32 },
	BITS64   { 64 },
	BITS128  { 128 },
	BITS256  { 256 },
}

fn BitSizes int_to_bit_size(sz bits)
{
	switch (bits)
	{
		case 1: return BIT1;
		case 8: return BITS8;
		case 16: return BITS16;
		case 32: return BITS32;
		case 64: return BITS64;
		case 128: return BITS128;
		case 256: return BITS256;
		default: unreachable("Not a valid bit size");
	}
}

enum BuiltinFunction
{
	ABS,
	ANY_MAKE,
	ATOMIC_LOAD,
	ATOMIC_STORE,
	ATOMIC_FETCH_EXCHANGE,
	ATOMIC_FETCH_ADD,
	ATOMIC_FETCH_SUB,
	ATOMIC_FETCH_AND,
	ATOMIC_FETCH_NAND,
	ATOMIC_FETCH_OR,
	ATOMIC_FETCH_XOR,
	ATOMIC_FETCH_MAX,
	ATOMIC_FETCH_MIN,
	ATOMIC_FETCH_INC_WRAP,
	ATOMIC_FETCH_DEC_WRAP,
	BITREVERSE,
	BREAKPOINT,
	BSWAP,
	CEIL,
	COMPARE_EXCHANGE,
	COPYSIGN,
	COS,
	CTLZ,
	CTTZ,
	EXACT_ADD,
	EXACT_DIV,
	EXACT_MOD,
	EXACT_MUL,
	EXACT_NEG,
	EXACT_SUB,
	EXP,
	EXP2,
	EXPECT,
	EXPECT_WITH_PROBABILITY,
	FENCE,
	FLOOR,
	FMA,
	FMULADD,
	FRAMEADDRESS,
	FSHL,
	FSHR,
	GATHER,
	GET_ROUNDING_MODE,
	INT_TO_MASK,
	LOG,
	LOG10,
	LOG2,
	MATRIX_MUL,
	MATRIX_TRANSPOSE,
	MASK_TO_INT,
	MASKED_LOAD,
	MASKED_STORE,
	MAX,
	MEMCOPY,
	MEMCOPY_INLINE,
	MEMMOVE,
	MEMSET,
	MEMSET_INLINE,
	MIN,
	NEARBYINT,
	OVERFLOW_ADD,
	OVERFLOW_MUL,
	OVERFLOW_SUB,
	POPCOUNT,
	POW,
	POW_INT,
	PREFETCH,
	REDUCE_ADD,
	REDUCE_AND,
	REDUCE_FADD,
	REDUCE_FMUL,
	REDUCE_MAX,
	REDUCE_MIN,
	REDUCE_MUL,
	REDUCE_OR,
	REDUCE_XOR,
	REVERSE,
	RETURNADDRESS,
	RINT,
	RND,
	ROUND,
	ROUNDEVEN,
	SAT_ADD,
	SAT_SHL,
	SAT_SUB,
	SAT_MUL,
	SCATTER,
	SELECT,
	SET_ROUNDING_MODE,
	SPRINTF,
	STR_FIND,
	STR_HASH,
	STR_LOWER,
	STR_PASCALCASE,
	STR_REPLACE,
	STR_UPPER,
	STR_SNAKECASE,
	SWIZZLE,
	SWIZZLE2,
	SIN,
	SQRT,
	SYSCALL,
	SYSCLOCK,
	TRAP,
	TRUNC,
	UNALIGNED_LOAD,
	UNALIGNED_STORE,
	UNREACHABLE,
	VECCOMPLT,
	VECCOMPLE,
	VECCOMPGT,
	VECCOMPGE,
	VECCOMPEQ,
	VECCOMPNE,
	VOLATILE_LOAD,
	VOLATILE_STORE,
	WASM_MEMORY_SIZE,
	WASM_MEMORY_GROW,
	WIDESTRING_16,
	WIDESTRING_32,
	NONE,
	LLRINT,
	LLROUND,
	LRINT,
	LROUND,
}