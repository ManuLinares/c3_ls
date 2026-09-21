module lsp::bindgen;

import std;

<*
 Standard root directories for header searches across platforms.
*>
const String[*] SYSTEM_SEARCH_ROOTS = {
	"/usr/include",
	"/usr/local/include",
	"/opt/homebrew/include",
	"/Library/Developer/CommandLineTools/SDKs"
};

fn void add_unique_include(BindgenOptions* options, String dir)
{
	String clean = dir.trim();
	if (clean.len == 0)
	{
		return;
	}

	foreach (existing : options.include_dirs)
	{
		if (existing == clean)
		{
			return;
		}
	}
	List{String} list;
	list.tinit();
	foreach (d : options.include_dirs)
	{
		list.push(d.copy(tmem));
	}
	list.push(clean.copy(tmem));
	options.include_dirs = list.to_tarray();
}

<*
 Searches for a missing header file across:
 1. The target header's containing directory.
 2. User-provided include directories (options.include_dirs).
 3. Standard system include roots.
 @return "Base include directory resolving the missing header, or NOT_FOUND."
*>
fn String? find_missing_header_directory(BindgenOptions options, String missing_header)
{
	String needle = missing_header;

	List{String} search_roots;
	search_roots.tinit();

	String target_dir = options.header_path;
	if (file::is_file(target_dir))
	{
		sz last_slash = target_dir.rindex_of_char('/') ?? target_dir.rindex_of_char('\\') ?? (sz)0;
		if (last_slash > 0)
		{
			target_dir = target_dir[:last_slash];
		}
	}
	target_dir = target_dir.trim_right("/\\");
	if (target_dir.len > 0)
	{
		search_roots.push(target_dir);
	}

	foreach (inc : options.include_dirs)
	{
		String clean_inc = inc.trim().trim_right("/\\");
		if (clean_inc.len > 0)
		{
			search_roots.push(clean_inc);
		}
	}

	foreach (sys : SYSTEM_SEARCH_ROOTS)
	{
		search_roots.push(sys);
	}

	foreach (root : search_roots)
	{
		if (!file::is_dir(root))
		{
			continue;
		}

		String direct = string::tformat("%s/%s", root, needle);
		if (file::is_file(direct))
		{
			return root;
		}

		Path? root_path = path::tnew(root);
		if (catch root_path)
		{
			continue;
		}

		if (try entries = path::ls(tmem, root_path, no_dirs: false, mask: "", recursive: false, rebase: root_path))
		{
			foreach (entry : entries)
			{
				String sub = (String)entry;
				if (!file::is_dir(sub))
				{
					continue;
				}

				String sub_cand = string::tformat("%s/%s", sub, needle);
				if (file::is_file(sub_cand))
				{
					return sub;
				}

				Path? sub_path = path::tnew(sub);
				if (catch sub_path)
				{
					continue;
				}

				if (try nested_entries = path::ls(tmem, sub_path, no_dirs: false, mask: "", recursive: false, rebase: sub_path))
				{
					foreach (nested : nested_entries)
					{
						String nested_dir = (String)nested;
						if (file::is_dir(nested_dir))
						{
							String nested_cand = string::tformat("%s/%s", nested_dir, needle);
							if (file::is_file(nested_cand))
							{
								return nested_dir;
							}
						}
					}
				}
			}
		}
	}

	return NOT_FOUND~;
}

fn bool is_include_root_dir(BindgenOptions options, String dir) @local
{
	String clean = dir.trim_right("/\\");
	if (clean.len == 0 || clean == "/" || clean == "\\")
	{
		return true;
	}

	foreach (root : SYSTEM_SEARCH_ROOTS)
	{
		if (clean == root.trim_right("/\\"))
		{
			return true;
		}
	}

	foreach (inc : options.include_dirs)
	{
		if (clean == inc.trim_right("/\\"))
		{
			return true;
		}
	}

	return false;
}

