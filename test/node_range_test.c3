module lsp::node_range_test;

import lsp, analyzer;

const String SOURCE = `
module app;
struct Box <Type>
{
	Type v;
}
struct Pt
{
	int a;
	int b;
}
fn void main()
{
	int x;
	int[] list;
	if (x > 0) { x = 1; }
	for (int i = 0; i < 3; i++) { x++; }
	do { x--; } while (x > 0);
	foreach (v : list) { x += v; }
	switch (x)
	{
		case 1:
			nextcase 2;
		case 2:
			break;
		default:
			x = 0;
	}
	$if true:
		x = 2;
	$endif
	$for var $i = 0; $i < 2; $i++:
		x += $i;
	$endfor
	$switch 1:
		$case 1:
			x = 3;
	$endswitch
	int? r = x;
	Box{int} bx;
	Pt pt = { .a = 1, .b = 2 };
	if (catch r) x = 4;
}
`;

fn ChildVisitResult first_of_kind(Node* c, Node* p, void* data)
{
	Node*[]* first = data;
	if (!(*first)[c.kind.ordinal]) (*first)[c.kind.ordinal] = c;
	return RECURSE;
}

<*
 Whether `node`'s range ends right after `suffix`, its last token.
*>
fn bool ends_with(Node* node, String suffix)
{
	sz end = SOURCE.len;
	String[] lines = SOURCE.tsplit("\n");
	sz offset = 0;
	foreach (i, line : lines)
	{
		if (i == node.range.end.line)
		{
			end = offset + node.range.end.column;
			break;
		}
		offset += line.len + 1;
	}
	return end >= suffix.len && SOURCE[end - suffix.len:suffix.len] == suffix;
}

fn void statement_ranges_end_at_their_last_token() @test
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();
	proj.workspace.process_file("/virtual/ranges.c3", SOURCE);
	SourceFile* sf = proj.workspace.ctx.files.get("/virtual/ranges.c3")!!;
	Node*[] first = mem::temp_array(Node*, NodeKind::values.len);
	foreach (stmt : sf.ast.statements) cursor::visit(stmt, null, { .on_enter = &first_of_kind }, &first);
	Node* generic_type;
	foreach (stmt : first[NodeKind.FN_DECL.ordinal].as(FnDecl).body.as(CompoundStmt).statements)
	{
		if (stmt.kind == VAR_DECL && stmt.as(VarDecl).name.text == "bx") generic_type = stmt.as(VarDecl).type;
	}

	assert(ends_with(first[NodeKind.COMPOUND_STMT.ordinal], "x = 4;\n}"));
	assert(ends_with(first[NodeKind.IF_STMT.ordinal], "{ x = 1; }"));
	assert(ends_with(first[NodeKind.FOR_STMT.ordinal], "{ x++; }"));
	assert(ends_with(first[NodeKind.DO_WHILE_STMT.ordinal], "while (x > 0);"));
	assert(ends_with(first[NodeKind.FOREACH_STMT.ordinal].as(ForeachStmt).variable, "v"));
	assert(ends_with(first[NodeKind.CASE_STMT.ordinal], "nextcase 2;"));
	assert(ends_with(first[NodeKind.NEXTCASE_STMT.ordinal], "nextcase 2;"));
	assert(ends_with(first[NodeKind.CONTINUE_BREAK_STMT.ordinal], "break;"));
	assert(ends_with(first[NodeKind.CT_IF_STMT.ordinal], "$endif"));
	assert(ends_with(first[NodeKind.CT_FOR_STMT.ordinal], "$endfor"));
	assert(ends_with(first[NodeKind.CT_SWITCH_STMT.ordinal], "$endswitch"));
	assert(ends_with(first[NodeKind.CATCH_EXPR.ordinal], "catch r"));
	assert(ends_with(first[NodeKind.DESIGNATED_INITIALIZER_EXPR.ordinal], ".a = 1"));
	assert(ends_with(generic_type, "Box{int}"));
}
