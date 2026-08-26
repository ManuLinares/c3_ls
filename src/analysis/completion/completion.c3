module lsp::analysis::completion;

import analyzer::core;
import analyzer::cursor;
import analyzer::sema;

import std::collections::list;
import std::collections::map;
import std::collections::set;

import lsp::core;
import lsp;
import uri;
import analyzer::lexer;
import lsp::analysis;
import lsp::analysis::hover;

struct Context
{
	Uri uri;
	LspPosition position;
	sz offset;
	LspWorkspace* ws;
	SourceFile* sf;
	Allocator allocator;
	String prefix;
	ScopeKind scope;
	LspAccessKind access;
	String base_identifier;
}

fn void resolve_item(LspProject* project, CompletionItem* item)
{
	if (!project || !item || item.label.len == 0) return;

	String sym_name = item.label;
	List{SymbolEntry} syms = project.workspace.find_symbol_by_name(sym_name);
	if (syms.len() == 0 && sym_name.starts_with("@"))
	{
		syms = project.workspace.find_symbol_by_name(sym_name.strip_prefix("@"));
	}
	if (syms.len() == 0 || !syms.get(0).node) return;

	Node* node = syms.get(0).node;
	String sig = hover::format_node_signature(node, sym_name);
	String doc_comment = cursor::docs(node) ?? "";

	DString md_buf;
	md_buf.tinit();
	md_buf.appendf("```c3\n%s\n```", sig);

	if (doc_comment.len > 0)
	{
		String clean_doc = doc_comment.trim().treplace("\"", "");
		if (clean_doc.len > 0)
		{
			md_buf.appendf("\n\n%s", clean_doc);
		}
	}

	item.documentation = {
		.kind = MARKDOWN,
		.value = md_buf.str_view()
	};
}

fn CompletionItem[]? resolve(LspProject* project, Uri uri, LspPosition pos)
{
	log::debug("completion resolve at line %d, char %d", pos.line, pos.character);

	List{CompletionItem} items;
	items.init(tmem);

	SourceFile* sf = project.workspace.get_source_file_by_path(uri.path);
	if (!sf) return items.array_view();

	Context ctx = {
		.uri = uri,
		.position = pos,
		.ws = &project.workspace,
		.sf = sf,
		.allocator = tmem,
		.scope = EXECUTION,
		.offset = analysis::compute_byte_offset(sf.content, pos.line, pos.character),
	};

	ctx.prefix = analysis::extract_prefix(sf.content, ctx.offset);

	detect_access_context(&ctx, sf);

	if (ctx.access != NONE)
	{
		provide_member_access(&ctx, &items);
	}
	else
	{
		provide_locals(&ctx, &items);
		provide_global(&ctx, &items);
		provide_module_paths(&ctx, &items);
		provide_keywords(&ctx, &items);
	}

	return items.array_view();
}
