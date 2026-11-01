module lsp::core::config;

import std::collections::map;
import std::collections::maybe;
import std::collections::object;
import std::encoding::json;
import std::io;

import uri;

const String PROJECT_CONFIG_NAME = "project.json";
const String MANIFEST_CONFIG_NAME = "manifest.json";

macro void free_maybe_string_array(Allocator allocator, maybe_arr)
{
	if (try val = maybe_arr.get())
	{
		foreach (s : val) s.free(allocator);
		alloc::free(allocator, val);
	}
}

struct TargetConfig
{
	Maybe{String[]} sources;
	Maybe{String[]} sources_override;
	Maybe{String[]} test_sources;
	Maybe{String[]} test_sources_override;
	Maybe{String[]} features;
	Maybe{String[]} features_override;
	Maybe{String[]} link_args;
	Maybe{String[]} link_args_override;
	Maybe{String[]} dependencies;
	Maybe{String[]} dependencies_override;
	Maybe{String[]} linked_libraries;
	Maybe{String[]} linked_libraries_override;
}

fn void TargetConfig.free(&self, Allocator allocator)
{
	free_maybe_string_array(allocator, self.sources);
	free_maybe_string_array(allocator, self.sources_override);
	free_maybe_string_array(allocator, self.test_sources);
	free_maybe_string_array(allocator, self.test_sources_override);
	free_maybe_string_array(allocator, self.features);
	free_maybe_string_array(allocator, self.features_override);
	free_maybe_string_array(allocator, self.link_args);
	free_maybe_string_array(allocator, self.link_args_override);
	free_maybe_string_array(allocator, self.dependencies);
	free_maybe_string_array(allocator, self.dependencies_override);
	free_maybe_string_array(allocator, self.linked_libraries);
	free_maybe_string_array(allocator, self.linked_libraries_override);
}

struct ProjectConfig
{
	String root_path;
	String[] sources;
	Maybe{String[]} test_sources;
	Maybe{String[]} dependency_search_paths;
	Maybe{String[]} dependencies;
	Maybe{String[]} features;
	HashMap{String, TargetConfig} targets;
}

fn void ProjectConfig.free(&self, Allocator allocator)
{
	if (self.root_path.len > 0) self.root_path.free(allocator);
	if (self.sources.len > 0)
	{
		foreach (s : self.sources) s.free(allocator);
		alloc::free(allocator, self.sources);
	}
	free_maybe_string_array(allocator, self.test_sources);
	free_maybe_string_array(allocator, self.dependency_search_paths);
	free_maybe_string_array(allocator, self.dependencies);
	free_maybe_string_array(allocator, self.features);
	if (self.targets.is_initialized())
	{
		self.targets.@each(; name, conf)
		{
			conf.free(allocator);
		};
	}

	self.targets.free();
}

struct ManifestConfig
{
	String provides;
	String[] sources;
	HashMap{String, TargetConfig} targets;
}

fn void ManifestConfig.free(&self, Allocator alloc)
{
	if (self.provides.len > 0) self.provides.free(alloc);
	if (self.sources.len > 0)
	{
		foreach (s : self.sources) s.free(alloc);
		alloc::free(alloc, self.sources);
	}

	self.targets.@each(; name, conf)
	{
		conf.free(alloc);
	};

	self.targets.free();
}

fn String[]? parse_string_array(Allocator alloc, Object* obj, String key)
{
	Object* arr_obj = obj.get(key) ?? null;
	if (!arr_obj || !arr_obj.is_array() || arr_obj.len() == 0) return NOT_FOUND~;

	sz count = arr_obj.len();
	String[] result = alloc::alloc_array(alloc, String, count);
	for (sz i = 0; i < count; i++)
	{
		result[i] = (arr_obj.get_string_at(i) ?? "").copy(alloc);
	}
	return result;
}

