module lsp::core::config;

import std::collections::map;
import std::collections::object;
import std::encoding::json;
import std::io;

import uri;

const String PROJECT_CONFIG_NAME = "project.json";
const String MANIFEST_CONFIG_NAME = "manifest.json";

struct TargetConfig
{
	String[] sources;
	String[] sources_override @Json("sources-override");
	String[] test_sources @Json("test-sources");
	String[] test_sources_override @Json("test-sources-override");
	String[] features;
	String[] features_override @Json("features-override");
	String[] dependencies;
	String[] dependencies_override @Json("dependencies-override");
	String[] dependency_search_paths @Json("dependency-search-paths");
	String[] dependency_search_paths_override @Json("dependency-search-paths-override");
}

<*
 The target's sources, test sources and features: its `-override` list if set, else its own list.
*>
fn String[] TargetConfig.own_sources(&self) => self.sources_override.len > 0 ? self.sources_override : self.sources;
fn String[] TargetConfig.own_test_sources(&self) => self.test_sources_override.len > 0 ? self.test_sources_override : self.test_sources;
fn String[] TargetConfig.own_features(&self) => self.features_override.len > 0 ? self.features_override : self.features;

struct ProjectConfig
{
	String root_path;
	String[] sources;
	String[] test_sources;
	String[] dependency_search_paths;
	String[] dependencies;
	String[] features;
	HashMap{String, TargetConfig} targets;
}

fn void ProjectConfig.free(&self, Allocator allocator) => object::recursively_free{ProjectConfig}(allocator, self);

<*
 The top level of project.json. Targets are an object keyed by name, which json::unmarshal cannot decode
 into a map, so each one is decoded from its Object*.
*>
struct ProjectFile @local
{
	String[] sources;
	String[] test_sources @Json("test-sources");
	String[] dependency_search_paths @Json("dependency-search-paths");
	String[] dependencies;
	String[] features;
	Object* targets;
}

struct ManifestConfig
{
	String provides;
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

	ProjectFile? parsed = json::unmarshal(allocator, json_content, ProjectFile);
	if (catch err = parsed)
	{
		log::error("Failed to parse %s (%s)", filename, err);
		return;
	}
	ProjectFile file = parsed;
	defer object::recursively_free{ProjectFile}(allocator, &file);

	ProjectConfig conf;
	if (!found_project)
	{
		log::info("Found manifest in root.");
		conf.sources = file.sources;
		file.sources = {};
	}
	else
	{
		log::info("Found project.json at (%s)", config_path);
		if (file.dependency_search_paths.len == 0)
		{
			file.dependency_search_paths = alloc::new_array(allocator, String, 1);
			file.dependency_search_paths[0] = "lib".copy(allocator);
		}
		conf = {
			.sources = file.sources,
			.test_sources = file.test_sources,
			.dependency_search_paths = file.dependency_search_paths,
			.dependencies = file.dependencies,
			.features = file.features,
		};
		file = { .targets = file.targets };
		conf.targets.init(allocator);
		if (file.targets && file.targets.is_map())
		{
			file.targets.@each_entry(; target_name, target_val)
			{
				TargetConfig? target = json::unmarshal(allocator, json::marshal(tmem, target_val), TargetConfig);
				if (catch err = target)
				{
					log::error("Failed to parse target '%s' in %s (%s)", target_name, filename, err);
				}
				else
				{
					conf.targets[target_name] = target;
				}
			};
		}
	}

	conf.root_path = root_path.copy(allocator);
	lsp_project.config.free(allocator);
	lsp_project.config = conf;
	log::info("Set config.root_path: %s", conf.root_path);
}
