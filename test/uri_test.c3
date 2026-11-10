module lsp::uri_test @test;

import uri;

fn void normalize_path_matches_file_keys()
{
	test::eq(uri::normalize_path(tmem, "a\\b/c"), "a/b/c");
	$if env::WIN32:
		test::eq(uri::normalize_path(tmem, "c:\\x"), "C:/x");
	$else
		test::eq(uri::normalize_path(tmem, "c:\\x"), "c:/x");
	$endif
	test::eq(uri::normalize_path(tmem, "c:\\x"), uri::from_file_path(tmem, "c:\\x").path);
}
