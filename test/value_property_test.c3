module lsp::value_property_test;

import lsp, lsp::analysis::completion, uri;

const String SOURCE = `
module app::props;
enum Month : char
{
	JAN,
	FEB,
}
struct Date
{
	Month month;
}
struct Segment
{
	int id;
}
struct Stream
{
	Segment[] segments;
}
struct Bag
{
	int[] items;
}
macro void Bag.@each(&self; @body(int item))
{
	foreach (x : self.items) @body(x);
}
fn void run(String path, bool recursive = false) {}
fn void main()
{
	Stream s;
	Date d;
	int[4] arr;
	any a;
	Bag bag;
	sz n = s.segments.len + arr.len;
	Segment* p = s.segments.ptr;
	char o = d.month.ordinal;
	typeid t = a.type;
	run("x", recursive: true);
	bag.@each(; int item)
	{
		int y = item;
	};
}
`;

fn LspPosition at(String needle, sz offset = 0)
{
	sz index = SOURCE.index_of(needle)!!;
	String before = SOURCE[:index];
	sz line_start = (before.rindex_of_char('\n') ?? -1) + 1;
	return { .line = (uint)before.count("\n"), .character = (uint)(index - line_start + offset) };
}

macro @with_project(; @body(LspProject* proj, Uri u))
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();
	proj.workspace.process_file("/virtual/props.c3", SOURCE);
	@body(&proj, uri::from_file_path(tmem, "/virtual/props.c3"));
}

fn String hover_at(LspProject* proj, Uri u, String needle, sz offset = 0) => hover::hover(proj, u, at(needle, offset)) ?? "";

fn String? detail_of(LspProject* proj, Uri u, String needle, String label)
{
	foreach (item : completion::resolve(proj, u, at(needle))!!)
	{
		if (item.label == label) return item.detail;
	}
	return NOT_FOUND~;
}

fn void hover_shows_value_properties() @test
{
	@with_project(; LspProject* proj, Uri u)
	{
		assert(hover_at(proj, u, "len + arr").contains("sz len"));
		assert(hover_at(proj, u, "len;").contains("sz len"));
		assert(hover_at(proj, u, "ptr;").contains("Segment* ptr"));
		assert(hover_at(proj, u, "ordinal;").contains("char ordinal"));
		assert(hover_at(proj, u, "type;").contains("typeid type"));
	};
}

fn void completion_lists_value_properties_by_kind() @test
{
	@with_project(; LspProject* proj, Uri u)
	{
		assert(detail_of(proj, u, "len + arr", "len")!! == "sz");
		assert(detail_of(proj, u, "len + arr", "ptr")!! == "Segment*");
		assert(@catch(detail_of(proj, u, "len + arr", "id")));
		assert(@catch(detail_of(proj, u, "len;", "ptr")));
		assert(detail_of(proj, u, "ordinal;", "ordinal")!! == "char");
		assert(detail_of(proj, u, "type;", "ptr")!! == "void*");
	};
}

fn void hover_on_named_argument_shows_parameter() @test
{
	@with_project(; LspProject* proj, Uri u)
	{
		assert(hover_at(proj, u, "recursive: true").contains("bool recursive = false"));
	};
}

fn void hover_on_macro_body_parameter() @test
{
	@with_project(; LspProject* proj, Uri u)
	{
		assert(hover_at(proj, u, "int item)\n\t{").starts_with("```c3\nint\n```"));
		assert(hover_at(proj, u, "item)\n\t{").contains("int item"));
		assert(hover_at(proj, u, "item;").contains("int item"));
	};
}
