module lsp::utils;

import std::collections::list;
import analyzer::core, analyzer::core::constants, analyzer::lexer;

<*
 Precomputes line starting byte offsets in a single linear pass for O(1) lookups.
*>
fn sz[] build_line_offsets(Allocator allocator, String content)
{
	List{sz} offsets;
	offsets.init(allocator);
	offsets.push(0);
	for (sz i = 0; i < content.len; i++)
	{
		if (content[i] == '\n')
		{
			offsets.push(i + 1);
		}
	}

	return offsets.array_view();
}

<*
 Converts line and character coordinates into a zero-indexed byte offset in O(1).
*>
fn sz offset_from_line_table(sz[] line_offsets, String content, uint target_line, uint target_char)
{
	if (target_line >= line_offsets.len) return content.len;
	sz off = line_offsets[target_line] + (sz)target_char;
	if (off > content.len) return content.len;
	return off;
}

<*
 Byte offset in `content` of the LSP position `target_line`:`target_char`,
 whose character counts UTF-16 code units. A character past the end of its
 line is the line's end.
*>
fn sz compute_byte_offset(String content, uint target_line, uint target_char)
{
	sz i = 0;
	for (uint line = 0; line < target_line && i < content.len; line++)
	{
		i += (content[i..].index_of_char('\n') ?? (content.len - i)) + 1;
	}
	uint units = 0;
	while (i < content.len && units < target_char && content[i] != '\n')
	{
		sz bytes = content.len - i;
		if (try c = conv::utf8_to_char32(&content[i], &bytes))
		{
			units += c > 0xFFFF ? 2 : 1;
		}
		else
		{
			// An invalid byte counts as one unit.
			bytes = 1;
			units++;
		}
		i += bytes;
	}
	return min(i, content.len);
}

<*
 Extracts a token prefix preceding a byte offset.
*>
fn String extract_prefix(String text, sz byte_offset)
{
	if (byte_offset == 0 || byte_offset > text.len) return "";

	sz start_idx = byte_offset;
	while (start_idx > 0)
	{
		char c = text[start_idx - 1];
		if (lexer::is_ident(c))
		{
			start_idx--;
		}
		else
		{
			switch (c)
			{
				case '@':
				case '#':
					start_idx--;
				case '$':
					start_idx--;
					// `$$` prefixes compiler builtins.
					if (start_idx > 0 && text[start_idx - 1] == '$') start_idx--;
				default:
					break;
			}
			break;
		}
	}

	if (start_idx >= byte_offset) return "";
	return text[start_idx..byte_offset - 1];
}

fn sz find_line_start(String text, sz offset)
{
	if (offset == 0 || offset > text.len) return 0;
	sz line_start = offset;
	while (line_start > 0 && text[line_start - 1] != '\n')
	{
		line_start--;
	}
	return line_start;
}

fn String extract_line_prefix(String text, sz offset)
{
	if (offset == 0 || offset > text.len) return "";
	sz line_start = find_line_start(text, offset);
	return text[line_start : offset - line_start].trim_left();
}

fn bool is_designator_delimiter(char c) @local
{
	return c == '{' || c == ',' || c == '=' || c == ';' || c == '(';
}

fn sz scan_base_expression_start(String text, sz end_idx)
{
	sz idx = end_idx;
	while (idx > 0 && (text[idx - 1] == ' ' || text[idx - 1] == '\t'))
	{
		idx--;
	}

	while (idx > 0)
	{
		if (text[idx - 1] == ')' || text[idx - 1] == ']' || text[idx - 1] == '}')
		{
			while (idx > 0 && (text[idx - 1] == ')' || text[idx - 1] == ']' || text[idx - 1] == '}'))
			{
				if (text[idx - 1] == ')')
				{
					int depth = 1;
					idx--;
					while (idx > 0 && depth > 0)
					{
						idx--;
						if (text[idx] == ')')
						{
							depth++;
						}
						else if (text[idx] == '(')
						{
							depth--;
						}
					}
				}
				else if (text[idx - 1] == '}')
				{
					int depth = 1;
					idx--;
					while (idx > 0 && depth > 0)
					{
						idx--;
						if (text[idx] == '}')
						{
							depth++;
						}
						else if (text[idx] == '{')
						{
							depth--;
						}
					}
				}
				else if (text[idx - 1] == ']')
				{
					int depth = 1;
					idx--;
					while (idx > 0 && depth > 0)
					{
						idx--;
						if (text[idx] == ']')
						{
							depth++;
						}
						else if (text[idx] == '[')
						{
							depth--;
						}
					}
				}
			}

			while (idx > 0 && lexer::is_name(text[idx - 1]))
			{
				idx--;
			}

			if (idx < text.len && text[idx] == '[')
			{
				return end_idx;
			}
		}
		else if (text[idx - 1] == '"')
		{
			idx--;
			while (idx > 0)
			{
				if (text[idx - 1] == '"' && (idx == 1 || text[idx - 2] != '\\'))
				{
					idx--;
					break;
				}
				idx--;
			}
		}
		else if (text[idx - 1] == '\'')
		{
			idx--;
			while (idx > 0)
			{
				if (text[idx - 1] == '\'' && (idx == 1 || text[idx - 2] != '\\'))
				{
					idx--;
					break;
				}
				idx--;
			}
		}
		else if (text[idx - 1] == '`')
		{
			idx--;
			while (idx > 0 && text[idx - 1] != '`')
			{
				idx--;
			}
			if (idx > 0) idx--;
		}
		else if (lexer::is_name(text[idx - 1]))
		{
			while (idx > 0 && lexer::is_name(text[idx - 1]))
			{
				idx--;
			}
		}
		else
		{
			break;
		}

		sz p = idx;
		while (p > 0 && (text[p - 1] == ' ' || text[p - 1] == '\t'))
		{
			p--;
		}

		if (p >= 2 && text[p - 2] == ':' && text[p - 1] == ':')
		{
			idx = p - 2;
			while (idx > 0 && text[idx - 1].is_space())
			{
				idx--;
			}
		}
		else if (p >= 1 && text[p - 1] == '.')
		{
			sz q = p - 1;
			while (q > 0 && text[q - 1].is_space()) q--;
			if (q == 0 || is_designator_delimiter(text[q - 1]))
			{
				return end_idx;
			}
			idx = q;
		}
		else
		{
			break;
		}
	}
	return idx;
}

