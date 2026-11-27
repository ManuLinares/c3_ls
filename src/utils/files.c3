module lsp::utils;

import std::io;
import std::collections::list;

fn String[] find_source_files(Allocator allocator, Path base_path, bool with_c3i = true)
{
	String clean_str = base_path.trim_right("/\\");
	Path? clean_path = path::tnew(clean_str);
	if (catch clean_path) return {};

	List{String} paths;
	paths.init(allocator);

	if (try files = path::ls(tmem, clean_path, no_dirs: true, recursive: true, rebase: clean_path))
	{
		foreach (p : files)
		{
			if (p.has_extension("c3") || (with_c3i && p.has_extension("c3i"))) paths.push(p.copy(allocator));
		}
	}

	return paths.array_view();
}
