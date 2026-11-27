module lsp::core;

import std::io;
import std::collections::map;
import std::collections::list;
import std::collections::set;
import std::compression::zip;
import std::encoding::json;
import std::os::process;
import std::os::win32;
import libc;

import lsp::server, lsp::utils;
import analyzer::core::source_file;
import uri;

struct LspFile
{
	Uri uri;
	String text;
	int version;
	bool is_library;
}

fn void LspFile.free(&self, Allocator allocator)
{
	alloc::free(allocator, self.text.ptr);
	self.uri.free();
}

<*
 Replaces `text` with a copy of `new_text` allocated with `allocator`; an empty `new_text` clears it.
*>
fn void LspFile.set_text(&self, Allocator allocator, String new_text)
{
	String old = self.text;
	self.text = new_text.len > 0 ? new_text.copy(allocator) : {};
	alloc::free(allocator, old.ptr);
}

struct FileInput
{
	String path;
	String source_text;
	String uri;
	bool is_library;
}

struct SourceGroup
{
	String name;
	String[] patterns;
	bool is_loaded;
}

struct LspProject
{
	HashMap{String, LspFile*} files;
	List{FileInput} process_queue;
	LspWorkspace workspace;
	ProjectConfig config;
	Allocator allocator;
	List{SourceGroup} source_groups;
	bool is_initialized;
}

fn void LspProject.init(&self, Allocator allocator)
{
	self.allocator = allocator;
	self.files.init(allocator);
	self.process_queue.init(allocator);
	self.workspace.init(allocator);
	self.source_groups.init(allocator);
	self.is_initialized = false;
}

fn void LspProject.free(&self)
{
	self.workspace.free();
	self.files.@each(; uri, file)
	{
		file.free(self.allocator);
		alloc::free(self.allocator, file);
	};
	self.files.free();
	self.process_queue.free();
	self.config.free(self.allocator);
	self.source_groups.free();
}

<*
 Opens the file at `path` in the project, as `open_file` does for its uri.
*>
fn void LspProject.open_path(&self, String path, bool from_disk = true)
{
	self.open_file({ .uri = (DocumentUri)uri::from_file_path(tmem, path).to_raw_string(tmem) }, from_disk: from_disk);
}

<*
 Start tracking a document.
 @param from_disk : "true for a workspace scan, which carries no text and is read off disk; false for a didOpen, which carries the editor's buffer"
*>
fn void LspProject.open_file(&self, TextDocumentItem document, bool from_disk = false)
{
	String raw_uri = document.uri;

	log::debug("Registering document stream via raw tracking token: %s", raw_uri);

	Uri? file_uri = uri::parse(self.allocator, raw_uri);
	if (catch file_uri)
	{
		log::error("Malformed URI received (%s)", raw_uri);
		return;
	}

	String lookup_key = file_uri.path;
	log::warn("Opening file: %s", lookup_key);

	if (!from_disk)
	{
		self.ensure_matching_sources_loaded(lookup_key);
	}

	if (try LspFile* tracked = self.files.get(lookup_key))
	{
		defer file_uri.free();

		// The workspace scan reaches a project's own sources before the
		// editor announces them, so by the time didOpen arrives the file is
		// already tracked - against what is on disk. Dropping the
		// notification left that stale copy in place until the first edit,
		// which is why completion came back empty on a freshly opened file.
		// A second scan must not clobber the buffer, but a didOpen has to
		// win: its text is what the user is looking at.
		if (from_disk)
		{
			log::warn("File %s is already tracking in workspace", lookup_key);
			return;
		}

		tracked.set_text(self.allocator, document.text);
		tracked.version = document.version;
		tracked.is_library = false; // User opened this file in editor; publish diagnostics on edit!

		// lookup_key points into the Uri freed above; the tracked file owns
		// an identical path that outlives the queue.
		self.process_queue.push(
			{
				.path = tracked.uri.path,
				.source_text = tracked.text,
				.is_library = false,
			}
		);
		return;
	}

	LspFile* lsp_file = alloc::new(self.allocator, LspFile);
	*lsp_file = {
		.uri = file_uri,
		.version = document.version,
		.is_library = from_disk,
	};
	lsp_file.set_text(self.allocator, document.text);

	self.files[lookup_key] = lsp_file;

	FileInput file = {
		.source_text = lsp_file.text,
		.uri = lookup_key,
		.path = lookup_key,
		.is_library = from_disk,
	};

	self.process_queue.push(file);
}

