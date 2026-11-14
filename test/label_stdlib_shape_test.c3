module lsp::label_stdlib_shape_test;

import lsp, lsp::analysis::completion, uri, std::collections::list;

const String PATH = "/virtual/win.c3";

fn String source_with(String jump) => string::tformat(`module std::os::process;
fn WString convert_command_line_win32(String[] command_line) @inline @feat(WIN32) @local
{
    DString str = dstring::temp_with_capacity(512);
    foreach LINE: (i, s : command_line)
    {
        if (i != 0) str.append(' ');

        do CHECK_WS:
        {
            foreach (c : s)
            {
                switch (c)
                {
                    case '\t':
                    case ' ':
                    case '\v':
                        break CHECK_WS;
                }
            }
            str.append(s);
            %s
        };
        str.append('"');
    }
    str.append('\0');
    return str.str_view().to_temp_wstring()!!;
}
`, jump);

fn String[] items_at(String source, uint line, uint character)
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();
	proj.workspace.process_file(PATH, source);
	List{String} labels;
	labels.tinit();
	foreach (item : completion::resolve(&proj, uri::from_file_path(tmem, PATH), { line, character })!!)
	{
		labels.push(item.label.tcopy());
	}
	return labels.array_view();
}

fn bool has(String[] labels, String label)
{
	foreach (l : labels) if (l == label) return true;
	return false;
}

fn void keyword_while_typing() @test
{
	String[] items = items_at(source_with("cont"), 21, 16);
	assert(has(items, "continue"), "%s", items);
}

fn void labels_after_jump_keyword() @test
{
	String[] items = items_at(source_with("continue "), 21, 21);
	assert(items.len == 2 && items[0] == "CHECK_WS" && items[1] == "LINE", "%s", items);
}
