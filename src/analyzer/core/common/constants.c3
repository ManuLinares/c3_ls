module analyzer::core::constants;

import analyzer::lexer;

const String KW_AT_DEPRECATED = "@deprecated";
const String KW_AT_PURE       = "@pure";
const String KW_AT_ENSURE     = "@ensure";
const String KW_AT_REQUIRE    = "@require";
const String KW_AT_PARAM      = "@param";
const String KW_AT_RETURN     = "@return";

const String KW_LEN = "len";
const String STD_CORE = "std::core";

enum PrimitiveKind : char
{
	VOID,
	BOOL,
	INT,
	FLOAT,
	SPECIAL
}

enum PrimitiveType : int (String name, TokenKind token, sz size, PrimitiveKind kind, bool is_signed)
{
	VOID     { "void",     VOID_TYPE,     0, VOID,    false },
	BOOL     { "bool",     BOOL_TYPE,     1, BOOL,    false },
	CHAR     { "char",     CHAR_TYPE,     1, INT,     false },
	ICHAR    { "ichar",    ICHAR_TYPE,    1, INT,     true  },
	SHORT    { "short",    SHORT_TYPE,    2, INT,     true  },
	USHORT   { "ushort",   USHORT_TYPE,   2, INT,     false },
	INT      { "int",      INT_TYPE,      4, INT,     true  },
	UINT     { "uint",     UINT_TYPE,     4, INT,     false },
	LONG     { "long",     LONG_TYPE,     8, INT,     true  },
	ULONG    { "ulong",    ULONG_TYPE,    8, INT,     false },
	INT128   { "int128",   INT128_TYPE,  16, INT,     true  },
	UINT128  { "uint128",  UINT128_TYPE, 16, INT,     false },
	FLOAT16  { "float16",  FLOAT16_TYPE,  2, FLOAT,   true  },
	BFLOAT   { "bfloat",   BFLOAT_TYPE,   2, FLOAT,   true  },
	FLOAT    { "float",    FLOAT_TYPE,    4, FLOAT,   true  },
	DOUBLE   { "double",   DOUBLE_TYPE,   8, FLOAT,   true  },
	FLOAT128 { "float128", FLOAT128_TYPE,16, FLOAT,   true  },
	IPTR     { "iptr",     IPTR_TYPE,     0, INT,     true  },
	UPTR     { "uptr",     UPTR_TYPE,     0, INT,     false },
	SZ       { "sz",       SZ_TYPE,       0, INT,     true  },
	USZ      { "usz",      USZ_TYPE,      0, INT,     false },
	ANY      { "any",      ANY_TYPE,     16, SPECIAL, false },
	TYPEID   { "typeid",   TYPEID_TYPE,   0, SPECIAL, false },
	FAULT    { "fault",    FAULT_TYPE,    0, SPECIAL, false }
}

fn bool PrimitiveType.is_int(self) => self.kind == PrimitiveKind.INT;
fn bool PrimitiveType.is_float(self) => self.kind == PrimitiveKind.FLOAT;
fn bool PrimitiveType.is_numeric(self) => self.is_int() || self.is_float();

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