fn void LspProject.change_file(&self, DidChangeParams params)
{
	String raw_uri = params.document.uri;
	log::debug("Registering document stream via raw tracking token: %s", raw_uri);

	Uri? file_uri = uri::parse(tmem, raw_uri);
	if (catch file_uri)
	{
		log::error("Malformed URI received (%s)", raw_uri);
		return;
	}

	String lookup_key = file_uri.path;

	LspFile*? file = self.files.get(lookup_key);
	if (catch file)
	{
		log::warn("File %s is not already tracking in workspace", lookup_key);
		return;
	}

	// Other projects' builds also report on the files they use, as on a stdlib file.
	self.workspace.clear_c3c_diagnostics_for_path(file.uri.path);
	server::project_manager.@each_project(; LspProject* p)
	{
		p.workspace.clear_c3c_diagnostics_for_path(file.uri.path);
	};

	if (params.document.version <= file.version) return;
	file.version = params.document.version;
	log::info("Reindexing: version = %d", file.version);

	String text = file.text;
	foreach (change : params.content_changes)
	{
		if (!change.range)
		{
			text = change.text;
			continue;
		}
		sz start = utils::compute_byte_offset(text, change.range.start.line, change.range.start.character);
		sz end = max(start, utils::compute_byte_offset(text, change.range.end.line, change.range.end.character));
		// Appended, not formatted with `%s`: the formatter copies a string one character at a time.
		DString edited;
		edited.tinit(text.len - (end - start) + change.text.len);
		edited.append(text[:start]);
		edited.append(change.text);
		edited.append(text[end..]);
		text = edited.str_view();
	}
	file.set_text(self.allocator, text);
	FileInput input = {
		.source_text = file.text,
		.uri = file.uri.path,
		.path = file.uri.path,
		.is_library = file.is_library,
	};
	self.process_queue.push(input);
}

<*
 Key of `document` in `files`: the path of a uri, or `document` itself when it is already a path.
*>
fn String? file_key(DocumentUri document) @local
{
	String raw = document;
	if (!raw.contains("://")) return raw;
	return uri::parse(tmem, raw).path;
}

fn void LspProject.close_document(&self, DocumentUri document)
{
	String? lookup_key = file_key(document);
	if (catch lookup_key) return;

	LspFile*? file = self.files.get(lookup_key);
	if (catch file) return;

	if (file::exists(lookup_key) && !lookup_key.starts_with("/virtual/"))
	{
		file.set_text(self.allocator, "");
		file.is_library = true;

		FileInput input = {
			.source_text = "",
			.uri = file.uri.path,
			.path = file.uri.path,
			.is_library = true,
		};
		self.process_queue.push(input);
		return;
	}

	self.close_file(document);
}

<*
 Whether `path` is the directory `dir` or inside it.
*>
fn bool is_in_dir(String path, String dir)
{
	if (!path.starts_with(dir)) return false;
	if (path.len == dir.len || dir.ends_with("/") || dir.ends_with("\\")) return true;
	return path[dir.len] == '/' || path[dir.len] == '\\';
}

fn void LspProject.close_file(&self, DocumentUri document)
{
	String? lookup_key = file_key(document);
	if (catch lookup_key) return;

	log::debug("Deregistering file: %s", lookup_key);

	if (!self.files.has_key(lookup_key))
	{
		// Check if a directory path was passed (e.g. `rm -rf lib`)
		List{String} to_evict;
		to_evict.tinit();

		self.files.@each(; f_path, f)
		{
			if (is_in_dir(f_path, lookup_key))
			{
				to_evict.push(f_path);
			}
		};

		foreach (p : to_evict) self.evict(p);
		return;
	}

	self.evict(lookup_key);
}

<*
 Stops tracking the file at `path`: drops its c3c diagnostics and parsed source, and frees it.
