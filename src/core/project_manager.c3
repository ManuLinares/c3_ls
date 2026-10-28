module lsp::core;

import std::collections::map;
import std::collections::list;
import std::io;
import uri;
import lsp::server;
import lsp::core::config;

struct ProjectManager
{
	HashMap{String, LspProject*} projects;
	LspProject default_project;
	LspProject* active_project;
	Allocator allocator;
}

fn void ProjectManager.init(&self, Allocator allocator)
{
	self.allocator = allocator;
	self.projects.init(allocator);
	self.default_project.init(allocator);
	self.active_project = null;
}

fn void ProjectManager.free(&self)
{
	self.projects.@each(; root, proj)
	{
		proj.free();
		alloc::free(self.allocator, proj);
	};
	self.projects.free();
	self.default_project.free();
	self.active_project = null;
}

<*
 Checks if a directory contains project.json or manifest.json.
*>
fn bool is_project_root_dir(Path dir)
{
	Path proj_json = dir.tappend(config::PROJECT_CONFIG_NAME) ?? (Path)"";
	Path manifest_json = dir.tappend(config::MANIFEST_CONFIG_NAME) ?? (Path)"";
	return path::exists(proj_json) || path::exists(manifest_json);
}

<*
 Walks up ancestor directories from file_path to find the nearest directory containing
 project.json or manifest.json.
*>
fn String find_enclosing_project_root(String file_path)
{
	if (file_path.len == 0) return "";

	String dir = file_path;
	if (!file::is_dir(dir))
	{
		dir = dir.path_tdirname() ?? "";
	}

	while (dir.len > 0)
	{
		Path? base_p = path::tnew(dir);
		if (catch base_p) break;

		if (is_project_root_dir(base_p))
		{
			return dir.copy(tmem);
		}

		String parent = dir.path_tdirname() ?? "";
		if (parent.len == 0 || parent == dir) break;
		dir = parent;
	}

	return "";
}

fn void ProjectManager.add_workspace_folder(&self, WorkspaceFolder wf)
{
	Uri? u = uri::parse(tmem, wf.uri);
	if (catch u) return;

	String root_str = u.path;
	Path? root_p = path::tnew(root_str);
	if (catch root_p) return;

	if (is_project_root_dir(root_p))
	{
		if (!self.projects.has_key(root_str))
		{
			LspProject* proj = alloc::new(self.allocator, LspProject);
			proj.init(self.allocator);
			config::load(proj, wf, self.allocator);
			self.projects.set(root_str.copy(self.allocator), proj);
			log::info("Registered project root: %s", root_str);
		}
		return;
	}

	// Fallback when root folder has no project.json: configure default_project
	config::load(&self.default_project, wf, self.allocator);

	// Shallow scan of immediate subdirectories (depth 1) for project roots
	if (try entries = path::ls(tmem, root_p, no_dirs: false, mask: "", recursive: false, rebase: root_p))
	{
		foreach (entry : entries)
		{
			Path? sub_p = root_p.tappend((String)entry);
			if (catch sub_p) continue;
			if (!path::is_dir(sub_p)) continue;

			if (is_project_root_dir(sub_p))
			{
				String sub_str = ((String)sub_p).copy(tmem);
				if (!self.projects.has_key(sub_str))
				{
					LspProject* sub_proj_inst = alloc::new(self.allocator, LspProject);
					sub_proj_inst.init(self.allocator);

					Uri sub_u = uri::from_file_path(tmem, sub_str);
					WorkspaceFolder sub_wf = {
						.uri = (DocumentUri)sub_u.to_raw_string(tmem),
						.name = ((String)entry).copy(self.allocator)
					};
					config::load(sub_proj_inst, sub_wf, self.allocator);
					self.projects.set(sub_str.copy(self.allocator), sub_proj_inst);
					log::info("Discovered subproject root: %s", sub_str);
				}
			}
		}
	}
}

fn void ProjectManager.initial_process_all(&self)
{
	if (self.default_project.config.root_path.len > 0)
	{
		self.default_project.initial_process();
	}
	self.projects.@each(; root, proj)
	{
		proj.initial_process();
	};
}

fn LspProject* ProjectManager.get_or_create_project_for_path(&self, String file_path)
{
	if (file_path.len == 0)
	{
		self.active_project = &self.default_project;
		return &self.default_project;
	}

	// 1. Longest prefix match against known project roots
	String best_root = "";
	LspProject* best_proj = null;
	self.projects.@each(; root, proj)
	{
		if (file_path.starts_with(root))
		{
			if (root.len > best_root.len)
			{
				best_root = root;
				best_proj = proj;
			}
		}
	};
	if (best_proj)
	{
		self.active_project = best_proj;
		return best_proj;
	}

	// 2. Walk up to locate enclosing project.json / manifest.json
	String enclosing_root = find_enclosing_project_root(file_path);
	if (enclosing_root.len > 0)
	{
		if (try LspProject* existing = self.projects.get(enclosing_root))
		{
			self.active_project = existing;
			return existing;
		}

		LspProject* new_proj = alloc::new(self.allocator, LspProject);
		new_proj.init(self.allocator);

		Uri root_u = uri::from_file_path(tmem, enclosing_root);
		WorkspaceFolder wf = {
			.uri = (DocumentUri)root_u.to_raw_string(tmem),
			.name = "",
		};

		config::load(new_proj, wf, self.allocator);
		new_proj.initial_process();

		self.projects.set(enclosing_root.copy(self.allocator), new_proj);
		log::info("Dynamically attached project root: %s", enclosing_root);

		self.active_project = new_proj;
		return new_proj;
	}

	self.active_project = &self.default_project;
	return &self.default_project;
}

fn LspProject* ProjectManager.get_or_create_project_for_uri(&self, Uri file_uri)
{
	return self.get_or_create_project_for_path(file_uri.path);
}

fn LspProject* ProjectManager.get_active_project(&self)
{
	return self.active_project ? self.active_project : &self.default_project;
}

fn void ProjectManager.update_all(&self)
{
	if (self.default_project.process_queue.len() > 0)
	{
		self.default_project.update();
	}
	self.projects.@each(; root, proj)
	{
		if (proj && proj.process_queue.len() > 0)
		{
			proj.update();
		}
	};
}