fn TargetConfig parse_target(Allocator alloc, Object* target_obj)
{
	TargetConfig conf = {};
	if (try s = parse_string_array(alloc, target_obj, "sources")) conf.sources = maybe::value(s);
	if (try s = parse_string_array(alloc, target_obj, "sources-override")) conf.sources_override = maybe::value(s);
	if (try s = parse_string_array(alloc, target_obj, "test-sources")) conf.test_sources = maybe::value(s);
	if (try s = parse_string_array(alloc, target_obj, "test-sources-override")) conf.test_sources_override = maybe::value(s);
	if (try s = parse_string_array(alloc, target_obj, "features")) conf.features = maybe::value(s);
	if (try s = parse_string_array(alloc, target_obj, "features-override")) conf.features_override = maybe::value(s);
	if (try s = parse_string_array(alloc, target_obj, "dependencies")) conf.dependencies = maybe::value(s);
	if (try s = parse_string_array(alloc, target_obj, "dependencies-override")) conf.dependencies_override = maybe::value(s);
	if (try s = parse_string_array(alloc, target_obj, "linked-libraries")) conf.linked_libraries = maybe::value(s);
	if (try s = parse_string_array(alloc, target_obj, "linked-libraries-override")) conf.linked_libraries_override = maybe::value(s);
	if (try s = parse_string_array(alloc, target_obj, "link-args")) conf.link_args = maybe::value(s);
	if (try s = parse_string_array(alloc, target_obj, "link-args-override")) conf.link_args_override = maybe::value(s);
	return conf;
}

fn void load(LspProject* lsp_project, WorkspaceFolder wf, Allocator allocator)
{
	Uri? uri = uri::parse(allocator, wf.uri);
	if (catch uri)
	{
		log::error("Failed to parse uri: (%s)", wf.uri);
		return;
	}
	defer uri.free();

	Path? root_path = path::tnew(uri.path);
	if (catch root_path)
	{
		log::error("Unknown workspace uri");
		return;
	}

	Path project_path = root_path.tappend(PROJECT_CONFIG_NAME) ?? (Path)"";
	Path manifest_path = root_path.tappend(MANIFEST_CONFIG_NAME) ?? (Path)"";

	bool found_project = path::exists(project_path);
	bool found_manifest = !found_project && path::exists(manifest_path);

	if (!found_project && !found_manifest)
	{
		log::error("No project.json or manifest.json found in root.");
		return;
	}

	String filename = found_project ? PROJECT_CONFIG_NAME : MANIFEST_CONFIG_NAME;
	Path config_path = found_project ? project_path : manifest_path;

	String? json_content = (String)file::load_temp(config_path);
	if (catch json_content)
	{
		log::error("Failed to load config file: %s", config_path);
		return;
	}

	Object*? dom_parsed = json::tparse(json_content);
	if (catch dom_parsed)
	{
		log::error("Failed to parse %s JSON", filename);
		return;
	}
	if (!dom_parsed)
	{
		log::error("Failed to parse %s JSON", filename);
		return;
	}
	Object* dom = dom_parsed;

	if (found_project)
	{
		log::info("Found project.json at (%s)", config_path);
		ProjectConfig conf;
		conf.targets.init(allocator);
		if (try srcs = parse_string_array(allocator, dom, "sources"))
		{
			conf.sources = srcs;
		}
		if (try test_srcs = parse_string_array(allocator, dom, "test-sources"))
		{
			conf.test_sources = maybe::value(test_srcs);
		}
		if (try search_paths = parse_string_array(allocator, dom, "dependency-search-paths"))
		{
			conf.dependency_search_paths = maybe::value(search_paths);
		}
		else
		{
			String[] default_paths = alloc::alloc_array(allocator, String, 1);
			default_paths[0] = "lib".copy(allocator);
			conf.dependency_search_paths = maybe::value(default_paths);
		}
		if (try deps = parse_string_array(allocator, dom, "dependencies"))
		{
			conf.dependencies = maybe::value(deps);
		}
		if (try feats = parse_string_array(allocator, dom, "features"))
		{
			conf.features = maybe::value(feats);
		}
		if (try targets_obj = dom.get("targets"))
		{
			targets_obj.@each_entry(; target_name, target_val)
			{
				if (target_val.is_map())
				{
					conf.targets[target_name] = parse_target(allocator, target_val);
				}
			};
		}
		lsp_project.config = conf;
	}
	else
	{
		log::info("Found manifest in root.");
		if (try srcs = parse_string_array(allocator, dom, "sources"))
		{
			lsp_project.config.sources = srcs;
		}
	}

	lsp_project.config.root_path = root_path.copy(allocator);
	log::info("Set config.root_path: %s", lsp_project.config.root_path);
}