*>
fn void LspProject.evict(&self, String path)
{
	LspFile*? file = self.files.get(path);
	if (catch file) return;
	self.workspace.clear_c3c_diagnostics_for_path(file.uri.path);
	self.workspace.clear_diagnostics_for_path(path);
	// Clears the file's errors in the editor.
	server::publish_diagnostics_for_path(file.uri.path, &self.workspace);
	if (try sf = self.workspace.get_source_file_by_path(path)) source_file::free(self.workspace.ctx, sf);
	file.free(self.allocator);
	alloc::free(self.allocator, file);
	(void)self.files.remove(path);
}

fn void LspProject.save_file(&self, DocumentUri document) => @pool()
{
	String? lookup_key = file_key(document);
	if (catch lookup_key) return;

	LspFile*? file = self.files.get(lookup_key);
	if (catch file) return;
	if (file.is_library) return;

	if (self.process_queue.len() > 0)
	{
		self.update();
	}

	if (lookup_key.starts_with("/virtual/")) return;

	if (@ok(self.workspace.get_source_file_by_path(lookup_key)))
	{
		if (try diags = self.workspace.diagnostics.get_ref(lookup_key))
		{
			foreach (d : *diags)
			{
				if (d.severity == 1) return;
			}
		}
	}

	List{LspProject*} runs;
	runs.tinit();
	runs.push(self);
	// Each project's build also checks the stdlib's generic modules, which c3c checks only where used.
	if (server::is_stdlib_file(lookup_key))
	{
		server::project_manager.@each_project(; LspProject* p)
		{
			if (p != self && p.config.root_path.len > 0) runs.push(p);
		};
	}

	// Files with c3c diagnostics before or after the runs; published once each.
	List{String} paths;
	paths.tinit();
	HashSet{String} seen;
	seen.tinit();
	if (seen.add(lookup_key)) paths.push(lookup_key);
	foreach (p : runs)
	{
		p.workspace.c3c_diagnostics.@each(; path, list)
		{
			String copy = path.copy(tmem);
			if (seen.add(copy)) paths.push(copy);
		};
		p.run_c3c_diagnostics(lookup_key);
		p.workspace.c3c_diagnostics.@each(; path, list)
		{
			String copy = path.copy(tmem);
			if (seen.add(copy)) paths.push(copy);
		};
	}
	foreach (path : paths) server::publish_diagnostics_for_path(path, &self.workspace);
}

<*
 Queues every open user file to be analyzed again, as after a change that can affect them all.
*>
fn void LspProject.requeue_user_files(&self)
{
	self.files.@each(; path, file)
	{
		if (file && !file.is_library) self.process_queue.push({ .source_text = file.text, .uri = file.uri.path, .path = file.uri.path });
	};
}

fn bool LspProject.is_test_source_file(&self, String file_path)
{
	if (self.file_matches_patterns(file_path, self.config.test_sources)) return true;

	if (self.config.targets.is_initialized())
	{
		self.config.targets.@each(; target_name, target_conf)
		{
			if (self.file_matches_patterns(file_path, target_conf.own_test_sources())) return true;
		};
	}

	return file_path.contains("/test/") || file_path.contains("\\test\\");
}

<*
 Whether the project's c3c build compiles `file_path`: one of its sources or test sources,
 a library on its dependency search paths, or the stdlib.
*>
fn bool LspProject.builds_file(&self, String file_path)
{
	switch
	{
		case server::is_stdlib_file(file_path):
		case self.is_test_source_file(file_path):
		case self.file_matches_patterns(file_path, self.config.sources):
		case self.file_matches_patterns(file_path, self.all_dependency_search_paths()):
			return true;
	}
	if (self.config.targets.is_initialized())
	{
		self.config.targets.@each(; target_name, target_conf)
		{
			if (self.file_matches_patterns(file_path, target_conf.own_sources())) return true;
		};
	}
	return false;
}

fn String LspProject.get_c3c_target(&self, String file_path)
{
	if (self.config.targets.is_initialized())
	{
		self.config.targets.@each(; target_name, target_conf)
		{
			if (array::contains(target_conf.own_features(), "LSP_TARGET")) return target_name;
		};

		self.config.targets.@each(; target_name, target_conf)
		{
			if (self.file_matches_patterns(file_path, target_conf.own_sources())) return target_name;
			if (self.file_matches_patterns(file_path, target_conf.own_test_sources())) return target_name;
		};
	}

	return "";
}

<*
 Output of `cmd`, stderr included, read while it runs so a full pipe cannot block it.