fn String deduce_package_dir(BindgenOptions options)
{
	if (options.target_dir.len > 0)
	{
		return options.target_dir;
	}

	if (file::is_dir(options.header_path))
	{
		String dir = options.header_path;
		if (!dir.ends_with("/") && !dir.ends_with("\\"))
		{
			dir = string::tformat("%s/", dir);
		}
		return dir;
	}

	sz last_slash = 0;
	if (try idx = options.header_path.rindex_of_char('/'))
	{
		last_slash = idx + 1;
	}
	else if (try idx = options.header_path.rindex_of_char('\\'))
	{
		last_slash = idx + 1;
	}

	if (last_slash > 0)
	{
		String parent = options.header_path[:last_slash];
		if (!is_include_root_dir(options, parent))
		{
			return parent;
		}
	}

	return "";
}

<*
 Auto-discovers peer include directories under the target's parent directory
 (e.g. Windows SDK: um/ -> shared/, km/, ucrt/).
*>
fn void auto_discover_peer_includes(BindgenOptions* options)
{
	String base_dir = options.header_path;
	if (file::is_file(base_dir))
	{
		sz last_slash = base_dir.rindex_of_char('/') ?? base_dir.rindex_of_char('\\') ?? (sz)0;
		if (last_slash > 0)
		{
			base_dir = base_dir[:last_slash];
		}
	}
	base_dir = base_dir.trim_right("/\\");

	sz parent_slash = base_dir.rindex_of_char('/') ?? base_dir.rindex_of_char('\\') ?? (sz)0;
	if (parent_slash == 0)
	{
		return;
	}

	String parent_dir = base_dir[:parent_slash];
	if (parent_dir == "/" || parent_dir == "/usr" || parent_dir == "/usr/include" ||
		parent_dir == "/usr/local" || parent_dir == "/usr/local/include")
	{
		return;
	}

	Path? parent_path = path::tnew(parent_dir);
	if (catch parent_path)
	{
		return;
	}

	if (try subs = path::ls(tmem, parent_path, no_dirs: false, mask: "", recursive: false, rebase: parent_path))
	{
		foreach (sub : subs)
		{
			String sub_str = (String)sub;
			if (sub_str != base_dir && file::is_dir(sub_str))
			{
				Path? sub_p = path::tnew(sub_str);
				if (try sp = sub_p)
				{
					if (try headers = path::ls(tmem, sp, no_dirs: true, mask: "*.h", recursive: false))
					{
						if (headers.len() > 0)
						{
							add_unique_include(options, sub_str);
						}
					}
				}
			}
		}
	}
}

<*
 Main coordinator for C binding generation.
 Runs clang with self-healing, parses AST JSON, translates types, and outputs C3 source code.
 @param options : "Bindgen configuration options."
 @return        "Exit code: 0 on success, 1 on failure."
