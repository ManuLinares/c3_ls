module lsp::analysis::code_actions;

import lsp::core;
import lsp;
import uri;
import std::collections::list;
import std::io;
import std::io::file;
import std::io::path;
import std::collections::set;

const String CMD_GENERATE_BINDINGS = "c3.generateBindings";

<*
 Standard search paths for C headers.
*>
const String[*] SYSTEM_HEADER_DIRS = {
	"/usr/include",
	"/usr/local/include",
	"/opt/homebrew/include",
	"/usr/include/x86_64-linux-gnu",
	"/usr/include/aarch64-linux-gnu"
};

<*
 Determines the appropriate output file path for generated bindings.
 Places in project's lib/ directory if in a project, or alongside source file.
 @param project     : "Pointer to current project."
 @param source_path : "Path of the file requesting the module."
 @param module_name : "Target module name."
 @return            "Destination path for .c3i / .c3 file."
*>
fn String determine_output_binding_path(LspProject* project, String source_path, String module_name)
{
	if (project && project.config.root_path.len > 0)
	{
		Path? root_path = path::tnew(project.config.root_path);
		if (try base = root_path)
		{
			Path lib_dir = base.tappend("lib") ?? (Path)"";
			return string::tformat("%s/%s.c3i", lib_dir, module_name);
		}
	}

	sz last_slash = source_path.rindex_of_char('/') ?? source_path.rindex_of_char('\\') ?? (sz)0;
	if (last_slash > 0)
	{
		String dir = source_path[:last_slash];
		return string::tformat("%s/%s.c3i", dir, module_name);
	}

	return string::tformat("%s.c3i", module_name);
}

<*
 Extracts missing module name from a "No module '<name>' found" diagnostic message.
 @param message : "Diagnostic message string."
 @return        "Module name, or empty string if not a missing module error."
*>
fn String extract_missing_module_from_diagnostic(String message)
{
	const String PREFIX = "No module '";
	const String SUFFIX = "' found";

	if (!message.starts_with(PREFIX) || !message.contains(SUFFIX))
	{
		return "";
	}

	String rest = message.strip_prefix(PREFIX);
	sz end_idx = rest.index_of_char('\'') ?? (sz)0;
	if (end_idx == 0)
	{
		return "";
	}

	return rest[:end_idx].trim();
}

struct CandidateHeader
{
	String path;
	int score;
	bool is_preferred;
}

const sz MAX_CANDIDATE_HEADERS = 16;

<*
 Scores how well a directory or file name matches an unresolved module query.
 Returns 0 if not a match, or a score >= 50 for candidate matches.
*>
fn int match_name_score(String query, String name)
{
	String q = query.to_lower_tcopy();
	String q_no_lib = q.starts_with("lib") && q.len > 3 ? q[3..] : q;
	String q_base = q.trim_right("0123456789.-_");

	String e = name.to_lower_tcopy().strip_suffix(".h");
	String e_no_lib = e.starts_with("lib") && e.len > 3 ? e[3..] : e;
	String e_base = e.trim_right("0123456789.-_");

	// 1. Exact match (e.g. alsa, zlib, sqlite3)
	if (e == q || e == string::tformat("lib%s", q) || e_no_lib == q_no_lib)
	{
		return 100;
	}

	// 2. Prefix with separator (e.g. wayland-client.h, gamemode_client.h)
	if (e.starts_with(string::tformat("%s-", q)) || e.starts_with(string::tformat("%s_", q)) ||
		e_no_lib.starts_with(string::tformat("%s-", q_no_lib)) || e_no_lib.starts_with(string::tformat("%s_", q_no_lib)))
	{
		return 80;
	}

	// 3. Base stem match without version digits (e.g. gtk-3.0 -> gtk, SDL3 -> sdl, ffmpeg4.4 -> ffmpeg)
	if (e_base == q || e_base == q_base || (e_base.len >= 3 && e_base == q_no_lib))
	{
		return 70;
	}

	// 4. Substring containment
	if (q.len >= 3 && (e.contains(q) || e_no_lib.contains(q_no_lib)))
	{
		return 50;
	}

	return 0;
}

<*
 Discovers candidate C headers matching module_name across workspace and system include paths.
 Top-level matching headers are collected before descending into library subdirectories.