*>
fn String? capture_output(String[] cmd, bool close_stdin) @local
{
	Process proc = process::spawn(cmd, options: STDERR_TO_STDOUT | INHERIT_ENV)!;
	defer (void)proc.destroy();
	if (close_stdin) proc.close_stdin();

	DString output;
	output.tinit();
	char[4096] chunk;
	while (try n = proc.read_stdout(&chunk, chunk.len))
	{
		if (n <= 0) break;
		output.append((String)chunk[:n]);
	}
	(void)proc.join();
	return output.str_view();
}

ulong lsp2_checked_compiler @local;
bool lsp2_supported @local;

<*
 Whether `compiler` gives each error's span length with `--lsp2`, checked once per compiler.
*>
fn bool has_lsp2(String compiler) @local => @pool()
{
	ulong id = compiler.hash();
	if (id != lsp2_checked_compiler)
	{
		lsp2_supported = capture_output({ compiler, "--help" }, false).contains("--lsp2") ?? false;
		lsp2_checked_compiler = id;
	}
	return lsp2_supported;
}

<*
 Closes the child's stdin, so it reads end of input, as `join` does before waiting.
*>
fn void Process.close_stdin(&self)
{
	if (self.stdin_file)
	{
		libc::fclose(self.stdin_file);
		self.stdin_file = null;
	}
	$if env::WIN32:
		if (self.hStdInput)
		{
			win32::closeHandle(self.hStdInput);
			self.hStdInput = null;
		}
	$endif
}

<*
 Runs c3c on what `user_file_path` belongs to and keeps its diagnostics: the project's build,
 the whole stdlib for a stdlib file, or the file alone outside a project.
*>
fn void LspProject.run_c3c_diagnostics(&self, String user_file_path) => @pool()
{
	if (user_file_path.len == 0) return;

	List{String} cmd;
	cmd.tinit();

	String comp = server::compiler_path.len > 0 ? server::compiler_path : "c3c";
	cmd.push(comp);

	// Without a project, c3c checks the whole stdlib even for empty source, read here from the closed stdin.
	bool stdlib_only = self.config.root_path.len == 0 && server::is_stdlib_file(user_file_path);
	switch
	{
		case stdlib_only:
			cmd.push_all({ "compile", "-C", "-" });
		case self.config.root_path.len == 0:
		case !self.builds_file(user_file_path):
			cmd.push_all({ "compile", "-C", user_file_path });
		default:
			cmd.push_all({ "--path", self.config.root_path });

			bool is_test = self.is_test_source_file(user_file_path);
			cmd.push(is_test ? "test" : "build");

			String target = self.get_c3c_target(user_file_path);
			if (target.len > 0)
			{
				cmd.push(target);
			}
	}

	cmd.push(has_lsp2(comp) ? "--lsp2" : "--lsp");
	cmd.push("--warn-builtin=no");
	if (self.config.root_path.len)
	{
		String trust = cache::trust_level(self.config.root_path);
		if (trust.len) cmd.push(string::tformat("--trust=%s", trust));
	}

	// A c3c that does not start leaves no diagnostics, clearing the previous ones.
	self.workspace.parse_c3c_lsp_output(capture_output(cmd.array_view(), stdlib_only) ?? "", self.config.root_path);
}

