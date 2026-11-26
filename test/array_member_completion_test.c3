module lsp::array_member_completion_test;
import lsp, uri;

const String SOURCE = "module demo;\nconst int[4] ARR = { 1, 2, 3, 4 };\n\nfn void main()\n{\n\tchar[lengthof(ARR)] computed;\n\tchar[4] plain;\n\tchar[] slice = &plain;\n\tusz n = computed.len + plain.len + slice.len;\n}\n";

fn String members_at(uint character) @local
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();
	Uri u = uri::from_file_path(mem, "/virtual/demo.c3");
	defer u.free();
	proj.workspace.process_file("/virtual/demo.c3", SOURCE);
	DString out;
	out.tinit();
	foreach (item : completion::resolve(&proj, u, { .line = 8, .character = character })!!) out.appendf("%s ", item.label);
	return out.str_view().trim();
}

fn void array_with_computed_length_has_no_ptr() @test => test::eq(members_at(18), "len");
fn void array_has_no_ptr() @test => test::eq(members_at(30), "len");
fn void slice_has_ptr() @test => test::eq(members_at(42), "len ptr");
