module lsp::text_offset_test;
import lsp;

fn void characters_count_utf16_units() @test
{
	// `é` is one UTF-16 unit and two bytes; the emoji two units and four bytes.
	String text = "module app;\nString s = \"é😀x\";\n";
	test::eq(utils::compute_byte_offset(text, 1, 15), text.index_of_char('x')!!);
	test::eq(utils::compute_byte_offset(text, 1, 100), text.len - 1);
	test::eq(utils::compute_byte_offset(text, 5, 0), text.len);
}
