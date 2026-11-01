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

	if (try c3_files = path::ls(tmem, clean_path, no_dirs: true, mask: "*.c3", recursive: true, rebase: clean_path))
	{
		foreach (p : c3_files)
		{
			paths.push(p.copy(allocator));
		}
	}

	if (with_c3i)
	{
		if (try c3i_files = path::ls(tmem, clean_path, no_dirs: true, mask: "*.c3i", recursive: true, rebase: clean_path))
		{
			foreach (p : c3i_files)
			{
				paths.push(p.copy(allocator));
			}
		}
	}

	return paths.array_view();
}