fn void LspProject.update(&self)
{
	List{String} dead_libs;
	dead_libs.tinit();

	self.files.@each(; p, lf)
	{
		if (lf && lf.is_library && !lf.uri.path.starts_with("/virtual/") && !file::exists(lf.uri.path))
		{
			dead_libs.push(p);
		}
	};

	if (dead_libs.len() > 0)
	{
		foreach (dead_p : dead_libs)
		{
			self.close_file((DocumentUri)dead_p);
		}

		self.requeue_user_files();
	}

	if (self.process_queue.is_empty()) return;

	// A file queued several times, as by edits waiting to be analyzed, is processed once with its latest entry.
	List{FileInput} latest;
	latest.tinit();
	HashSet{String} queued;
	queued.tinit();
	foreach_r (f : self.process_queue)
	{
		if (queued.add(f.path.len > 0 ? f.path : f.uri)) latest.push(f);
	}
	latest.reverse();
	FileInput[] files = latest.array_view();
	defer self.process_queue.clear();

	// Pass 1: Parse and register all AST nodes across queued files into global workspace registry
	foreach (f : files)
	{
		String text = f.source_text;
		if (text.len == 0 && f.path.len > 0)
		{
			if (try loaded = (String)file::load(tmem, f.path))
			{
				text = loaded;
			}
		}
		if (text.len > 0)
		{
			String target_path = f.path.len > 0 ? f.path : f.uri;
			self.workspace.parse_and_register_file(target_path, text);
			// `@feat` sees the project's features, those of the target built for this file, and TESTING in test files.
			if (try sf = self.workspace.get_source_file_by_path(target_path))
			{
				List{String} features;
				features.init(&sf.arena);
				features.push_all(self.config.features);
				String target = self.get_c3c_target(target_path);
				if (target.len) features.push_all(self.config.targets[target]!!.own_features());
				if (self.is_test_source_file(target_path)) features.push("TESTING");
				sf.features = features.array_view();
			}
		}
	}

	// Pass 2: Execute semantic analysis only on user files
	foreach (f : files)
	{
		if (f.is_library) continue;
		String target_path = f.path.len > 0 ? f.path : f.uri;
		self.workspace.analyze_file(target_path);
	}

	HashSet{String} published_paths;
	published_paths.tinit();

	foreach (f : files)
	{
		if (f.is_library) continue;
		String p = f.path.len > 0 ? f.path : f.uri;
		if (published_paths.add(p))
		{
			server::publish_diagnostics_for_path(p, &self.workspace);
		}
	}
}

fn void LspProject.initial_process(&self)
{
	if (self.is_initialized) return;
	self.process_stdlib();
	self.process_config();
	self.process_libs();
	self.update();
	self.is_initialized = true;
}

fn void LspProject.process_stdlib(&self)
{
	if (server::std_path.len == 0) return;
	Path? base_path = path::tnew(server::std_path);
	if (catch err = base_path)
	{
		log::error("Invalid stdlib path %s", err);
		return;
	}
	String[] paths = utils::find_source_files(tmem, base_path);
	foreach (matched : paths)
	{
		self.open_path(matched);
	}
}

fn void LspProject.add_source_group(&self, String name, String[] patterns) @inline
{
	self.source_groups.push({ .name = name, .patterns = patterns, .is_loaded = false });
}

fn void LspProject.setup_source_groups(&self)
{
	self.source_groups.clear();

	if (self.config.sources.len > 0)
	{
		self.add_source_group("sources", self.config.sources);
	}

	if (self.config.test_sources.len > 0)
	{
		self.add_source_group("test-sources", self.config.test_sources);
	}

	if (self.config.targets.is_initialized())
	{
		self.config.targets.@each(; target_name, target_conf)
		{
			if (target_conf.own_sources().len > 0) self.add_source_group(target_name, target_conf.own_sources());
			if (target_conf.own_test_sources().len > 0) self.add_source_group(target_name, target_conf.own_test_sources());
		};
	}
}

fn bool LspProject.file_matches_patterns(&self, String file_path, String[] patterns)
{
	if (self.config.root_path.len == 0 || file_path.len == 0) return false;

	Path? norm_file = path::tnew(file_path);
	if (catch norm_file) return false;

	Path? base_path = path::tnew(self.config.root_path);
	if (catch base_path) return false;

	foreach (source_entry : patterns)
	{
		String entry_str = source_entry;
		if (entry_str.ends_with("/**"))
		{
			entry_str = entry_str.strip_suffix("/**");
		}
		else if (entry_str.ends_with("/*"))
		{
			entry_str = entry_str.strip_suffix("/*");
		}

		Path? entry_path = base_path.tappend(entry_str);
		if (catch entry_path) continue;

		$if env::WIN32:
			String f_str = ((String)norm_file).to_lower_tcopy();
			String e_str = ((String)entry_path).to_lower_tcopy();
		$else
			String f_str = (String)norm_file;
			String e_str = (String)entry_path;
		$endif

		String prefix = string::tformat("%s%c", e_str, (char)path::PREFERRED_SEPARATOR);
		if (f_str == e_str || f_str.starts_with(prefix))
		{
			return true;
		}
	}
	return false;
}

