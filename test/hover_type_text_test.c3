module lsp::hover_type_text_test;
import lsp, uri;

const String SOURCE = "module demo;\nconst int[4] ARR = { 1, 2, 3, 4 };\n\nfn char[4]? get_names() => { 'a', 'b', 'c', 'd' };\n\nstruct Block @align(lengthof(ARR) * 4)\n{\n\tint x;\n}\n\nfn void main()\n{\n\tchar[lengthof(ARR)] first, second;\n\tif (try char[lengthof(ARR)] names = get_names())\n\t{\n\t\tfirst = names;\n\t}\n\tsecond = first;\n\tBlock b;\n}\n";

fn String hover_at(uint line, uint character) @local
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();
	Uri u = uri::from_file_path(mem, "/virtual/demo.c3");
	defer u.free();
	proj.workspace.process_file("/virtual/demo.c3", SOURCE);
	return hover::hover(&proj, u, { .line = line, .character = character }).tcopy() ?? "";
}

fn void shared_type_as_written() @test
{
	String hover = hover_at(12, 29);
	assert(hover.contains("char[lengthof(ARR)] second"), "%s", hover);
}
fn void try_type_as_written() @test
{
	String hover = hover_at(15, 11);
	assert(hover.contains("try char[lengthof(ARR)] names"), "%s", hover);
}
fn void attribute_arguments_as_written() @test
{
	String hover = hover_at(5, 15);
	assert(hover.contains("attribute @align(lengthof(ARR) * 4)"), "%s", hover);
}
