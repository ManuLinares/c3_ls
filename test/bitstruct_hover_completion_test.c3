module lsp::bitstruct_hover_completion_test;

import lsp, uri, std::io;

const String SRC = `module bits_test;

bitstruct Flags : char
{
	bool ready : 0;
	bool busy : 1;
}

struct Reg
{
	int id;
	bitstruct bits : char
	{
		bool on : 0;
		bool err : 1;
	}
	union
	{
		int as_int;
		float as_float;
	}
}

fn void main()
{
	Flags f;
	f.ready = true;
	Reg r;
	r.bits.on = true;
	r.id = 1;
}
`;

const String PATH = "/virtual/bits.c3";

<* Position just after the n-th occurrence of `needle` in SRC. *>
fn LspPosition after(String needle, int nth = 0)
{
	sz from = 0;
	for (int i = 0; ; i++)
	{
		sz idx = SRC[from..].index_of(needle)!! + from;
		if (i == nth)
		{
			sz end = idx + needle.len;
			uint line = 0;
			sz line_start = 0;
			foreach (j, c : SRC[:end])
			{
				if (c == '\n')
				{
					line++;
					line_start = j + 1;
				}
			}
			return { .line = line, .character = (uint)(end - line_start) };
		}
		from = idx + needle.len;
	}
}

fn CompletionItem* find_item(CompletionItem[] items, String label)
{
	foreach (&item : items)
	{
		if (item.label == label) return item;
	}
	return null;
}

fn void hover_bitstruct_declaration_and_usage() @test
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();
	proj.workspace.process_file(PATH, SRC);
	Uri u = uri::from_file_path(tmem, PATH);

	// Inside `Flags` at its declaration and at `Flags f;`.
	LspPosition[2] positions = { after("bitstruct Fl"), after("\tFl") };
	foreach (pos : positions)
	{
		String h = hover::hover(&proj, u, pos)!!;
		assert(h.contains("bitstruct Flags"), "hover: %s", h);
	}
}

fn void completion_bitstruct_members() @test
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();
	proj.workspace.process_file(PATH, SRC);
	Uri u = uri::from_file_path(tmem, PATH);

	// `f.|ready = true;`
	CompletionItem[] items = completion::resolve(&proj, u, after("f."))!!;
	assert(find_item(items, "ready") != null);
	assert(find_item(items, "busy") != null);
}

fn void completion_nested_bitstruct_and_union_in_struct() @test
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();
	proj.workspace.process_file(PATH, SRC);
	Uri u = uri::from_file_path(tmem, PATH);

	// `r.|bits.on = true;`
	CompletionItem[] items = completion::resolve(&proj, u, after("r."))!!;
	assert(find_item(items, "id") != null);

	CompletionItem* bits = find_item(items, "bits");
	assert(bits != null);
	assert(bits.detail == "bitstruct bits", "detail: %s", bits.detail);

	// Anonymous union members are reachable directly.
	assert(find_item(items, "as_int") != null);
	assert(find_item(items, "as_float") != null);

	// `r.bits.|on = true;`
	items = completion::resolve(&proj, u, after("r.bits."))!!;
	assert(find_item(items, "on") != null);
	assert(find_item(items, "err") != null);
}