fn void LspProject.load_source_group(&self, SourceGroup* group, bool from_disk = true)
{
	if (group.is_loaded) return;
	group.is_loaded = true;

	if (self.config.root_path.len == 0) return;
	Path? base_path = path::tnew(self.config.root_path);
	if (catch err = base_path)
	{
		log::error("Config base path is not valid: %s", err);
		return;
	}

	foreach (source_entry : group.patterns)
	{
		String entry_str = source_entry;
		bool recursive = false;

		if (entry_str.ends_with("/**"))
		{
			entry_str = entry_str.strip_suffix("/**");
			recursive = true;
		}
		else if (entry_str.ends_with("/*"))
		{
			entry_str = entry_str.strip_suffix("/*");
			recursive = false;
		}

		Path? entry_path = base_path.tappend(entry_str);
		if (catch err = entry_path)
		{
			log::error("'%s' is not a valid directory layout: %s", entry_str, err);
			continue;
		}

		if (path::is_file(entry_path))
		{
			log::info("Found source file in group '%s': %s", group.name, (String)entry_path);
			self.open_path((String)entry_path, from_disk);
			continue;
		}

		PathList? paths = path::ls(tmem, entry_path, no_dirs: true, recursive: recursive, rebase: entry_path);
		if (catch paths) continue;

		foreach (matched : paths)
		{
			if (!matched.has_extension("c3") && !matched.has_extension("c3i")) continue;
			log::info("Found source file in group '%s': %s", group.name, matched);
			self.open_path(matched, from_disk);
		}
	}
}

fn void LspProject.ensure_matching_sources_loaded(&self, String file_path)
{
	if (self.config.root_path.len == 0) return;
	if (self.source_groups.is_empty())
	{
		self.setup_source_groups();
	}

	for (sz i = 0; i < self.source_groups.len(); i++)
	{
		SourceGroup* group = self.source_groups.get_ref(i);
		if (group.is_loaded) continue;

		if (self.file_matches_patterns(file_path, group.patterns))
		{
			self.load_source_group(group, from_disk: true);
		}
	}
}

fn void LspProject.process_config(&self)
{
	if (self.source_groups.is_empty())
	{
		self.setup_source_groups();
	}

	for (sz i = 0; i < self.source_groups.len(); i++)
	{
		SourceGroup* group = self.source_groups.get_ref(i);
		if (group.name == "sources")
		{
			self.load_source_group(group, from_disk: false);
			break;
		}
	}
}

<*
 Dependencies of the project and of every target, since any target may be the one being built.
*>
fn String[] LspProject.all_dependencies(&self)
{
	List{String} out;
	out.tinit();
	push_unique_all(&out, self.config.dependencies);
	if (self.config.targets.is_initialized())
	{
		self.config.targets.@each(; target_name, target_conf)
		{
			push_unique_all(&out, target_conf.dependencies_override);
			push_unique_all(&out, target_conf.dependencies);
		};
	}
	return out.array_view();
}

<*
 Library search paths of the project and of every target.
*>
fn String[] LspProject.all_dependency_search_paths(&self)
{
	List{String} out;
	out.tinit();
	push_unique_all(&out, self.config.dependency_search_paths.len > 0 ? self.config.dependency_search_paths : (String[]){ "lib" });
	if (self.config.targets.is_initialized())
	{
		self.config.targets.@each(; target_name, target_conf)
		{
			push_unique_all(&out, target_conf.dependency_search_paths_override);
			push_unique_all(&out, target_conf.dependency_search_paths);
		};
	}
	return out.array_view();
}

fn void push_unique_all(List{String}* list, String[] values) @local
{
	foreach (value : values)
	{
		if (!list.contains(value)) list.push(value);
	}
}

