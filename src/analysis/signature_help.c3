module lsp::analysis::signature_help;

import analyzer::core;
import analyzer::cursor;
import analyzer::sema::query;

import std::collections::list;
import std::io;

import lsp::core;
import lsp;
import lsp::analysis;
import lsp::analysis::hover;
import uri;

struct CallTargetInfo
{
	String callee_name;
	uint active_param;
	bool is_valid;
}

fn CallTargetInfo parse_call_context(String text, sz offset)
{
	CallTargetInfo info = {.callee_name = "",.active_param = 0,.is_valid = false };
	if (offset == 0 || offset > text.len) return info;

	int depth = 0;
	sz open_paren_idx = 0;
	bool found = false;

	for (sz i = offset; i > 0; i--)
	{
		char c = text[i - 1];

		switch (c)
		{
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
					i++; continue;
				}
				if (c == '"') in_str = false;
				continue;
			case in_char:
				if (c == '\\')
				{
					i++; continue;
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
				if (nested_depth > 0) nested_depth--;
			case ',':
				if (nested_depth == 0) commas++;
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
		else if (text[callee_start - 1].is_alnum() || text[callee_start - 1] == '_' || text[callee_start - 1] == '@' || text[callee_start - 1] == '#' || text[callee_start - 1] == '$')
		{
			while (callee_start > 0 && (text[callee_start - 1].is_alnum() || text[callee_start - 1] == '_' || text[callee_start - 1] == '@' || text[callee_start - 1] == '#' || text[callee_start - 1] == '$'))
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
		info.is_valid = true;
	}

	return info;
}

fn SignatureHelpResult? signature_help(LspProject* project, Uri uri, LspPosition pos)
{
	SourceFile* sf = project.workspace.get_source_file_by_path(uri.path);
	if (!sf || !project.workspace.ctx) return {.signatures = {} };

	sz offset = analysis::compute_byte_offset(sf.content, pos.line, pos.character);

	CallTargetInfo target_info = parse_call_context(sf.content, offset);
	if (!target_info.is_valid) return {.signatures = {} };

	Location loc = {
		.line = (int)pos.line,
		.column = (int)pos.character
	};
	Node* callee_node = query::resolve_callee_by_name(project.workspace.ctx, sf, target_info.callee_name, loc);
	if (!callee_node) return {.signatures = {} };

	String symbol_name = target_info.callee_name;
	if (try dot_idx = symbol_name.rindex_of_char('.'))
	{
		symbol_name = symbol_name[dot_idx + 1..];
	}
	if (try sc_idx = symbol_name.rindex_of("::"))
	{
		symbol_name = symbol_name[sc_idx + 2..];
	}

	String sig_label = hover::format_node_signature(callee_node, symbol_name);
	String doc_comment = cursor::docs(callee_node) ?? "";

	List{ParameterInformation} params;
	params.tinit();

	bool is_method_call = target_info.callee_name.contains(".");
	bool is_method_decl = false;
	if (callee_node.kind == FN_DECL && callee_node.as(FnDecl).associated_type != null)
	{
		is_method_decl = true;
	}
	else if (callee_node.kind == MACRO_DECL && @ok(callee_node.as(MacroDecl).associated_type.get()))
	{
		is_method_decl = true;
	}

	sz start_param_idx = (is_method_call && is_method_decl) ? 1 : 0;

	switch (callee_node.kind)
	{
		case FN_DECL:
			{
				FnDecl* fn_decl = callee_node.as(FnDecl);
				for (sz i = start_param_idx; i < fn_decl.params.len; i++)
				{
					Node* p = fn_decl.params[i];
					if (!p || p.kind != VAR_DECL) continue;
					VarDecl* vd = p.as(VarDecl);
					String pname = vd.name ? vd.name.text : "";
					String ptype = cursor::spelling(vd.type, tmem);
					String plabel = "";
					if (ptype.len > 0 && pname.len > 0)
					{
						plabel = string::tformat("%s %s", ptype, pname);
					}
					else if (pname.len > 0)
					{
						plabel = pname;
					}
					else
					{
						plabel = ptype;
					}
					params.push(
					{
						.label = plabel,
						.documentation = ""
					}
					);
				}
			}
		case MACRO_DECL:
			{
				MacroDecl* mac_decl = callee_node.as(MacroDecl);
				for (sz i = start_param_idx; i < mac_decl.params.len; i++)
				{
					Node* p = mac_decl.params[i];
					if (!p || p.kind != VAR_DECL) continue;
					VarDecl* vd = p.as(VarDecl);
					String pname = vd.name ? vd.name.text : "";
					params.push(
					{
						.label = pname,
						.documentation = ""
					}
					);
				}
			}
		default:
			break;
	}

	SignatureInformation[] sig_list = alloc::alloc_array(tmem, SignatureInformation, 1);
	sig_list[0] = {
		.label = sig_label,
		.documentation = {
			.kind = MARKDOWN,
			.value = doc_comment.len > 0 ? doc_comment.trim().treplace("\"", "") : ""
		},
		.parameters = params.array_view(),
		.activeParameter = target_info.active_param
	};

	return {
		.signatures = sig_list,
		.activeSignature = 0,
		.activeParameter = target_info.active_param
	};
}
