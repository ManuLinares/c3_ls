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
	if (file::is_file(target_dir)) target_dir = ((Path)target_dir).dirname();
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

	String parent = ((Path)options.header_path).dirname();
	if (parent == "." || is_include_root_dir(options, parent)) return "";
	return options.header_path[:parent.len + 1];
}

<*
 Auto-discovers peer include directories under the target's parent directory
 (e.g. Windows SDK: um/ -> shared/, km/, ucrt/).
*>
fn void auto_discover_peer_includes(BindgenOptions* options)
{
	String base_dir = options.header_path;
	if (file::is_file(base_dir)) base_dir = ((Path)base_dir).dirname();
	base_dir = base_dir.trim_right("/\\");

	String parent_dir = ((Path)base_dir).dirname();
	if (parent_dir == "." || parent_dir == "/" || parent_dir == "/usr" || parent_dir == "/usr/include" ||
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
 Reports an error on stderr for CLI runs, or through the logger otherwise.
*>
macro void report_error(bool is_cli, String $format, ...) @local
{
	if (is_cli)
	{
		io::eprintfn("Error: " +++ $format, ...$vaarg);
	}
	else
	{
		log::error($format, ...$vaarg);
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
	json::max_depth = 512;

	if (options.header_path.len == 0)
	{
		report_error(is_cli, "No C header file or directory specified for --bindgen.");
		return 1;
	}

	if (!file::exists(options.header_path))
	{
		report_error(is_cli, "Specified header path '%s' does not exist.", options.header_path);
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
			report_error(is_cli, "Invalid directory path '%s'.", target_dir);
			return 1;
		}

		PathList? entries = path::ls(tmem, dir_path, no_dirs: true, mask: "*.h", recursive: true, rebase: dir_path);
		if (catch entries)
		{
			report_error(is_cli, "Failed to read directory '%s'.", target_dir);
			return 1;
		}
		if (entries.len() == 0)
		{
			report_error(is_cli, "No .h header files found in directory '%s'.", target_dir);
			return 1;
		}

		Path? tmp_dir = path::temp_directory(tmem);
		if (catch tmp_dir)
		{
			report_error(is_cli, "Failed to access temporary directory.");
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
			report_error(is_cli, "Failed to create temporary wrapper header.");
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
		report_error(is_cli, "Failed to run clang AST dump (%s). Ensure 'clang' is installed and in PATH.", err);
		return 1;
	}

	Object*? parsed = json::tparse(json_ast);
	if (catch err = parsed)
	{
		report_error(is_cli, "Failed to parse Clang AST JSON output (%s).", err);
		return 1;
	}

	Object* root_obj = parsed;
	if (!root_obj)
	{
		report_error(is_cli, "Clang AST JSON output was empty.");
		return 1;
	}

	CTranslationUnit tu;
	tu.init(mem);
	defer tu.free();

	parse_clang_ast_json(tmem, &tu, root_obj, options);

	String? macro_dump = run_clang_macro_dump(tmem, options);
	if (catch err = macro_dump)
	{
		report_error(is_cli, "Failed to run clang preprocessor (%s).", err);
		return 1;
	}
	parse_macro_constants(tmem, &tu, macro_dump, options);

	String generated_code = emit_c3_bindings(tmem, &tu, options);

	if (options.output_path.len > 0)
	{
		if (catch err = file::save(options.output_path, generated_code))
		{
			report_error(is_cli, "Failed to write output file '%s' (%s).", options.output_path, err);
			return 1;
		}
		sz constdef_count;
		foreach (e : tu.enums)
		{
			if (e.is_constdef) constdef_count++;
		}
		String summary = string::tformat("Generated C3 bindings: '%s' (%d functions, %d variables, %d structs, %d enums, %d constdefs, %d aliases).",
			options.output_path, tu.functions.len(), tu.variables.len(), tu.structs.len(),
			tu.enums.len() - constdef_count, constdef_count, tu.typedefs.len());
		if (is_cli)
		{
			io::printn(summary);
		}
		else
		{
			log::info("%s", summary);
		}
		return 0;
	}

	if (is_cli)
	{
		io::print(generated_code);
	}
	return 0;
}