struct CallTargetInfo
{
	String callee_name;
	uint active_param;
	bool is_valid;
	bool in_parens;
	sz open_paren_idx;
}

<*
 The call whose argument list holds `offset` in `sf`, found from the file's tokens.
*>
fn CallTargetInfo parse_call_context(SourceFile* sf, sz offset)
{
	CallTargetInfo info;
	Token[] tokens = sf.lexer.tokens.array_view();
	String text = sf.content;
	if (offset == 0 || offset > text.len) return info;

	sz end = tokens_before(sf, offset);

	sz paren = -1;
	int depth = 0;
	for (sz i = end - 1; i >= 0 && paren < 0; i--)
	{
		switch (tokens[i].kind)
		{
			case EOS:
				if (depth == 0) return info;
			case RBRACE:
				depth++;
			case LBRACE:
				if (depth == 0) return info;
				depth--;
			case RPAREN:
				depth++;
			case LPAREN:
				if (depth == 0)
				{
					paren = i;
				}
				else
				{
					depth--;
				}
			default:
				break;
		}
	}
	if (paren < 0) return info;

	info.in_parens = true;
	info.open_paren_idx = token_offset(text, tokens[paren]);

	int nested = 0;
	for (sz i = paren + 1; i < end; i++)
	{
		switch (tokens[i].kind)
		{
			case LPAREN:
			case LBRACKET:
			case LBRACE:
				nested++;
			case RPAREN:
			case RBRACKET:
			case RBRACE:
				if (nested > 0) nested--;
			case COMMA:
				if (nested == 0) info.active_param++;
			default:
				break;
		}
	}

	sz first = paren;
	for (sz i = paren - 1; i >= 0; i--)
	{
		TokenKind kind = tokens[i].kind;
		if (kind == RPAREN || kind == RBRACKET)
		{
			TokenKind open = kind == RPAREN ? LPAREN : LBRACKET;
			int group = 0;
			for (; i >= 0; i--)
			{
				if (tokens[i].kind == kind) group++;
				if (tokens[i].kind == open && --group == 0) break;
			}
			if (i < 0) break;
			first = i;
			continue;
		}
		if (!kind.is_identifier()) break;
		first = i;
		if (i > 0 && tokens[i - 1].kind == BUILTIN)
		{
			first = i - 1;
			break;
		}
		if (i == 0 || (tokens[i - 1].kind != SCOPE && tokens[i - 1].kind != DOT)) break;
		first = --i;
	}

	if (first < paren)
	{
		Token last = tokens[paren - 1];
		sz start = token_offset(text, tokens[first]);
		info.callee_name = text[start : token_offset(text, last) + last.value.len - start];
		info.is_valid = !constants::is_keyword(info.callee_name);
	}
	return info;
}

<*
 Byte offset of `token` in `text`, the content it was lexed from.
*>
fn sz token_offset(String text, Token token) => token.value.ptr - text.ptr;

<*
 Number of tokens of `sf`, before its EOF, that start before `offset`.
*>
fn sz tokens_before(SourceFile* sf, sz offset)
{
	Token[] tokens = sf.lexer.tokens.array_view();
	sz count = 0;
	sz hi = tokens.len;
	while (count < hi)
	{
		sz mid = (count + hi) / 2;
		if (tokens[mid].kind != EOF && token_offset(sf.content, tokens[mid]) < offset)
		{
			count = mid + 1;
		}
		else
		{
			hi = mid;
		}
	}
	return count;
}
