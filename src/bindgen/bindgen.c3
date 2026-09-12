module lsp::bindgen;

import std;

<*
 Main coordinator for C binding generation.
 Runs clang, parses AST JSON, translates types, and outputs C3 source code.
 @param options : "Bindgen configuration options."
 @return        "Exit code: 0 on success, 1 on failure."
*>
fn int run_bindgen(BindgenOptions options, bool is_cli = false) => @pool()
{
	if (options.header_path.len == 0)
	{
		if (is_cli)
		{
			io::eprintfn("Error: No C header file specified for --bindgen.");
		}
		else
		{
			log::error("No C header file specified for bindgen.");
		}
		return 1;
	}

	if (!file::exists(options.header_path))
	{
		if (is_cli)
		{
			io::eprintfn("Error: Specified header file '%s' does not exist.", options.header_path);
		}
		else
		{
			log::error("Specified header file '%s' does not exist.", options.header_path);
		}
		return 1;
	}

	String? json_ast = run_clang_ast_dump(tmem, options);
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