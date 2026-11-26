module lsp::core::cache;

import std::encoding::json;
import std::io;
import std::hash::fnv64a;

const String CACHE_DIR_NAME = ".lsp-cache";
const String TRUST_FILE_NAME = ".trust";

struct MetaData
{
	ulong archive_hash;
}

fn ulong? archive_hash(String source_archive) @local
{
	return fnv64a::hash(file::load(tmem, source_archive)!);
}

fn Path? get_or_create_cache_dir(String workspace_root)
{
	Path base = path::tnew(workspace_root)!;
	Path build_dir = base.tappend("build")!;
	Path cache_dir = build_dir.tappend(CACHE_DIR_NAME)!;

	if (!path::exists(cache_dir))
	{
		if (catch err = path::mkdir(cache_dir, recursive: true))
		{
			log::error("Failed to create cache directory: %s", cache_dir);
			return err~;
		}
	}

	return cache_dir;
}

<*
 The trust level the user allowed for the project at `workspace_root`, `include` or `full`, kept
 in its cache folder and passed to c3c as `--trust`; empty when none was allowed.
*>
fn String trust_level(String workspace_root)
{
	Path? file = path::tnew(workspace_root).tappend("build").tappend(CACHE_DIR_NAME).tappend(TRUST_FILE_NAME);
	if (catch file) return "";
	String level = ((String)file::load_temp((String)file) ?? "").trim();
	return level == "include" || level == "full" ? level : "";
}

fn void? save_trust_level(String workspace_root, String level)
{
	Path dir = get_or_create_cache_dir(workspace_root)!;
	file::save((String)dir.tappend(TRUST_FILE_NAME)!, level)!;
}

<*
 Whether the cached extraction differs from the archive's current contents.
 @param library_name    : `e.g., lib`
 @param root_cache_path : `Path string to '.lsp-cache'`
 @param source_archive  : `Path string to the original archive file (e.g., path/to/lib.c3l)`
*>
fn bool? is_library_outdated(String library_name, String root_cache_path, String source_archive)
{
	Path cache_base = path::tnew(root_cache_path)!;
	Path lib_cache_dir = cache_base.tappend(library_name)!;

	if (!path::exists(lib_cache_dir)) return true;

	Path meta_file = lib_cache_dir.tappend("meta.json")!;
	if (!path::exists(meta_file)) return true;

	String? content = (String)file::load(tmem, meta_file);
	if (catch content) return true;

	MetaData? meta = json::unmarshal(tmem, content, MetaData);
	if (catch meta) return true;

	return meta.archive_hash != archive_hash(source_archive)!;
}

<*
 Writes the meta.json file into the library's cache folder after successful extraction.
*>
fn void? update_library_meta(String library_name, String root_cache_path, String source_archive)
{
	Path cache_base = path::tnew(root_cache_path)!;
	Path lib_cache_dir = cache_base.tappend(library_name)!;
	Path meta_file = lib_cache_dir.tappend("meta.json")!;

	MetaData meta = {.archive_hash = archive_hash(source_archive)! };
	String json_out = json::marshal(tmem, meta, NONE);

	if (catch file::save(meta_file, json_out))
	{
		log::error("Failed to write meta.json file for library: %s", library_name);
	}
}
