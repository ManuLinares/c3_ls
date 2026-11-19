module lsp::bitstruct_hover_completion_test;

import lsp, uri, std::io, std::collections::list;

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

const String FLAGS_SRC = `module flags_test;

bitstruct Kind : char
{
	bool ctl;
	bool sp;
}

const Kind[2] TABLE = {
	[0] = { .ctl, .sp },
	[1] = { .sp },
};
`;

fn void hover_and_definition_bitstruct_flag_designators() @test
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();
	proj.workspace.process_file("/virtual/flags.c3", FLAGS_SRC);
	Uri u = uri::from_file_path(tmem, "/virtual/flags.c3");

	// `{ .c|tl, ...`, `.s|p }` and `{ .s|p }`.
	LspPosition[3] positions = { { 9, 10 }, { 9, 16 }, { 10, 10 } };
	String[3] fields = { "ctl", "sp", "sp" };
	uint[3] lines = { 4, 5, 5 };
	foreach (i, pos : positions)
	{
		String h = hover::hover(&proj, u, pos)!!;
		assert(h.contains(string::tformat("bool %s", fields[i])), "hover %d: %s", i, h);
		LspLocation[] locs = definition::goto_definition(&proj, u, pos)!!;
		assert(locs.len == 1 && locs[0].range.start.line == lines[i], "definition %d", i);
	}
}

fn void completion_bitstruct_flag_designators() @test
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();
	proj.workspace.process_file("/virtual/flags.c3", FLAGS_SRC);
	Uri u = uri::from_file_path(tmem, "/virtual/flags.c3");

	// `{ .|ctl, ...` and `{ .|sp }`.
	LspPosition[2] positions = { { 9, 10 }, { 10, 10 } };
	foreach (i, pos : positions)
	{
		CompletionItem[] items = completion::resolve(&proj, u, pos)!!;
		assert(find_item(items, "ctl") != null && find_item(items, "sp") != null, "completion %d", i);
	}

	// `{ .ctl, .|sp }` omits the flag already set.
	CompletionItem[] items = completion::resolve(&proj, u, { 9, 16 })!!;
	assert(find_item(items, "ctl") == null && find_item(items, "sp") != null);
}

<* Completion labels at the `|` marker of `marked`. *>
fn List{String} labels_at(String marked)
{
	sz cut = marked.index_of_char('|')!!;
	String src = string::tformat("%s%s", marked[:cut], marked[cut + 1..]);
	LspProject proj;
	proj.init(mem);
	defer proj.free();
	proj.workspace.process_file("/virtual/marked.c3", src);
	uint line;
	sz line_start;
	foreach (j, c : src[:cut])
	{
		if (c != '\n') continue;
		line++;
		line_start = j + 1;
	}
	LspPosition pos = { line, (uint)(cut - line_start) };
	CompletionItem[] items = completion::resolve(&proj, uri::from_file_path(tmem, "/virtual/marked.c3"), pos)!!;
	List{String} labels;
	labels.tinit();
	foreach (item : items) labels.push(item.label.tcopy());
	return labels;
}

const String MARKED_HEAD = `module flags_test;

bitstruct Kind : ushort @private
{
	bool ctl;
	bool sp;
	bool blank;
}

const Kind[256] TABLE @private = {
`;

fn void completion_bitstruct_flag_designator_with_attribute() @test
{
	String[*] cases = {
		"\t[0..31] = { .ctl, | },\n};\n",
		"\t[0..31] = { .ctl, .| },\n};\n",
		"\t['0'..'1'] = { .ctl, .s| },\n};\n",
		"\t[9] = { .| },\n};\n",
		"\t[9] = { | },\n};\n",
	};
	String[*] want = { "sp blank", "sp blank", "sp", "ctl sp blank", "ctl sp blank" };
	foreach (i, c : cases)
	{
		List{String} labels = labels_at(string::tformat("%s%s", MARKED_HEAD, c));
		String got = string::tjoin(labels.array_view(), " ");
		assert(got == want[i], "case %d: %s", i, got);
	}
}

const String ARRAY_HEAD = `module arr_test;
struct Pt { int x; int y; }
struct Box { Pt[2] corners; Pt origin; }
`;

fn void completion_designators_in_arrays_and_positional_elements() @test
{
	String[*] cases = {
		"const Pt[2][3] GRID = { [0] = { [1] = { .| } } };\n",
		"Box b = { { { .| }, {} }, {} };\n",
		"Box b = { .corners = { [1] = { .| } } };\n",
		"Box b = { { {}, {} }, { .| } };\n",
		"Pt[2] p = { .| };\n",
		"Box b = { { .| }, {} };\n",
	};
	bool[*] has_fields = { true, true, true, true, false, false };
	foreach (i, c : cases)
	{
		List{String} labels = labels_at(string::tformat("%s%s", ARRAY_HEAD, c));
		bool x = labels.contains("x");
		bool y = labels.contains("y");
		assert(x == has_fields[i] && y == has_fields[i], "case %d: %s", i, labels);
	}
}

fn void definition_designator_in_positional_element() @test
{
	String src = string::tformat("%s%s", ARRAY_HEAD, "Box b = { { { .y = 1 }, {} }, {} };\n");
	LspProject proj;
	proj.init(mem);
	defer proj.free();
	proj.workspace.process_file("/virtual/arr.c3", src);
	Uri u = uri::from_file_path(tmem, "/virtual/arr.c3");
	// `{ .|y = 1 }` resolves to `Pt.y` on line 1.
	LspLocation[] locs = definition::goto_definition(&proj, u, { 3, 15 })!!;
	assert(locs.len == 1 && locs[0].range.start.line == 1 && locs[0].range.start.character == 23, "%s", locs);
}

fn void completion_designator_of_unknown_type_offers_nothing() @test
{
	// `$Param` is only known at expansion: no field to offer, and nothing else fits after `.`.
	String src = "module t;\nmacro make($Param)\n{\n\t$Param p = { .| };\n\treturn p;\n}\n";
	List{String} labels = labels_at(src);
	assert(labels.len() == 0, "%s", labels);
}
