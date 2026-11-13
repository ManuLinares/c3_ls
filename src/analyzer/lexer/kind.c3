module analyzer::lexer;

bitstruct TokenTraits : char
{
	bool is_identifier;
	bool is_keyword;
	bool is_base_type;
	bool is_int_literal;
	bool is_float_literal;
}

enum TokenKind : char (TokenTraits traits)
{
	<* Error *>
	ERROR                 { {} },


	// Operators
	<* & *>
	AMP                   { {} },
	<* | *>
	BIT_OR                { {} },
	<* ^ *>
	BIT_XOR               { {} },
	<* ~ *>
	BIT_NOT               { {} },
	<* ! *>
	BANG                  { {} },
	<* + *>
	PLUS                  { {} },
	<* - *>
	MINUS                 { {} },
	<* * *>
	ASTERISK              { {} },
	<* / *>
	DIV                   { {} },
	<* % *>
	MOD                   { {} },
	<* ? *>
	QUESTION              { {} },
	<* ?? *>
	QUESTQUEST            { {} },
	<* ?: *>
	ELVIS                 { {} },
	<* !! *>
	BANGBANG              { {} },
	<* $$ *>
	BUILTIN               { {} },
	<* >> *>
	RSHIFT                { {} },
	<* << *>
	LSHIFT                { {} },
	<* ++ *>
	PLUSPLUS              { {} },
	<* -- *>
	MINUSMINUS            { {} },
	<* +++ *>
	CT_CONCAT_OP          { {} },
	<* ??? *>
	CT_TERNARY            { {} },
	
	
	// Assignment
	<* = *>
	EQ                    { {} },
	<* >>= *>
	RSHIFT_ASSIGN         { {} },
	<* <<= *>
	LSHIFT_ASSIGN         { {} },
	<* += *>
	PLUS_ASSIGN           { {} },
	<* -= *>
	MINUS_ASSIGN          { {} },
	<* *= *>
	MULT_ASSIGN           { {} },
	<* /= *>
	DIV_ASSIGN            { {} },
	<* %= *>
	MOD_ASSIGN            { {} },
	<* &= *>
	BIT_AND_ASSIGN        { {} },
	<* ^= *>
	BIT_XOR_ASSIGN        { {} },
	<* |= *>
	BIT_OR_ASSIGN         { {} },
	<* +++= *>
	CT_CONCAT_ASSIGN      { {} },
	
	
	// Comparison
	<* < *>
	LESS                  { {} },
	<* > *>
	GREATER               { {} },
	<* && *>
	AND                   { {} },
	<* || *>
	OR                    { {} },
	<* <= *>
	LESS_EQ               { {} },
	<* >= *>
	GREATER_EQ            { {} },
	<* == *>
	EQEQ                  { {} },
	<* != *>
	NOT_EQUAL             { {} },
	<* &&& *>
	CT_AND_OP             { {} },
	<* ||| *>
	CT_OR_OP              { {} },
	
	
	// Punctuation
	<* ; *>
	EOS                   { {} },
	<* : *>
	COLON                 { {} },
	<* :: *>
	SCOPE                 { {} },
	<* , *>
	COMMA                 { {} },
	<* . *>
	DOT                   { {} },
	<* .. *>
	DOTDOT                { {} },
	<* ... *>
	ELLIPSIS              { {} },
	
	
	// Structure
	<* { *>
	LBRACE                { {} },
	<* } *>
	RBRACE                { {} },
	<* [ *>
	LBRACKET              { {} },
	<* ] *>
	RBRACKET              { {} },
	<* ( *>
	LPAREN                { {} },
	<* ) *>
	RPAREN                { {} },
	<* -> *>
	ARROW                 { {} },
	<* => *>
	IMPLIES               { {} },
	<* [< *>
	LVEC                  { {} },
	<* >] *>
	RVEC                  { {} },  
	// <*
	DOCS_START            { {} },
	// *>
	DOCS_END              { {} },
	<* Any identifer before a @ *>
	DOCS_TEXT             { {} },
	<* // *>
	LINE_COMMENT          { {} },
	<* /* *>
	BLOCK_COMMENT         { {} },
	
	
	// Literals (Identifiers and Strings)
	<* STRING *>
	STRING_LITERAL        { {} },
	<* 'a' 'FO' 'BARS' '\u1232' *>
	CHAR_LITERAL          { {} },
	<* Base64 or Hex *>
	BYTES_LITERAL         { {} },
	<* 123 *>
	INT_DECIMAL_LITERAL   { { .is_int_literal } },
	<* 0x23 *>
	INT_HEX_LITERAL       { { .is_int_literal } },
	<* 0o327 *>
	INT_OCTAL_LITERAL     { { .is_int_literal } },
	<* 0b10010 *>
	INT_BIN_LITERAL       { { .is_int_literal } },
	<* 43.23e23 *>
	FLOAT_DECIMAL_LITERAL { { .is_float_literal } },
	<* 0x23.2p-2a *>
	FLOAT_HEX_LITERAL     { { .is_float_literal } },
	<* foo *>
	IDENT                 { { .is_identifier } },
	<* '@' *>
	AT                    { {} },
	<* Foo, *>
	TYPE_IDENT            { { .is_identifier } },
	<* FOO *>
	CONST_IDENT           { { .is_identifier } },
	<* @foo *>
	AT_IDENT              { { .is_identifier } },
	<* @Foo *>
	AT_TYPE_IDENT         { { .is_identifier } },
	<* @FOO *>
	AT_CONST_IDENT        { { .is_identifier } },
	<* #foo, *>
	HASH_IDENT            { { .is_identifier } },
	<* #Type *>
	HASH_TYPE_IDENT       { { .is_identifier } },
	<* #CONST_IDENT *>
	HASH_CONST_IDENT      { { .is_identifier } },
	<* $foo *>
	CT_IDENT              { { .is_identifier } },
	<* $Foo, *>
	CT_TYPE_IDENT         { { .is_identifier } },
	<* $FOO, *>
	CT_CONST_IDENT        { { .is_identifier } },
	<* Base Types *>
	VOID_TYPE             { { .is_base_type } },
	BOOL_TYPE             { { .is_base_type } },
	CHAR_TYPE             { { .is_base_type } },
	DOUBLE_TYPE           { { .is_base_type } },
	FLOAT_TYPE            { { .is_base_type } },
	FLOAT16_TYPE          { { .is_base_type } },
	BFLOAT_TYPE           { { .is_base_type } },
	INT128_TYPE           { { .is_base_type } },
	ICHAR_TYPE            { { .is_base_type } },
	INT_TYPE              { { .is_base_type } },
	IPTR_TYPE             { { .is_base_type } },
	SZ_TYPE               { { .is_base_type } },
	LONG_TYPE             { { .is_base_type } },
	SHORT_TYPE            { { .is_base_type } },
	UINT128_TYPE          { { .is_base_type } },
	UINT_TYPE             { { .is_base_type } },
	ULONG_TYPE            { { .is_base_type } },
	UPTR_TYPE             { { .is_base_type } },
	USHORT_TYPE           { { .is_base_type } },
	USZ_TYPE              { { .is_base_type } },
	FLOAT128_TYPE         { { .is_base_type } },
	ANY_TYPE              { { .is_base_type } },
	FAULT_TYPE            { { .is_base_type } },
	TYPEID_TYPE           { { .is_base_type } },
	UNTYPEDLIST_TYPE      { { .is_base_type } },
	
	
	// Keywords
	ALIAS                 { { .is_keyword } },
	ASSERT                { { .is_keyword } },
	ASM                   { { .is_keyword } },
	ATTRDEF               { { .is_keyword } },
	BITSTRUCT             { { .is_keyword } },
	BREAK                 { { .is_keyword } },
	CASE                  { { .is_keyword } },
	CATCH                 { { .is_keyword } },
	CONSTDEF              { { .is_keyword } },
	CONST                 { { .is_keyword } },
	CONTINUE              { { .is_keyword } },
	DEFAULT               { { .is_keyword } },
	DEFER                 { { .is_keyword } },
	DO                    { { .is_keyword } },
	ELSE                  { { .is_keyword } },
	ENUM                  { { .is_keyword } },
	EXTERN                { { .is_keyword } },
	FALSE                 { { .is_keyword } },
	FAULTDEF              { { .is_keyword } },
	FOR                   { { .is_keyword } },
	FOREACH               { { .is_keyword } },
	FOREACH_R             { { .is_keyword } },
	FN                    { { .is_keyword } },
	TLOCAL                { { .is_keyword } },
	IF                    { { .is_keyword } },
	INLINE                { { .is_keyword } },
	IMPORT                { { .is_keyword } },
	LENGTHOF              { { .is_keyword } },
	MACRO                 { { .is_keyword } },
	MODULE                { { .is_keyword } },
	NEXTCASE              { { .is_keyword } },
	NULL                  { { .is_keyword } },
	INTERFACE             { { .is_keyword } },
	RETURN                { { .is_keyword } },
	STATIC                { { .is_keyword } },
	STRUCT                { { .is_keyword } },
	SWITCH                { { .is_keyword } },
	TRUE                  { { .is_keyword } },
	TRY                   { { .is_keyword } },
	TYPEDEF               { { .is_keyword } },
	UNION                 { { .is_keyword } },
	VAR                   { { .is_keyword } },
	WHILE                 { { .is_keyword } },


	// Compile-time Keywords
	<* $assert *>
	CT_ASSERT             { {} },
	<* $case *>
	CT_CASE               { {} },
	<* $default *>
	CT_DEFAULT            { {} },
	<* $defined *>
	CT_DEFINED            { {} },
	<* $echo *>
	CT_ECHO               { {} },
	<* $else *>
	CT_ELSE               { {} },
	<* $embed *>
	CT_EMBED              { {} },
	<* $endfor *>
	CT_ENDFOR             { {} },
	<* $endforeach *>
	CT_ENDFOREACH         { {} },
	<* $endif *>
	CT_ENDIF              { {} },
	<* $endswitch *>
	CT_ENDSWITCH          { {} },
	<* $eval *>
	CT_EVAL               { {} },
	<* $error *>
	CT_ERROR              { {} },
	<* $exec *>
	CT_EXEC               { {} },
	<* $expand *>
	CT_EXPAND             { {} },
	<* $feature *>
	CT_FEATURE            { {} },
	<* $for *>
	CT_FOR                { {} },
	<* $foreach *>
	CT_FOREACH            { {} },
	<* $if *>
	CT_IF                 { {} },
	<* $include *>
	CT_INCLUDE            { {} },
	<* $reflect *>
	CT_REFLECT            { {} },
	<* $stringify *>
	CT_STRINGIFY          { {} },
	<* $switch *>
	CT_SWITCH             { {} },
	<* $Typefrom *>
	CT_TYPEFROM           { {} },
	<* $Typeof *>
	CT_TYPEOF             { {} },
	<* $vaarg, *>
	CT_VAARG              { {} },

	AT_INLINE             { {} },
	AT_PURE               { {} },
	AT_NOINLINE           { {} },

	EOF                   { {} }
}

fn bool TokenKind.is_identifier(self) @inline => self.traits.is_identifier;
fn bool TokenKind.is_keyword(self) @inline => self.traits.is_keyword;
fn bool TokenKind.is_base_type(self) @inline => self.traits.is_base_type;
fn bool TokenKind.is_int_literal(&self) @inline => self.traits.is_int_literal;
fn bool TokenKind.is_float_literal(&self) @inline => self.traits.is_float_literal;
