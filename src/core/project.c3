module lsp::core;

import std::io;
import std::collections::map;
import std::collections::list;
import std::collections::object;
import std::compression::zip;
import std::encoding::json;

import lsp::analysis;
import lsp::server;
import lsp::core::config;
import analyzer::core;
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

struct LspProject
{
	HashMap{String, LspFile*} files;
	List{FileInput} process_queue;
	LspWorkspace workspace;
	ProjectConfig config;
	HashMap{String, ManifestConfig} manifests;
	Allocator allocator;
}

fn void LspProject.init(&self, Allocator allocator)
{
	self.allocator = allocator;
	self.files.init(allocator);
	self.process_queue.init(allocator);
	self.workspace.init(allocator);
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
		tracked.text = document.text.copy(self.allocator);
		tracked.version = 1;

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

	FileInput file;

	if (!from_disk)
	{
		file = {
			.source_text = lsp_file.text,
			.uri = lookup_key,
			.path = lookup_key,
			.is_library = false,
		};
	}
	else
	{
		file = {
			.path = lookup_key,
			.uri = lookup_key,
			.is_library = true,
		};
	}

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

fn void LspProject.close_file(&self, DocumentUri document)
{
	String raw_uri = document;
	Uri? query_uri = uri::parse(tmem, raw_uri);
	if (catch query_uri) return;

	String lookup_key = query_uri.path;

	log::debug("Deregistering file: %s", lookup_key);

	if (!self.files.has_key(lookup_key))
	{
		log::error("Attempted to drop non-existent file path identifier (%s)", lookup_key);
		return;
	}

	LspFile* file = self.files.get(lookup_key) ?? null;
	if (!file) return;

	file.free(self.allocator);
	alloc::free(self.allocator, file);
	self.files.remove(lookup_key);
}

fn void LspProject.update(&self)
{
	if (self.process_queue.is_empty()) return;

	FileInput[] files = self.process_queue.array_view();
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
		}
	}
	// Pass 2: Execute semantic analysis only on user files (not stdlib/library files).
	// Library files are already registered in Pass 1; running the variable pass over
	// their bodies is redundant since diagnostics for library files are discarded anyway.
	foreach (f : files)
	{
		if (f.is_library) continue;
		String target_path = f.path.len > 0 ? f.path : f.uri;
		self.workspace.analyze_file(target_path);
	}

	server::publish_diagnostics(files, &self.workspace);
}

fn void LspProject.initial_process(&self)
{
	self.process_stdlib();
	self.process_config();
	self.process_libs();
	self.update();
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

fn void LspProject.process_config(&self)
{
	if (self.config.root_path.len == 0) return;

	Path? base_path = path::tnew(self.config.root_path);
	if (catch err = base_path)
	{
		log::error("Config base path is not valid: %s", err);
		return;
	}

	log::info("Base path: %s", base_path);

	foreach (source_entry : self.config.sources)
	{
		String entry_str = source_entry;
		bool recursive = false;
		String mask = "*.c3";

		if (entry_str.ends_with("/**"))
		{
			entry_str = entry_str.strip_suffix("/**");
			recursive = true;
		}

		Path? entry_path = base_path.tappend(entry_str);
		if (catch err = entry_path)
		{
			log::error("'%s' is not a valid directory layout: %s", entry_str, err);
			continue;
		}

		PathList paths;
		if (catch err = @try(paths, path::ls(tmem, entry_path, no_dirs: true, mask: mask, recursive: recursive, rebase: entry_path)))
		{
			log::error("Failed to list directory contents for: %s", entry_str);
			continue;
		}

		foreach (matched : paths)
		{
			log::info("Found source path: %s", matched);
			Uri file_uri = uri::from_file_path(tmem, matched);
			DocumentUri uri = (DocumentUri)file_uri.to_raw_string(tmem);
			self.open_file({ .uri = uri }, from_disk: false);
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