enum Keyword : int (String name, TokenKind token, KeywordFlags flags, String docs)
{
	ALIAS      { "alias",      ALIAS,      { .is_top_level = true, .is_type_decl = true }, "" },
	ASSERT     { "assert",     ASSERT,     { .is_statement = true }, "" },
	ASM        { "asm",        ASM,        { .is_statement = true }, "" },
	ATTRDEF    { "attrdef",    ATTRDEF,    { .is_top_level = true }, "" },
	ATTRGROUP  { "attrgroup",  ATTRDEF,    { .is_top_level = true }, "" },
	ATTRMACRO  { "attrmacro",  ATTRDEF,    { .is_top_level = true }, "" },
	BITSTRUCT  { "bitstruct",  BITSTRUCT,  { .is_top_level = true, .is_type_decl = true, .has_type_colon = true }, "" },
	BREAK      { "break",      BREAK,      { .is_statement = true }, "" },
	CASE       { "case",       CASE,       { .is_statement = true }, "" },
	CATCH      { "catch",      CATCH,      { .is_statement = true }, "" },
	CENUM      { "cenum",      CONSTDEF,   { .is_top_level = true, .is_type_decl = true, .has_type_colon = true }, "" },
	CONST      { "const",      CONST,      { .is_top_level = true, .is_statement = true }, "" },
	CONSTDEF   { "constdef",   CONSTDEF,   { .is_top_level = true, .is_type_decl = true, .has_type_colon = true }, "" },
	CONSTSET   { "constset",   CONSTDEF,   { .is_top_level = true, .is_type_decl = true, .has_type_colon = true }, "" },
	CONTINUE   { "continue",   CONTINUE,   { .is_statement = true }, "" },
	DEFAULT    { "default",    DEFAULT,    { .is_statement = true }, "" },
	DEFER      { "defer",      DEFER,      { .is_statement = true }, "" },
	DISTINCT   { "distinct",   TYPEDEF,    { .is_top_level = true, .is_type_decl = true }, "" },
	DO         { "do",         DO,         { .is_statement = true }, "" },
	ELSE       { "else",       ELSE,       { .is_statement = true }, "" },
	ENUM       { "enum",       ENUM,       { .is_top_level = true, .is_type_decl = true, .has_type_colon = true }, "" },
	EXCUSE     { "excuse",     FAULTDEF,   { .is_top_level = true }, "" },
	EXTERN     { "extern",     EXTERN,     { .is_top_level = true }, "" },
	FALSE      { "false",      FALSE,      { .is_expression = true }, "" },
	FAULTCONST { "faultconst", FAULTDEF,   { .is_top_level = true }, "" },
	FAULTDEF   { "faultdef",   FAULTDEF,   { .is_top_level = true }, "" },
	FAULTSET   { "faultset",   FAULTSET,   { .is_top_level = true }, "" },
	FN         { "fn",         FN,         { .is_top_level = true }, "" },
	FOR        { "for",        FOR,        { .is_statement = true }, "" },
	FOREACH    { "foreach",    FOREACH,    { .is_statement = true }, "" },
	FOREACH_R  { "foreach_r",  FOREACH_R,  { .is_statement = true }, "" },
	IF         { "if",         IF,         { .is_statement = true }, "" },
	INLINE     { "inline",     INLINE,     { .is_container = true }, "" },
	IMPORT     { "import",     IMPORT,     { .is_top_level = true }, "" },
	INTERFACE  { "interface",  INTERFACE,  { .is_top_level = true, .is_type_decl = true, .has_type_colon = true }, "" },
	LENGTHOF   { "lengthof",   LENGTHOF,   { .is_statement = true, .is_expression = true }, "" },
	MACRO      { "macro",      MACRO,      { .is_top_level = true }, "" },
	MODULE     { "module",     MODULE,     { .is_top_level = true }, "module declaration" },
	NEXTCASE   { "nextcase",   NEXTCASE,   { .is_statement = true }, "" },
	NULL       { "null",       NULL,       { .is_expression = true }, "" },
	RETURN     { "return",     RETURN,     { .is_statement = true }, "" },
	STATIC     { "static",     STATIC,     { .is_top_level = true }, "" },
	STRUCT     { "struct",     STRUCT,     { .is_top_level = true, .is_type_decl = true }, "" },
	SWITCH     { "switch",     SWITCH,     { .is_statement = true }, "" },
	TLOCAL     { "tlocal",     TLOCAL,     { .is_top_level = true, .is_container = true }, "" },
	TRUE       { "true",       TRUE,       { .is_expression = true }, "" },
	TRY        { "try",        TRY,        { .is_statement = true }, "" },
	TYPEDEF    { "typedef",    TYPEDEF,    { .is_top_level = true, .is_type_decl = true }, "" },
	UNION      { "union",      UNION,      { .is_top_level = true, .is_type_decl = true }, "" },
	VAR        { "var",        VAR,        { .is_statement = true }, "" },
	WHILE      { "while",      WHILE,      { .is_statement = true }, "" },
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