module lsp::label_test;

import lsp, lsp::analysis::completion, uri, std::collections::list;

const String SOURCE = "module app;\nfn void main(String[] args)\n{\n\tforeach LINE: (i, s : args)\n\t{\n\t\tdo CHECK_WS:\n\t\t{\n\t\t\tforeach (c : s)\n\t\t\t{\n\t\t\t\tif (c == ' ') break CHECK_WS;\n\t\t\t}\n\t\t\tcontinue LINE;\n\t\t};\n\t\tswitch SW: (i)\n\t\t{\n\t\t\tcase 0:\n\t\t\t\tnextcase SW: 1;\n\t\t\tdefault:\n\t\t\t\tbreak LINE;\n\t\t}\n\t}\n}\n";
const String PATH = "/virtual/labels.c3";

fn LspRange definition_at(LspProject* proj, uint line, uint character)
{
	LspLocation[] locs = definition::goto_definition(proj, uri::from_file_path(tmem, PATH), { line, character })!!;
	assert(locs.len == 1);
	return locs[0].range;
}

fn void jumps_go_to_their_label() @test
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();
	proj.workspace.process_file(PATH, SOURCE);

	LspRange r = definition_at(&proj, 9, 25);
	assert(r.start.line == 5 && r.start.character == 5 && r.end.character == 13);
	r = definition_at(&proj, 11, 13);
	assert(r.start.line == 3 && r.start.character == 9);
	r = definition_at(&proj, 16, 14);
	assert(r.start.line == 13 && r.start.character == 9);
	r = definition_at(&proj, 18, 11);
	assert(r.start.line == 3 && r.start.character == 9);
	r = definition_at(&proj, 3, 10);
	assert(r.start.line == 3 && r.start.character == 9);
}

fn void hover_shows_labeled_statement_and_line() @test
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();
	proj.workspace.process_file(PATH, SOURCE);

	String h = hover::hover(&proj, uri::from_file_path(tmem, PATH), { 11, 13 })!!;
	assert(h.contains("foreach LINE: (i, s : args)"), "%s", h);
	assert(h.contains("line 4"), "%s", h);
	assert(!h.contains("module"), "%s", h);
	h = hover::hover(&proj, uri::from_file_path(tmem, PATH), { 9, 25 })!!;
	assert(h.contains("do CHECK_WS:"), "%s", h);
}

fn void references_and_rename_cover_label_and_jumps() @test
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();
	proj.workspace.process_file(PATH, SOURCE);
	Uri u = uri::from_file_path(tmem, PATH);

	LspLocation[] refs = references::find_references(&proj, u, { 18, 11 }, { .includeDeclaration = true })!!;
	assert(refs.len == 3);
	refs = references::find_references(&proj, u, { 13, 9 }, { .includeDeclaration = false })!!;
	assert(refs.len == 1 && refs[0].range.start.line == 16);

	LspRange name = rename::prepare_rename(&proj, u, { 5, 6 })!!;
	assert(name.start.character == 5 && name.end.character == 13);
	WorkspaceEdit edit = rename::rename(&proj, u, { 5, 6 }, "BLANK")!!;
	assert(edit.documentChanges[0].edits.len == 2);
}

fn String[] labels_at(String source, uint line, uint character)
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();
	proj.workspace.process_file(PATH, source);
	List{String} labels;
	labels.tinit();
	foreach (item : completion::resolve(&proj, uri::from_file_path(tmem, PATH), { line, character })!!)
	{
		labels.push(string::tformat("%s=%s", item.label, item.insertText));
	}
	return labels.array_view();
}

fn void completion_offers_labels_the_jump_can_name() @test
{
	String source = SOURCE.treplace("continue LINE;", "continue ;").treplace("nextcase SW: 1;", "nextcase ;").treplace("break LINE;", "break ;");
	String[] at_break = labels_at(source, 18, 10);
	assert(at_break.len == 2 && at_break[0] == "SW=SW" && at_break[1] == "LINE=LINE", "%s", at_break);
	String[] at_continue = labels_at(source, 11, 12);
	assert(at_continue.len == 2 && at_continue[0] == "CHECK_WS=CHECK_WS" && at_continue[1] == "LINE=LINE", "%s", at_continue);
	String[] at_nextcase = labels_at(source, 16, 13);
	assert(at_nextcase.len > 1 && at_nextcase[0] == "SW=SW: ", "%s", at_nextcase);
	foreach (l : at_nextcase) assert(!l.starts_with("LINE="), "%s", at_nextcase);
}

fn void label_end_resolves() @test
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();
	proj.workspace.process_file(PATH, SOURCE);

	LspRange r = definition_at(&proj, 11, 16);
	assert(r.start.line == 3 && r.start.character == 9);
	r = definition_at(&proj, 3, 13);
	assert(r.start.line == 3 && r.start.character == 9);
}

fn void completion_while_typing_jumps() @test
{
	String typing_keyword = SOURCE.treplace("continue LINE;", "cont");
	String[] at_keyword = labels_at(typing_keyword, 11, 7);
	bool found;
	foreach (l : at_keyword) if (l.starts_with("continue=")) found = true;
	assert(found, "%s", at_keyword);

	String typing_label = SOURCE.treplace("continue LINE;", "continue ");
	String[] at_label = labels_at(typing_label, 11, 12);
	assert(at_label.len == 2 && at_label[0] == "CHECK_WS=CHECK_WS" && at_label[1] == "LINE=LINE", "%s", at_label);
}