*>
fn List{CandidateHeader} find_candidate_c_headers(LspProject* project, String module_name)
{
	List{CandidateHeader} results;
	results.tinit();

	if (module_name.len == 0) return results;

	HashSet{String} seen;
	seen.tinit();

	List{String} search_dirs;
	search_dirs.tinit();

	if (project && project.config.root_path.len > 0)
	{
		search_dirs.push(project.config.root_path);
		search_dirs.push(string::tformat("%s/include", project.config.root_path));
	}

	foreach (dir : SYSTEM_HEADER_DIRS)
	{
		search_dirs.push(dir);
	}

	String q_header = string::tformat("%s.h", module_name);

	// Phase 1: Top-level matching headers (e.g. wayland-client.h, sqlite3.h)
	foreach (search_dir : search_dirs)
	{
		if (results.len() >= MAX_CANDIDATE_HEADERS) break;
		if (!file::is_dir(search_dir)) continue;

		Path? dir_p = path::tnew(search_dir);
		if (catch dir_p) continue;

		// Exact match: <dir>/<module>.h
		String exact_path = string::tformat("%s/%s", search_dir, q_header);
		if (file::is_file(exact_path) && seen.add(exact_path))
		{
			results.push({ .path = exact_path, .score = 100, .is_preferred = true });
		}

		// Direct top-level header files matching module name/prefix
		if (try entries = path::ls(tmem, dir_p, no_dirs: true, mask: "*.h", recursive: false, rebase: dir_p))
		{
			foreach (entry : entries)
			{
				if (results.len() >= MAX_CANDIDATE_HEADERS) break;

				String entry_path = (String)entry;
				String entry_name = entry.basename();

				int score = match_name_score(module_name, entry_name);
				if (score >= 80 && file::is_file(entry_path) && seen.add(entry_path))
				{
					results.push({ .path = entry_path, .score = score, .is_preferred = (results.len() == 0) });
				}
			}
		}
	}

	// Phase 2: Matching library subdirectories (e.g. alsa/, SDL3/, curl/)
	foreach (search_dir : search_dirs)
	{
		if (results.len() >= MAX_CANDIDATE_HEADERS) break;
		if (!file::is_dir(search_dir)) continue;

		Path? dir_p = path::tnew(search_dir);
		if (catch dir_p) continue;

		if (try entries = path::ls(tmem, dir_p, no_dirs: false, mask: "", recursive: false, rebase: dir_p))
		{
			foreach (entry : entries)
			{
				if (results.len() >= MAX_CANDIDATE_HEADERS) break;

				String entry_path = (String)entry;
				if (!file::is_dir(entry_path)) continue;

				String entry_name = entry.basename();
				int score = match_name_score(module_name, entry_name);
				if (score == 0) continue;

				Path? sub_p = path::tnew(entry_path);
				if (catch sub_p) continue;

				// Exact header inside matching directory (<dir>/<mod>/<mod>.h)
				String sub_exact = string::tformat("%s/%s", entry_path, q_header);
				if (file::is_file(sub_exact) && seen.add(sub_exact))
				{
					results.push({ .path = sub_exact, .score = score + 5, .is_preferred = (results.len() == 0) });
				}

				// Headers inside matched directory
				if (try sub_files = path::ls(tmem, sub_p, no_dirs: true, mask: "*.h", recursive: true, rebase: sub_p))
				{
					foreach (sf : sub_files)
					{
						if (results.len() >= MAX_CANDIDATE_HEADERS) break;
						String sf_path = (String)sf;
						if (seen.add(sf_path))
						{
							results.push({ .path = sf_path, .score = score, .is_preferred = (results.len() == 0) });
						}
					}
				}
			}
		}
	}

	return results;
}

<*
 Generates CodeAction items (Quick Fixes) for the requested range and diagnostics.
 Suggests automatic C binding generation whenever a missing module import is detected.
 @param project : "Pointer to LspProject."
 @param uri     : "Source document URI."
 @param params  : "CodeActionParams received from client."
 @return        "Array of applicable CodeAction suggestions."
*>
fn CodeAction[]? get_code_actions(LspProject* project, Uri uri, CodeActionParams params)
{
	List{CodeAction} actions;
	actions.tinit();

	if (!project)
	{
		return actions.array_view();
	}

	String source_path = uri.path;

	foreach (diag : params.context.diagnostics)
	{
		String missing_mod = extract_missing_module_from_diagnostic(diag.message);
		if (missing_mod.len == 0)
		{
			continue;
		}

		List{CandidateHeader} candidates = find_candidate_c_headers(project, missing_mod);
		if (candidates.len() == 0)
		{
			continue;
		}

		String out_path = determine_output_binding_path(project, source_path, missing_mod);

		foreach (cand : candidates)
		{
			String[] cmd_args = alloc::alloc_array(tmem, String, 3);
			cmd_args[0] = cand.path;
			cmd_args[1] = missing_mod;
			cmd_args[2] = out_path;

			LspDiagnostic[] related_diags = alloc::alloc_array(tmem, LspDiagnostic, 1);
			related_diags[0] = diag;

			actions.push({
				.title = string::tformat("Generate C3 bindings for '%s' from %s", missing_mod, cand.path),
				.kind = "quickfix",
				.diagnostics = related_diags,
				.isPreferred = cand.is_preferred,
				.command = {
					.title = "Generate C3 bindings",
					.command = CMD_GENERATE_BINDINGS,
					.arguments = cmd_args
				}
			});
		}
	}

	return actions.array_view();
}