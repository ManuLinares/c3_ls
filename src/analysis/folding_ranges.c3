module lsp::analysis::folding_ranges;

import analyzer::core;
import analyzer::cursor;

import std::collections::list, std::collections::set;
import std::io;

import lsp::core;
import lsp;
import uri;

<*
 Folding ranges collected so far, each start and end line pair once.
*>
struct Folds
{
	List{FoldingRange} ranges;
	HashSet{ulong} seen;
}

fn void Folds.add(&self, uint start_line, uint end_line, String kind)
{
	if (end_line <= start_line || !self.seen.add((ulong)start_line << 32 | end_line)) return;
	self.ranges.push({ .startLine = start_line, .endLine = end_line, .kind = kind });
}

fn ChildVisitResult collect_folding_callback(Node* c, Node* p, void* user_data)
{
	if (!c || c.kind == ERROR) return CONTINUE;
	Folds* folds = user_data;

	if (c.range.start.line < c.range.end.line)
	{
		switch (c.kind)
		{
			case COMPOUND_STMT:
			case STRUCT_DECL:
			case ENUM_DECL:
			case SWITCH_STMT:
			case INTERFACE_DECL:
			case FAULTDEF_DECL:
			case FN_DECL:
			case MACRO_DECL:
			case FOR_STMT:
			case WHILE_STMT:
			case DO_WHILE_STMT:
			case FOREACH_STMT:
			case IF_STMT:
				folds.add((uint)c.range.start.line, (uint)c.range.end.line, "region");
			default:
				break;
		}
	}

	return RECURSE;
}

fn void collect_comment_folds(String content, Folds* folds)
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
				folds.add(start_line, end_line, "comment");
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
				folds.add(start_line, end_line, "comment");
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

	Folds folds;
	folds.ranges.tinit();
	folds.seen.tinit();

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
				folds.add((uint)import_start, (uint)import_end, "imports");
			}
			import_start = -1;
			import_end = -1;
		}
	}
	if (import_start != -1 && import_end > import_start)
	{
		folds.add((uint)import_start, (uint)import_end, "imports");
	}

	foreach (stmt : sf.ast.statements)
	{
		if (!stmt || stmt.kind == ERROR) continue;
		cursor::visit(stmt, null, {.on_enter = &collect_folding_callback }, &folds);
	}

	collect_comment_folds(sf.content, &folds);

	return folds.ranges.array_view();
}
