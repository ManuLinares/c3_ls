module lsp::enum_fault_property_test;
import lsp, uri;

const String SOURCE = "module demo;\n\nenum Color : char { RED, GREEN }\nconstdef Mode : int { FAST = 1, SLOW = 2 }\nfaultdef OOPS;\n\nfn void main()\n{\n\tColor col = RED;\n\tMode mode = Mode.FAST;\n\tfault err = OOPS;\n\tString a = col.description;\n\tString c = err.description;\n\tint d = (int)mode;\n}\n";
const String TYPING_MODE = "module demo;\n\nenum Color : char { RED, GREEN }\nconstdef Mode : int { FAST = 1, SLOW = 2 }\nfaultdef OOPS;\n\nfn void main()\n{\n\tColor col = RED;\n\tMode mode = Mode.FAST;\n\tfault err = OOPS;\n\tString a = col.description;\n\tString c = err.description;\n\tint d = (int)mode;\n\tmode.\n}\n";

fn String members_at(uint line, uint character, String source = SOURCE) @local
{
	LspProject proj;
	proj.init(mem);
	defer proj.free();
	Uri u = uri::from_file_path(mem, "/virtual/demo.c3");
	defer u.free();
	proj.workspace.process_file("/virtual/demo.c3", source);
	DString out;
	out.tinit();
	foreach (item : completion::resolve(&proj, u, { .line = line, .character = character })!!) out.appendf(" %s ", item.label);
	return out.str_view();
}

fn void enum_value_has_ordinal_and_description() @test => test::eq(members_at(11, 16), " ordinal  description ");
fn void fault_has_description_and_type() @test => test::eq(members_at(12, 16), " type  description ");
fn void constdef_value_has_no_properties() @test => test::eq(members_at(14, 6, TYPING_MODE), "");
