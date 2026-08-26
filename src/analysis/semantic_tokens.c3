module lsp::analysis::semantic_tokens;

import analyzer::core;
import analyzer::lexer;

import std::collections::list;
import std::io;

import lsp::core;
import lsp;
import uri;

const String[] TOKEN_TYPES = {
	"namespace",  // 0
	"type",  // 1
	"class",  // 2
	"enum",  // 3
	"interface",  // 4
	"struct",  // 5
	"typeParameter",  // 6
	"parameter",  // 7
	"variable",  // 8
	"property",  // 9
	"enumMember",  // 10
	"event",  // 11
	"function",  // 12
	"method",  // 13
	"macro",  // 14
	"keyword",  // 15
	"modifier",  // 16
	"comment",  // 17
	"string",  // 18
	"number",  // 19
	"operator"  // 20
};

const String[] TOKEN_MODIFIERS = {
	"declaration",  // 1 << 0
	"definition",  // 1 << 1
	"readonly",  // 1 << 2
	"static",  // 1 << 3
	"deprecated",  // 1 << 4
	"abstract",  // 1 << 5
	"async",  // 1 << 6
	"modification",  // 1 << 7
	"documentation",  // 1 << 8
	"defaultLibrary"  // 1 << 9
};

fn String[] get_token_types() => TOKEN_TYPES;
fn String[] get_token_modifiers() => TOKEN_MODIFIERS;

struct RawSemanticToken
{
	uint line;
	uint col;
	uint length;
	uint token_type;
	uint token_modifiers;
}

fn SemanticTokensResult? compute_semantic_tokens(LspProject* project, Uri uri)
{
	SourceFile* sf = project.workspace.get_source_file_by_path(uri.path);
	if (!sf || !sf.lexer) return {.data = {} };

	List{uint} encoded_data;
	encoded_data.tinit();

	uint prev_line = 0;
	uint prev_col = 0;

	for (sz i = 0; i < sf.lexer.tokens.len(); i++)
	{
		Token tok = sf.lexer.tokens[i];
		if (tok.kind == EOF || tok.kind == ERROR) continue;

		uint line = tok.range.start.line >= 0 ? (uint)tok.range.start.line : 0;
		uint col = tok.range.start.column >= 0 ? (uint)tok.range.start.column : 0;
		uint len = (uint)tok.value.len;
		if (len == 0) continue;

		uint t_type = 15;  // default keyword
		uint t_mods = 0;

		switch (tok.kind)
		{
			case LINE_COMMENT:
			case BLOCK_COMMENT:
			case DOCS_START:
			case DOCS_END:
			case DOCS_TEXT:
				t_type = 17;  // comment
				break;

			case STRING_LITERAL:
			case CHAR_LITERAL:
			case BYTES_LITERAL:
				t_type = 18;  // string
				break;

			case INT_DECIMAL_LITERAL:
			case INT_HEX_LITERAL:
			case INT_OCTAL_LITERAL:
			case INT_BIN_LITERAL:
			case FLOAT_DECIMAL_LITERAL:
			case FLOAT_HEX_LITERAL:
				t_type = 19;  // number
				break;

			case TYPE_IDENT:
			case AT_TYPE_IDENT:
			case CT_TYPE_IDENT:
			case VOID_TYPE:
			case BOOL_TYPE:
			case CHAR_TYPE:
			case DOUBLE_TYPE:
			case FLOAT_TYPE:
			case FLOAT16_TYPE:
			case BFLOAT_TYPE:
			case INT128_TYPE:
			case ICHAR_TYPE:
			case INT_TYPE:
			case IPTR_TYPE:
			case SZ_TYPE:
			case LONG_TYPE:
			case SHORT_TYPE:
			case UINT128_TYPE:
			case UINT_TYPE:
			case ULONG_TYPE:
			case UPTR_TYPE:
			case USHORT_TYPE:
			case USZ_TYPE:
			case FLOAT128_TYPE:
			case ANY_TYPE:
			case FAULT_TYPE:
			case TYPEID_TYPE:
				t_type = 1;  // type
				break;

			case CONST_IDENT:
			case AT_CONST_IDENT:
			case CT_CONST_IDENT:
			case HASH_CONST_IDENT:
				t_type = 10;  // enumMember / constant
				t_mods |= (1 << 2);  // readonly
				break;

			case HASH_IDENT:
			case HASH_TYPE_IDENT:
				t_type = 7;  // parameter
				break;

			case AT_IDENT:
				t_type = 14;  // macro / attribute
				break;

			case CT_IDENT:
				t_type = 8;  // variable
				break;

			case INLINE:
			case STATIC:
			case EXTERN:
			case TLOCAL:
				t_type = 16;  // modifier
				break;

			case IDENT:
				{
					Token next_tok = (i + 1 < sf.lexer.tokens.len()) ? sf.lexer.tokens[i + 1] : tok;
					Token prev_tok = (i > 0) ? sf.lexer.tokens[i - 1] : tok;

					if (next_tok.kind == LPAREN)
					{
						t_type = 12;  // function
					}
					else if (prev_tok.kind == DOT)
					{
						t_type = 9;  // property
					}
					else
					{
						t_type = 8;  // variable
					}
					break;
				}

			case PLUS:
			case MINUS:
			case ASTERISK:
			case DIV:
			case MOD:
			case EQ:
			case EQEQ:
			case NOT_EQUAL:
			case LESS:
			case LESS_EQ:
			case GREATER:
			case GREATER_EQ:
			case AND:
			case OR:
			case BIT_OR:
			case BIT_XOR:
			case BIT_NOT:
			case AMP:
			case LSHIFT:
			case RSHIFT:
			case IMPLIES:
			case ARROW:
			case ELVIS:
			case QUESTQUEST:
			case CT_CONCAT_OP:
			case CT_AND_OP:
			case CT_OR_OP:
				t_type = 20;  // operator
				break;

			default:
				if (tok.kind.is_keyword())
				{
					t_type = 15;  // keyword
				}
				else
				{
					continue;
				}
				break;
		}

		uint delta_line = line - prev_line;
		uint delta_col = delta_line == 0 ? col - prev_col : col;

		encoded_data.push(delta_line);
		encoded_data.push(delta_col);
		encoded_data.push(len);
		encoded_data.push(t_type);
		encoded_data.push(t_mods);

		prev_line = line;
		prev_col = col;
	}

	return {
		.data = encoded_data.array_view()
	};
}
