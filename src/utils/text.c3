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

<*
 Whether the character at `idx` follows an odd number of backslashes.
*>
fn bool is_escaped(String text, sz idx) @local
{
	sz backslashes = 0;
	while (idx > backslashes && text[idx - backslashes - 1] == '\\') backslashes++;
	return backslashes % 2 == 1;
}

fn sz find_enclosing_bracket(String text, sz idx, char open_ch = '{', char close_ch = '}')
{
	int depth = 0;
	int other_brace = 0;
	int other_paren = 0;
	int other_bracket = 0;
	bool in_str = false;
	bool in_char = false;
	bool in_raw = false;

	for (sz i = idx; i > 0; i--)
	{
		char c = text[i - 1];
		if (c == '`') { in_raw = !in_raw; continue; }
		if (in_raw) continue;
		if (c == '"' && !is_escaped(text, i - 1)) { in_str = !in_str; continue; }
		if (in_str) continue;
		if (c == '\'' && !is_escaped(text, i - 1)) { in_char = !in_char; continue; }
		if (in_char) continue;

		if (c == close_ch)
		{
			depth++;
		}
		else if (c == open_ch)
		{
			if (depth > 0)
			{
				depth--;
			}
			else
			{
				return i - 1;
			}
		}
		else
		{
			switch (c)
			{
				case '}': other_brace++;
				case '{': if (other_brace > 0) other_brace--;
				case ')': other_paren++;
				case '(': if (other_paren > 0) other_paren--;
				case ']': other_bracket++;
				case '[': if (other_bracket > 0) other_bracket--;
				default: break;
			}
		}
	}
	return (sz)-1;
}

fn sz find_enclosing_open_brace(String text, sz idx) => find_enclosing_bracket(text, idx, '{', '}');

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

fn CallTargetInfo parse_call_context(String text, sz offset)
{
	CallTargetInfo info = {
		.callee_name = "",
		.active_param = 0,
		.is_valid = false,
		.open_paren_idx = 0
	};
	if (offset == 0 || offset > text.len) return info;

	int depth = 0;
	sz open_paren_idx = 0;
	bool found = false;

	for (sz i = offset; i > 0; i--)
	{
		char c = text[i - 1];

		switch (c)
		{
			case ';':
				if (depth == 0) return info;
			case '}':
				depth++;
			case '{':
				if (depth == 0) return info;
				depth--;
			case ')':
				depth++;
			case '(':
				if (depth > 0)
				{
					depth--;
				}
				else
				{
					open_paren_idx = i - 1;
					found = true;
				}
			default:
				break;
		}
		if (found) break;
	}

	if (!found) return info;

	info.in_parens = true;
	info.open_paren_idx = open_paren_idx;

	uint commas = 0;
	int nested_depth = 0;
	bool in_str = false;
	bool in_char = false;
	bool in_raw = false;

	for (sz i = open_paren_idx + 1; i < offset; i++)
	{
		char c = text[i];
		switch (true)
		{
			case in_raw:
				if (c == '`') in_raw = false;
				continue;
			case in_str:
				if (c == '\\')
				{
					i++;
					continue;
				}
				if (c == '"') in_str = false;
				continue;
			case in_char:
				if (c == '\\')
				{
					i++;
					continue;
				}
				if (c == '\'') in_char = false;
				continue;
			default:
				break;
		}

		switch (c)
		{
			case '`':
				in_raw = true;
			case '"':
				in_str = true;
			case '\'':
				in_char = true;
			case '(':
			case '[':
			case '{':
				nested_depth++;
			case ')':
			case ']':
			case '}':
				if (nested_depth > 0)
				{
					nested_depth--;
				}
			case ',':
				if (nested_depth == 0)
				{
					commas++;
				}
			default:
				break;
		}
	}

	info.active_param = commas;

	sz callee_end = open_paren_idx;
	while (callee_end > 0 && text[callee_end - 1].is_space())
	{
		callee_end--;
	}

	sz callee_start = callee_end;
	while (callee_start > 0)
	{
		if (text[callee_start - 1] == ')')
		{
			callee_start--;
			int scan_depth = 1;
			while (callee_start > 0 && scan_depth > 0)
			{
				if (text[callee_start - 1] == ')')
				{
					scan_depth++;
				}
				else if (text[callee_start - 1] == '(')
				{
					scan_depth--;
				}
				callee_start--;
			}
			continue;
		}
		else if (text[callee_start - 1] == ']')
		{
			callee_start--;
			int scan_depth = 1;
			while (callee_start > 0 && scan_depth > 0)
			{
				if (text[callee_start - 1] == ']')
				{
					scan_depth++;
				}
				else if (text[callee_start - 1] == '[')
				{
					scan_depth--;
				}
				callee_start--;
			}
			continue;
		}
		else if (lexer::is_name(text[callee_start - 1]))
		{
			while (callee_start > 0 && lexer::is_name(text[callee_start - 1]))
			{
				callee_start--;
			}
		}
		else
		{
			break;
		}

		if (callee_start >= 2 && text[callee_start - 2] == ':' && text[callee_start - 1] == ':')
		{
			callee_start -= 2;
		}
		else if (callee_start >= 1 && text[callee_start - 1] == '.')
		{
			callee_start -= 1;
		}
		else
		{
			break;
		}
	}

	if (callee_end > callee_start)
	{
		info.callee_name = text[callee_start : callee_end - callee_start];
		info.is_valid = !constants::is_keyword(info.callee_name);
	}

	return info;
}