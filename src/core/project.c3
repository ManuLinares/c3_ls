module lsp::core;

import std::io;
import std::collections::map;
import std::collections::list;
import std::collections::set;
import std::collections::object;
import std::compression::zip;
import std::encoding::json;
import std::io::file;
import std::os::process;

import lsp::analysis;
import lsp::server;
import lsp::core::config;
import analyzer::core;
import analyzer::core::source_file;
import uri;
import lsp::utils;

struct LspFile
{
	Uri uri;
	String text;
	int version;
	bool is_library;
}

fn void LspFile.free(&self, Allocator allocator)
{
	if (self.text.len > 0)
	{
		self.text.free(allocator);
	}
	self.uri.free();
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
	HashMap{String, ManifestConfig} manifests;
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
	self.manifests.@each(; name, conf)
	{
		conf.free(self.allocator);
	};
	self.manifests.free();
	self.source_groups.free();
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
	if (catch err = file_uri)
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

		if (tracked.text.len > 0) tracked.text.free(self.allocator);
		tracked.text = document.text.len > 0 ? document.text.copy(self.allocator) : "";
		tracked.version = 1;
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
		.text = document.text.len > 0 ? document.text.copy(self.allocator) : "",
		.version = 1,
		.is_library = from_disk,
	};

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

	if (!self.files.has_key(lookup_key))
	{
		log::warn("File %s is not already tracking in workspace", lookup_key);
		return;
	}

	LspFile* file = self.files.get(lookup_key) ?? null;
	if (!file) return;

	self.workspace.clear_c3c_diagnostics_for_path(file.uri.path);

	if (params.document.version <= file.version) return;
	file.version = params.document.version;
	log::info("Reindexing: version = %d", file.version);

	if (file.text.len > 0)
	{
		file.text.free(self.allocator);
		file.text = "";
	}
	if (params.content_changes.len > 0 && params.content_changes[0].text.len > 0)
	{
		file.text = params.content_changes[0].text.copy(self.allocator);
	}
	FileInput input = {
		.source_text = file.text,
		.uri = file.uri.path,
		.path = file.uri.path,
		.is_library = file.is_library,
	};
	self.process_queue.push(input);
}