fn void LspProject.process_libs(&self)
{
	if (self.config.root_path.len == 0) return;

	Path? base_path = path::tnew(self.config.root_path);
	if (catch base_path)
	{
		log::error("Config base path is not valid for parsing libraries.");
		return;
	}

	String[] deps         = self.all_dependencies();
	String[] search_paths = self.all_dependency_search_paths();

	foreach (search_entry : search_paths)
	{
		if (search_entry.ends_with("\\")) search_entry = search_entry.strip_suffix("\\");
		if (!search_entry.ends_with("/")) search_entry = string::tformat("%s/", search_entry);

		Path? search_base = base_path.tappend(search_entry);
		if (catch search_base) continue;

		String[]? libs = libs_installed(search_base);
		if (catch libs) continue;

		foreach (lib : libs)
		{
			ManifestConfig? config = load_manifest(lib);
			if (catch config)
			{
				log::warn("Lib without manifest.json (%s)", lib);
				continue;
			}
			String lib_provides = config.provides;
			foreach (dep_name : deps)
			{
				if (dep_name != lib_provides) continue;

				Path lib_path = (Path)lib;
				Path scan_target   = lib_path;
				bool is_compressed = path::is_file(lib_path);

				if (is_compressed)
				{
					if (lib_path.has_extension("c3i"))
					{
						log::debug("Found a declaration file (.c3i) at: %s", lib_path);
						self.open_path(lib_path);
					}
					else
					{
						log::debug("Found a compressed library archive (.c3l file) at: %s", lib_path);

						Path? cache_root = cache::get_or_create_cache_dir(self.config.root_path);
						if (catch cache_root) continue;
						Path? cache_target_dir = cache_root.tappend(dep_name);
						if (catch cache_target_dir) continue;
						bool outdated = cache::is_library_outdated(dep_name, cache_root, lib_path) ?? true;
						if (outdated)
						{
							log::info("Cache is stale or missing for %s. Extracting...", dep_name);

							if (path::exists(cache_target_dir)) (void)path::rmtree(cache_target_dir);
							if (catch err = path::mkdir(cache_target_dir, recursive: true))
							{
								log::error("Failed to create cache_target dir: %s", err);
								continue;
							}

							if (decompress_library(lib_path, cache_target_dir))
							{
								if (catch err = cache::update_library_meta(dep_name, cache_root, lib_path))
								{
									log::error("Failed to update meta file: %s", err);
								}
							}
						}
						else
						{
							log::info("Cache hit for library %s. No offline modifications detected.", dep_name);
						}

						scan_target = cache_target_dir;
					}
				}
				else
				{
					log::info("Found an uncompressed library folder (.c3l folder) at: %s", lib_path);
				}

				String[] paths = utils::find_source_files(tmem, scan_target);
				foreach (matched : paths)
				{
					log::info("Found internal library source: %s", matched);
					self.open_path(matched);
				}

				break;
			}
		}
	}
}

<*
 Extracts a zipped library archive to a target cache directory.
 @param source_archive : `Path to the .c3l / .zip file (e.g., "libs/glfw.c3l")`
 @param cache_target_dir : `Path to the destination directory (e.g., ".lsp-cache/glfw")`
*>
fn bool decompress_library(String source_archive, Path cache_target_dir)
{
	log::info("Extracting archive %s to %s", source_archive, cache_target_dir);

	ZipArchive? archive = zip::open(tmem, source_archive, "r");
	if (catch archive)
	{
		log::error("Failed to open zip archive: %s", source_archive);
		return false;
	}
	defer (void)archive.close();

	if (catch err = archive.extract(cache_target_dir))
	{
		log::error("Extraction failed for %s: %s", source_archive, err);
		return false;
	}

	return true;
}

// Returns paths to all .c3l entries (files or folders) inside a search dir.
fn String[]? libs_installed(String dir) @local
{
	if (!file::is_dir(dir)) return {};

	PathList entries = path::ls(tmem, path::tnew(dir)!)!;

	List{String} paths;
	paths.tinit();

	foreach (entry : entries)
	{
		if (!entry.has_extension("c3l")) continue;
		paths.push(string::tformat("%s/%s", dir, entry));
	}

	return paths.to_tarray();
}

<*
 Reads the manifest of an installed lib. Handles both the directory layout and
 the zipped `.c3l` archive layout that c3c accepts.
*>
fn ManifestConfig? load_manifest(String lib_path) @private
{
	String data;

	if (file::is_dir(lib_path))
	{
		data = (String)file::load_temp(string::tformat("%s/%s", lib_path, config::MANIFEST_CONFIG_NAME))!;
	}
	else
	{
		ZipArchive archive = zip::open(tmem, lib_path)!;
		defer (void)archive.close();
		data = (String)archive.read_file_all(tmem, config::MANIFEST_CONFIG_NAME)!;
	}

	return json::unmarshal(tmem, data, ManifestConfig)!;
}