*>
fn int run_bindgen(BindgenOptions options, bool is_cli = false) => @pool()
{
	if (options.header_path.len == 0)
	{
		if (is_cli)
		{
			io::eprintfn("Error: No C header file or directory specified for --bindgen.");
		}
		else
		{
			log::error("No C header file or directory specified for bindgen.");
		}
		return 1;
	}

	if (!file::exists(options.header_path))
	{
		if (is_cli)
		{
			io::eprintfn("Error: Specified header path '%s' does not exist.", options.header_path);
		}
		else
		{
			log::error("Specified header path '%s' does not exist.", options.header_path);
		}
		return 1;
	}

	auto_discover_peer_includes(&options);

	options.target_dir = deduce_package_dir(options);

	String temp_wrapper_path = "";
	if (file::is_dir(options.header_path))
	{
		String target_dir = options.target_dir;

		Path? dir_path = path::tnew(target_dir);
		if (catch dir_path)
		{
			if (is_cli)
			{
				io::eprintfn("Error: Invalid directory path '%s'.", target_dir);
			}
			return 1;
		}

		PathList? entries = path::ls(tmem, dir_path, no_dirs: true, mask: "*.h", recursive: true, rebase: dir_path);
		if (catch entries)
		{
			if (is_cli)
			{
				io::eprintfn("Error: Failed to read directory '%s'.", target_dir);
			}
			else
			{
				log::error("Failed to read directory '%s'.", target_dir);
			}
			return 1;
		}
		if (entries.len() == 0)
		{
			if (is_cli)
			{
				io::eprintfn("Error: No .h header files found in directory '%s'.", target_dir);
			}
			else
			{
				log::error("No .h header files found in directory '%s'.", target_dir);
			}
			return 1;
		}

		Path? tmp_dir = path::temp_directory(tmem);
		if (catch tmp_dir)
		{
			if (is_cli)
			{
				io::eprintfn("Error: Failed to access temporary directory.");
			}
			return 1;
		}

		Path wrapper = tmp_dir.tappend(string::tformat("c3_bindgen_wrap_%d.h", (int)datetime::now().sec)) ?? (Path)"";
		temp_wrapper_path = (String)wrapper;

		DString wrap_content;
		wrap_content.tinit();
		wrap_content.append("#pragma once\n");
		foreach (h_file : entries)
		{
			wrap_content.appendf("#include \"%s\"\n", (String)h_file);
		}

		if (catch file::save(wrapper, wrap_content.str_view()))
		{
			if (is_cli)
			{
				io::eprintfn("Error: Failed to create temporary wrapper header.");
			}
			return 1;
		}

		add_unique_include(&options, target_dir);
		options.header_path = temp_wrapper_path;
	}
	defer
	{
		if (temp_wrapper_path.len > 0 && file::exists(temp_wrapper_path))
		{
			(void)file::delete(temp_wrapper_path);
		}
	};

	String? json_ast = run_clang_ast_dump(tmem, &options);
	if (catch err = json_ast)
	{
		if (is_cli)
		{
			io::eprintfn("Error: Failed to run clang AST dump (%s). Ensure 'clang' is installed and in PATH.", err);
		}
		else
		{
			log::error("Failed to run clang AST dump (%s). Ensure 'clang' is installed and in PATH.", err);
		}
		return 1;
	}

	Object*? parsed = json::tparse(json_ast);
	if (catch err = parsed)
	{
		if (is_cli)
		{
			io::eprintfn("Error: Failed to parse Clang AST JSON output (%s).", err);
		}
		else
		{
			log::error("Failed to parse Clang AST JSON output (%s).", err);
		}
		return 1;
	}

	Object* root_obj = parsed;
	if (!root_obj)
	{
		if (is_cli)
		{
			io::eprintfn("Error: Clang AST JSON output was empty.");
		}
		else
		{
			log::error("Clang AST JSON output was empty.");
		}
		return 1;
	}

	CTranslationUnit tu;
	tu.init(mem);
	defer tu.free();

	parse_clang_ast_json(tmem, &tu, root_obj, options);

	String generated_code = emit_c3_bindings(tmem, &tu, options);

	if (options.output_path.len > 0)
	{
		if (catch err = file::save(options.output_path, generated_code))
		{
			if (is_cli)
			{
				io::eprintfn("Error: Failed to write output file '%s' (%s).", options.output_path, err);
			}
			else
			{
				log::error("Failed to write output file '%s' (%s).", options.output_path, err);
			}
			return 1;
		}
		sz enum_count = 0;
		sz constdef_count = 0;
		foreach (e : tu.enums)
		{
			if (e.is_constdef)
			{
				constdef_count++;
			}
			else
			{
				enum_count++;
			}
		}

		if (is_cli)
		{
			io::printfn("Generated C3 bindings: '%s' (%d functions, %d variables, %d structs, %d enums, %d constdefs, %d aliases).",
				options.output_path,
				(int)tu.functions.len(),
				(int)tu.variables.len(),
				(int)tu.structs.len(),
				(int)enum_count,
				(int)constdef_count,
				(int)tu.typedefs.len()
			);
		}
		else
		{
			log::info("Generated C3 bindings: '%s' (%d functions, %d variables, %d structs, %d enums, %d constdefs, %d aliases).",
				options.output_path,
				(int)tu.functions.len(),
				(int)tu.variables.len(),
				(int)tu.structs.len(),
				(int)enum_count,
				(int)constdef_count,
				(int)tu.typedefs.len()
			);
		}
		return 0;
	}

	if (is_cli)
	{
		io::print(generated_code);
	}
	return 0;
}