fn void LspProject.close_document(&self, DocumentUri document)
{
	String raw_uri = document;
	String lookup_key = raw_uri;
	if (raw_uri.contains("://"))
	{
		Uri? query_uri = uri::parse(tmem, raw_uri);
		if (catch query_uri) return;
		lookup_key = query_uri.path;
	}

	LspFile* file = self.files.get(lookup_key) ?? null;
	if (!file) return;

	if (file::exists(lookup_key) && !lookup_key.starts_with("/virtual/"))
	{
		if (file.text.len > 0)
		{
			file.text.free(self.allocator);
			file.text = "";
		}
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

fn void LspProject.close_file(&self, DocumentUri document)
{
	String raw_uri = document;
	String lookup_key = raw_uri;
	if (raw_uri.contains("://"))
	{
		Uri? query_uri = uri::parse(tmem, raw_uri);
		if (catch query_uri) return;
		lookup_key = query_uri.path;
	}

	log::debug("Deregistering file: %s", lookup_key);

	if (!self.files.has_key(lookup_key))
	{
		// Check if a directory path was passed (e.g. `rm -rf lib`)
		List{String} to_evict;
		to_evict.tinit();

		self.files.@each(; f_path, f)
		{
			if (f_path.starts_with(lookup_key))
			{
				to_evict.push(f_path);
			}
		};

		foreach (p : to_evict)
		{
			if (try f = self.files.get(p))
			{
				if (self.workspace.ctx)
				{
					SourceFile* sf = self.workspace.get_source_file_by_path(p);
					if (sf)
					{
						source_file::free(self.workspace.ctx, sf);
					}
				}
				f.free(self.allocator);
				alloc::free(self.allocator, f);
				(void)self.files.remove(p);
			}
		}
		return;
	}

	LspFile* file = self.files.get(lookup_key) ?? null;
	if (!file) return;

	self.workspace.clear_c3c_diagnostics_for_path(file.uri.path);

	if (self.workspace.ctx)
	{
		SourceFile* sf = self.workspace.get_source_file_by_path(lookup_key);
		if (sf)
		{
			source_file::free(self.workspace.ctx, sf);
		}
	}

	file.free(self.allocator);
	alloc::free(self.allocator, file);
	self.files.remove(lookup_key);
}

fn void LspProject.save_file(&self, DocumentUri document) => @pool()
{
	String raw_uri = document;
	String lookup_key = raw_uri;
	if (raw_uri.contains("://"))
	{
		Uri? query_uri = uri::parse(tmem, raw_uri);
		if (catch query_uri) return;
		lookup_key = query_uri.path;
	}

	LspFile* file = self.files.get(lookup_key) ?? null;
	if (!file || file.is_library) return;

	if (self.process_queue.len() > 0)
	{
		self.update();
	}

	if (self.config.root_path.len == 0 || lookup_key.starts_with("/virtual/")) return;

	SourceFile* sf = self.workspace.get_source_file_by_path(lookup_key);
	if (sf)
	{
		if (try diags = self.workspace.diagnostics.get_ref(lookup_key))
		{
			foreach (d : *diags)
			{
				if (d.severity == 1) return;
			}
		}
	}

	List{String} prev_c3c_files;
	prev_c3c_files.tinit();
	self.workspace.c3c_diagnostics.@each(; path, list)
	{
		prev_c3c_files.push(path.copy(tmem));
	};

	self.run_c3c_diagnostics(lookup_key);

	HashSet{String} published_paths;
	published_paths.tinit();

	if (published_paths.add(lookup_key))
	{
		server::publish_diagnostics_for_path(lookup_key, &self.workspace);
	}

	foreach (p : prev_c3c_files)
	{
		if (published_paths.add(p))
		{
			server::publish_diagnostics_for_path(p, &self.workspace);
		}
	}

	self.workspace.c3c_diagnostics.@each(; path, list)
	{
		if (published_paths.add(path))
		{
			server::publish_diagnostics_for_path(path, &self.workspace);
		}
	};
}

fn bool LspProject.is_test_source_file(&self, String file_path)
{
	if (try test_srcs = self.config.test_sources.get())
	{
		if (self.file_matches_patterns(file_path, test_srcs)) return true;
	}

	if (self.config.targets.is_initialized())
	{
		self.config.targets.@each(; target_name, target_conf)
		{
			if (try test_srcs = target_conf.test_sources_override.get())
			{
				if (self.file_matches_patterns(file_path, test_srcs)) return true;
			}
			else if (try test_srcs = target_conf.test_sources.get())
			{
				if (self.file_matches_patterns(file_path, test_srcs)) return true;
			}
		};
	}

	return file_path.contains("/test/") || file_path.contains("\\test\\");
}

fn String LspProject.get_c3c_target(&self, String file_path)
{
	if (self.config.targets.is_initialized())
	{
		self.config.targets.@each(; target_name, target_conf)
		{
			if (try feats = target_conf.features_override.get())
			{
				foreach (f : feats)
				{
					if (f == "LSP_TARGET") return target_name;
				}
			}
			else if (try feats = target_conf.features.get())
			{
				foreach (f : feats)
				{
					if (f == "LSP_TARGET") return target_name;
				}
			}
		};

		self.config.targets.@each(; target_name, target_conf)
		{
			if (try srcs = target_conf.sources_override.get())
			{
				if (self.file_matches_patterns(file_path, srcs)) return target_name;
			}
			else if (try srcs = target_conf.sources.get())
			{
				if (self.file_matches_patterns(file_path, srcs)) return target_name;
			}
			if (try test_srcs = target_conf.test_sources_override.get())
			{
				if (self.file_matches_patterns(file_path, test_srcs)) return target_name;
			}
			else if (try test_srcs = target_conf.test_sources.get())
			{
				if (self.file_matches_patterns(file_path, test_srcs)) return target_name;
			}
		};
	}

	return "";
}

fn void LspProject.run_c3c_diagnostics(&self, String user_file_path) => @pool()
{
	if (self.config.root_path.len == 0 || user_file_path.len == 0) return;

	List{String} cmd;
	cmd.tinit();

	String comp = server::compiler_path.len > 0 ? server::compiler_path : "c3c";
	cmd.push(comp);

	if (self.config.root_path.len > 0)
	{
		cmd.push("--path");
		cmd.push(self.config.root_path);
	}

	bool is_test = self.is_test_source_file(user_file_path);
	cmd.push(is_test ? "test" : "build");

	String target = self.get_c3c_target(user_file_path);
	if (target.len > 0)
	{
		cmd.push(target);
	}

	cmd.push("--lsp");
	cmd.push("--warn-builtin=no");

	Process? proc = process::spawn(cmd.array_view(), options: STDERR_TO_STDOUT);
	if (catch proc) return;

	DString output_buf;
	output_buf.tinit();

	char[4096] chunk;
	while (true)
	{
		long? bytes_read = proc.read_stdout(&chunk, 4096);
		if (catch bytes_read) break;
		long n = bytes_read;
		if (n <= 0) break;
		output_buf.append((String)chunk[:n]);
	}

	(void)proc.join();

	self.workspace.parse_c3c_lsp_output(output_buf.str_view(), self.config.root_path);
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

		self.files.@each(; path_key, lsp_f)
		{
			if (lsp_f && !lsp_f.is_library)
			{
				self.process_queue.push({
					.source_text = lsp_f.text,
					.uri = lsp_f.uri.path,
					.path = lsp_f.uri.path,
					.is_library = false
				});
			}
		};
	}

	if (self.process_queue.is_empty()) return;

	FileInput[] files = self.process_queue.array_view();
	defer self.process_queue.clear();

	bool any_syntax_error = false;
	String user_file_for_c3c = "";

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
			bool ok = self.workspace.parse_and_register_file(target_path, text);
			if (!f.is_library)
			{
				user_file_for_c3c = target_path;
				if (!ok)
				{
					any_syntax_error = true;
				}
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
		Uri file_uri = uri::from_file_path(tmem, matched);
		DocumentUri uri = (DocumentUri)file_uri.to_raw_string(tmem);
		self.open_file({ .uri = uri }, from_disk: true);
	}
}

fn void LspProject.add_source_group(&self, String name, String[] patterns) @inline
{
	self.source_groups.push({ .name = name, .patterns = patterns, .is_loaded = false });
}

macro void LspProject.add_group_if_present(&self, name, maybe_override, maybe_default)
{
	if (try p = maybe_override.get())
	{
		self.add_source_group(name, p);
	}
	else if (try p = maybe_default.get())
	{
		self.add_source_group(name, p);
	}
}

fn void LspProject.setup_source_groups(&self)
{
	self.source_groups.clear();

	if (self.config.sources.len > 0)
	{
		self.add_source_group("sources", self.config.sources);
	}

	if (try test_srcs = self.config.test_sources.get())
	{
		self.add_source_group("test-sources", test_srcs);
	}

	if (self.config.targets.is_initialized())
	{
		self.config.targets.@each(; target_name, target_conf)
		{
			self.add_group_if_present(target_name, target_conf.sources_override, target_conf.sources);
			self.add_group_if_present(target_name, target_conf.test_sources_override, target_conf.test_sources);
		};
	}
}

fn bool LspProject.file_matches_patterns(&self, String file_path, String[] patterns)
{
	if (self.config.root_path.len == 0) return false;
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

		if (file_path.starts_with((String)entry_path))
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
			Uri file_uri = uri::from_file_path(tmem, (String)entry_path);
			DocumentUri uri = (DocumentUri)file_uri.to_raw_string(tmem);
			self.open_file({ .uri = uri }, from_disk: from_disk);
			continue;
		}

		String[2] masks = { "*.c3", "*.c3i" };
		foreach (mask : masks)
		{
			PathList paths;
			if (catch err = @try(paths, path::ls(tmem, entry_path, no_dirs: true, mask: mask, recursive: recursive, rebase: entry_path)))
			{
				continue;
			}

			foreach (matched : paths)
			{
				log::info("Found source file in group '%s': %s", group.name, matched);
				Uri file_uri = uri::from_file_path(tmem, matched);
				DocumentUri uri = (DocumentUri)file_uri.to_raw_string(tmem);
				self.open_file({ .uri = uri }, from_disk: from_disk);
			}
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

fn void LspProject.process_libs(&self)
{
	if (self.config.root_path.len == 0) return;

	Path? base_path = path::tnew(self.config.root_path);
	if (catch base_path)
	{
		log::error("Config base path is not valid for parsing libraries.");
		return;
	}

	String[] deps         = self.config.dependencies.get() ?? {};
	String[] search_paths = self.config.dependency_search_paths.get() ?? (String[]){ "lib" };

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
						Uri file_uri = uri::from_file_path(tmem, lib_path);
						self.open_file({ .uri = (DocumentUri)file_uri.to_raw_string(tmem) }, from_disk: true);
					}
					else
					{
						log::debug("Found a compressed library archive (.c3l file) at: %s", lib_path);

						Path? cache_root = cache::get_or_create_cache_dir(self.config.root_path);
						if (catch cache_root) continue;
						Path? cache_target_dir = cache_root.tappend(dep_name);
						if (catch cache_target_dir) continue;
						bool outdated = cache::is_library_outdated(dep_name, cache_target_dir, lib_path) ?? true;
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
					Uri file_uri = uri::from_file_path(tmem, matched);
					self.open_file({ .uri = (DocumentUri)file_uri.to_raw_string(tmem) }, from_disk: true);
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

	Object* dom = json::tparse(data)!;
	ManifestConfig conf;
	conf.provides = (dom.get_string("provides") ?? "").copy(tmem);
	return conf;
}