module lsp::analysis::semantic_tokens;

import analyzer::core;
import analyzer::lexer;

import std::collections::list;
import std::io;

import lsp::core;
import lsp;
import uri;

enum SemanticTokenType : uint
{
	NAMESPACE,
	TYPE,
	CLASS,
	ENUM,
	INTERFACE,
	STRUCT,
	TYPE_PARAMETER,
	PARAMETER,
	VARIABLE,
	PROPERTY,
	ENUM_MEMBER,
	EVENT,
	FUNCTION,
	METHOD,
	MACRO,
	KEYWORD,
	MODIFIER,
	COMMENT,
	STRING,
	NUMBER,
	OPERATOR,
	REGEXP,
}

<*
 Each value is sent as the bit `1 << ordinal`.
*>
enum SemanticTokenModifier : uint
{
	DECLARATION,
	DEFINITION,
	READONLY,
	STATIC,
	DEPRECATED,
	ABSTRACT,
	ASYNC,
	MODIFICATION,
	DOCUMENTATION,
	DEFAULT_LIBRARY,
}

macro String[] @legend($Enum)
{
	var $names = {};
	$foreach $v : $Enum::values:
		$names +++= @str_camelcase($v.description);
	$endforeach
	return $names;
}

const String[] TOKEN_TYPES = @legend(SemanticTokenType);
const String[] TOKEN_MODIFIERS = @legend(SemanticTokenModifier);

fn String[] get_token_types() => TOKEN_TYPES;
fn String[] get_token_modifiers() => TOKEN_MODIFIERS;

fn SemanticTokensResult? compute_semantic_tokens(LspProject* project, Uri uri)
{
	SourceFile* sf = project.workspace.get_source_file_by_path(uri.path);
	if (!sf || !sf.lexer) return {.data = {} };

	List{uint} encoded_data;
	encoded_data.tinit();

	uint prev_line = 0;
	uint prev_col = 0;
	// Inside the module path of a `module` or `import` statement, before its attributes.
	bool in_module_path;

	for (sz i = 0; i < sf.lexer.tokens.len(); i++)
	{
		Token tok = sf.lexer.tokens[i];
		if (tok.kind == EOF || tok.kind == ERROR) continue;
		switch (tok.kind)
		{
			case MODULE:
			case IMPORT: in_module_path = true;
			case EOS:
			case AT_IDENT: in_module_path = false;
			default: break;
		}

		uint line = tok.range.start.line >= 0 ? (uint)tok.range.start.line : 0;
		uint col = tok.range.start.column >= 0 ? (uint)tok.range.start.column : 0;
		uint len = (uint)tok.value.len;
		if (len == 0) continue;

		SemanticTokenType t_type = KEYWORD;
		uint t_mods = 0;

		switch (tok.kind)
		{
			case LINE_COMMENT:
			case BLOCK_COMMENT:
			case DOCS_START:
			case DOCS_END:
			case DOCS_TEXT:
				t_type = COMMENT;
				break;

			case STRING_LITERAL:
			case CHAR_LITERAL:
			case BYTES_LITERAL:
				t_type = STRING;
				break;

			case TYPE_IDENT:
			case AT_TYPE_IDENT:
			case CT_TYPE_IDENT:
				t_type = TYPE;
				break;

			case CONST_IDENT:
			case AT_CONST_IDENT:
			case CT_CONST_IDENT:
			case HASH_CONST_IDENT:
				t_type = ENUM_MEMBER;
				t_mods |= 1 << SemanticTokenModifier.READONLY.ordinal;
				break;

			case HASH_IDENT:
			case HASH_TYPE_IDENT:
				t_type = PARAMETER;
				break;

			case AT_IDENT:
				t_type = MACRO;
				break;

			case BUILTIN:
				{
					if (i + 1 >= sf.lexer.tokens.len()) continue;
					Token name = sf.lexer.tokens[i + 1];
					if (name.range.start.line != tok.range.start.line || name.range.start.column != tok.range.start.column + 2) continue;
					switch (name.kind)
					{
						case IDENT: t_type = FUNCTION;
						case CONST_IDENT: t_type = ENUM_MEMBER;
						default: continue;
					}
					len += (uint)name.value.len;
					t_mods |= 1 << SemanticTokenModifier.DEFAULT_LIBRARY.ordinal;
					i++;
					break;
				}

			case CT_IDENT:
				t_type = VARIABLE;
				break;

			case INLINE:
			case STATIC:
			case EXTERN:
			case TLOCAL:
				t_type = KEYWORD;
				break;

			case IDENT:
				{
					Token next_tok = (i + 1 < sf.lexer.tokens.len()) ? sf.lexer.tokens[i + 1] : tok;
					Token prev_tok = (i > 0) ? sf.lexer.tokens[i - 1] : tok;

					// A module name is sent as `regexp`, not `namespace` or something proper.
					// default VS Code themes colour `namespace` like types, and `regexp` is the only standard type with a colour of its own.
					// Seems nicer
					if (in_module_path || next_tok.kind == SCOPE)
					{
						t_type = REGEXP;
					}
					else if (next_tok.kind == LPAREN)
					{
						t_type = FUNCTION;
					}
					else if (prev_tok.kind == DOT)
					{
						t_type = PROPERTY;
					}
					else
					{
						t_type = VARIABLE;
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
				t_type = OPERATOR;
				break;

			default:
				switch
				{
					case tok.kind.is_int_literal():
					case tok.kind.is_float_literal():
						t_type = NUMBER;
					case tok.kind.is_base_type():
						t_type = TYPE;
					case tok.kind.is_keyword():
						t_type = KEYWORD;
					default:
						continue;
				}
		}

		uint delta_line = line - prev_line;
		uint delta_col = delta_line == 0 ? col - prev_col : col;

		encoded_data.push(delta_line);
		encoded_data.push(delta_col);
		encoded_data.push(len);
		encoded_data.push(t_type.ordinal);
		encoded_data.push(t_mods);

		prev_line = line;
		prev_col = col;
	}

	return {
		.data = encoded_data.array_view()
	};
}
