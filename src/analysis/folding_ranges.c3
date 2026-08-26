module lsp::analysis::folding_ranges;

import analyzer::core;
import analyzer::cursor;

import std::collections::list;
import std::io;

import lsp::core;
import lsp;
import uri;

struct FoldingCollector
{
	List{FoldingRange} * ranges;
}

fn void add_folding_range(List{FoldingRange} * ranges, uint start_line, uint end_line, String kind = "")
{
	if (end_line <= start_line) return;

	foreach (r : *ranges)
	{
		if (r.startLine == start_line && r.endLine == end_line) return;
	}

	ranges.push(
	{
		.startLine = start_line,
		.startCharacter = 0,
		.endLine = end_line,
		.endCharacter = 0,
		.kind = kind
	}
	);
}

fn ChildVisitResult collect_folding_callback(Node* c, Node* p, void* user_data)
{
	if (!c || c.kind == ERROR) return CONTINUE;
	FoldingCollector* ctx = (FoldingCollector*)user_data;

	if (c.range.start.line < c.range.end.line)
	{
		switch (c.kind)
		{
			case COMPOUND_STMT:
			case STRUCT_DECL:
			case ENUM_DECL:
			case SWITCH_STMT:
			case INTERFACE_DECL:
			case FN_DECL:
			case MACRO_DECL:
			case FOR_STMT:
			case WHILE_STMT:
			case DO_WHILE_STMT:
			case FOREACH_STMT:
			case IF_STMT:
				add_folding_range(ctx.ranges, (uint)c.range.start.line, (uint)c.range.end.line, "region");
			default:
				break;
		}
	}

	return RECURSE;
}

fn void collect_comment_folds(String content, List{FoldingRange} * ranges)
{
	sz i = 0;
	uint line = 0;
	while (i < content.len)
	{
		if (content[i] == '\n')
		{
			line++;
			i++;
			continue;
		}
		// Block comments: /* ... */
		if (i + 1 < content.len && content[i] == '/' && content[i + 1] == '*')
		{
			uint start_line = line;
			i += 2;
			while (i + 1 < content.len && !(content[i] == '*' && content[i + 1] == '/'))
			{
				if (content[i] == '\n') line++;
				i++;
			}
			if (i + 1 < content.len)
			{
				i += 2;
			}
			uint end_line = line;
			if (end_line > start_line)
			{
				add_folding_range(ranges, start_line, end_line, "comment");
			}
			continue;
		}
		// Doc comments: <* ... *>
		if (i + 1 < content.len && content[i] == '<' && content[i + 1] == '*')
		{
			uint start_line = line;
			i += 2;
			while (i + 1 < content.len && !(content[i] == '*' && content[i + 1] == '>'))
			{
				if (content[i] == '\n') line++;
				i++;
			}
			if (i + 1 < content.len)
			{
				i += 2;
			}
			uint end_line = line;
			if (end_line > start_line)
			{
				add_folding_range(ranges, start_line, end_line, "comment");
			}
			continue;
		}

		i++;
	}
}

fn FoldingRange[]? get_folding_ranges(LspProject* project, Uri uri)
{
	SourceFile* sf = project.workspace.get_source_file_by_path(uri.path);
	if (!sf) return {};

	List{FoldingRange} ranges;
	ranges.tinit();

	int import_start = -1;
	int import_end = -1;

	foreach (stmt : sf.ast.statements)
	{
		if (stmt && stmt.kind == IMPORT_DECL)
		{
			if (import_start == -1)
			{
				import_start = stmt.range.start.line;
			}
			import_end = stmt.range.end.line;
		}
		else
		{
			if (import_start != -1 && import_end > import_start)
			{
				add_folding_range(&ranges, (uint)import_start, (uint)import_end, "imports");
			}
			import_start = -1;
			import_end = -1;
		}
	}
	if (import_start != -1 && import_end > import_start)
	{
		add_folding_range(&ranges, (uint)import_start, (uint)import_end, "imports");
	}

	FoldingCollector collector = {.ranges = &ranges };
	foreach (stmt : sf.ast.statements)
	{
		if (!stmt || stmt.kind == ERROR) continue;
		cursor::visit(stmt, null, {.on_enter = &collect_folding_callback }, &collector);
	}

	collect_comment_folds(sf.content, &ranges);

	return ranges.array_view();
}
