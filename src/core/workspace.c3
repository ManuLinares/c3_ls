module lsp::core;

import analyzer::core;
import analyzer::core::context;
import analyzer::core::diagnostics;
import analyzer::core::source_file;
import analyzer::cursor;
import analyzer::sema;
import analyzer::sema::registry;
import analyzer::sema::query;
import analyzer::lexer;

import std::collections::list;
import std::collections::map;
import std::io;

struct SymbolEntry
{
	Node* node;
	ulong section_id;
}

struct LspWorkspace
{
	AnalyzerContext* ctx;
	Allocator allocator;
	HashMap{String, List{LspDiagnostic}} diagnostics;
}

LspWorkspace* active_workspace @local = null;
String active_processing_path @local = "";

const uint MAX_DIAGNOSTICS_PER_FILE = 100;

fn void on_analyzer_diagnostic(SourceFile* file, Range range, DiagnosticLevel level, String message)
{
	if (!active_workspace) return;

	String path = file ? file.path : active_processing_path;
	if (path.len == 0) return;

	if (try List{LspDiagnostic} * existing_list = active_workspace.diagnostics.get_ref(path))
	{
		if (existing_list.len() >= MAX_DIAGNOSTICS_PER_FILE) return;
	}

	int severity = 1;
	switch (level)
	{
		case ERROR: severity = 1;
		case WARN: severity = 2;
		case INFO: severity = 3;
		case NOTE: severity = 4;
	}

	LspDiagnostic diag = {
		.range = {
			.start = {
				.line = range.start.line >= 0 ? (uint)range.start.line : 0,
				.character = range.start.column >= 0 ? (uint)range.start.column : 0
			},
			.end = {
				.line = range.end.line >= 0 ? (uint)range.end.line : (range.start.line >= 0 ? (uint)range.start.line : 0),
				.character = range.end.column >= 0 ? (uint)range.end.column : (range.start.column >= 0 ? (uint)range.start.column : 0)
			}
		},
		.severity = severity,
		.message = message.copy(active_workspace.allocator),
		.source = "c3-analyzer"
	};

	if (try List{LspDiagnostic} * list = active_workspace.diagnostics.get_ref(path))
	{
		list.push(diag);
	}
	else
	{
		List{LspDiagnostic} list;
		list.init(active_workspace.allocator);
		list.push(diag);
		active_workspace.diagnostics.set(path, list);
	}
}

fn void LspWorkspace.init(&self, Allocator allocator)
{
	self.allocator = allocator;
	self.ctx = context::create(allocator);
	self.diagnostics.init(allocator);
}

fn void LspWorkspace.free(&self)
{
	self.diagnostics.@each(; path, list)
	{
		foreach (d : list)
		{
			d.message.free(self.allocator);
		}
		list.free();
	};
	self.diagnostics.free();

	if (self.ctx)
	{
		context::free(self.ctx);
	}
}

<*
 Retrieves a parsed SourceFile by its normalized path identifier.
*>
fn SourceFile* LspWorkspace.get_source_file_by_path(&self, String path)
{
	if (!self.ctx) return null;
	return self.ctx.files.get(path) ?? null;
}

fn List{SymbolEntry} LspWorkspace.find_symbol_by_name(&self, String name, SourceFile* sf = null)
{
	List{SymbolEntry} results;
	results.tinit();

	if (!self.ctx || name.len == 0) return results;

	if (self.ctx.registry)
	{
		self.ctx.modules.@each(; mod_name, mod)
		{
			if (!sf || query::is_module_visible_to_file(self.ctx, sf, mod_name))
			{
				String qname = string::tformat("%s::%s", mod_name, name);
				FunctionInfo* fn_info = self.ctx.registry.functions.get(qname) ?? null;
				while (fn_info != null)
				{
					if (fn_info.node && fn_info.node.kind != ERROR)
					{
						if (!sf || query::is_symbol_accessible_from_file(self.ctx, sf, fn_info.node, mod_name))
						{
							results.push(
							{
								.node = fn_info.node,.section_id = 0
							}
							);
						}
					}
					fn_info = fn_info.next;
				}

				TypeInfo* ty_info = self.ctx.registry.types.get(qname) ?? null;
				while (ty_info != null)
				{
					if (ty_info.node && ty_info.node.kind != ERROR)
					{
						if (!sf || query::is_symbol_accessible_from_file(self.ctx, sf, ty_info.node, mod_name))
						{
							results.push(
							{
								.node = ty_info.node,.section_id = 0
							}
							);
						}
					}
					ty_info = ty_info.next;
				}

				MacroInfo* mac_info = self.ctx.registry.macros.get(qname) ?? null;
				while (mac_info != null)
				{
					if (mac_info.node && mac_info.node.kind != ERROR)
					{
						if (!sf || query::is_symbol_accessible_from_file(self.ctx, sf, mac_info.node, mod_name))
						{
							results.push(
							{
								.node = mac_info.node,.section_id = 0
							}
							);
						}
					}
					mac_info = mac_info.next;
				}
			}
		};
	}

	self.ctx.modules.@each(; mod_name, mod)
	{
		if (mod && (!sf || query::is_module_visible_to_file(self.ctx, sf, mod_name)))
		{
			foreach (n : mod.nodes)
			{
				if (!n) continue;
				if (sf && !query::is_symbol_accessible_from_file(self.ctx, sf, n, mod_name)) continue;

				switch (n.kind)
				{
					case ENUM_DECL:
						{
							EnumDecl* ed = n.as(EnumDecl);
							foreach (variant : ed.variants)
							{
								if (!variant || variant.kind != VAR_DECL) continue;
								VarDecl* vd = variant.as(VarDecl);
								if (vd.name && vd.name.text == name)
								{
									results.push(
									{
										.node = variant,.section_id = 0
									}
									);
								}
							}
						}
					case STRUCT_DECL:
						{
							StructDecl* sd = n.as(StructDecl);
							foreach (field : sd.fields)
							{
								if (!field || field.kind != VAR_DECL) continue;
								VarDecl* vd = field.as(VarDecl);
								if (vd.name && vd.name.text == name)
								{
									results.push(
									{
										.node = field,.section_id = 0
									}
									);
								}
							}
						}
					default:
						break;
				}
			}
		}
	};

	if (results.len() == 0)
	{
		self.ctx.files.@each(; file_path, file_sf)
		{
			if (file_sf)
			{
				String file_mod = query::get_source_file_module_name(file_sf);
				foreach (stmt : file_sf.ast.statements)
				{
					if (!stmt || stmt.kind == ERROR) continue;
					if (sf && !query::is_symbol_accessible_from_file(self.ctx, sf, stmt, file_mod)) continue;

					String sname = cursor::spelling(stmt, tmem);
					if (sname == name)
					{
						results.push(
						{
							.node = stmt,.section_id = 0
						}
						);
					}
				}
			}
		};
	}

	return results;
}

fn List{SymbolEntry} LspWorkspace.find_method(&self, String type_name, String method_name)
{
	List{SymbolEntry} results;
	results.tinit();

	if (!self.ctx || type_name.len == 0 || method_name.len == 0) return results;

	self.ctx.files.@each(; file_path, sf)
	{
		if (sf)
		{
			foreach (stmt : sf.ast.statements)
			{
				if (!stmt || stmt.kind == ERROR) continue;

				switch (stmt.kind)
				{
					case FN_DECL:
						{
							FnDecl* fn_decl = stmt.as(FnDecl);
							if (fn_decl.name && fn_decl.name.text == method_name && fn_decl.associated_type)
							{
								String assoc = cursor::raw_type_identifier(fn_decl.associated_type) ?? "";
								if (assoc == type_name)
								{
									results.push(
									{
										.node = stmt,.section_id = 0
									}
									);
								}
							}
						}
					case MACRO_DECL:
						{
							MacroDecl* mac_decl = stmt.as(MacroDecl);
							if (mac_decl.name && mac_decl.name.text == method_name)
							{
								if (try assoc_node = mac_decl.associated_type.get())
								{
									String assoc = cursor::raw_type_identifier(assoc_node) ?? "";
									if (assoc == type_name)
									{
										results.push(
										{
											.node = stmt,.section_id = 0
										}
										);
									}
								}
							}
						}
					default:
						break;
				}
			}
		}
	};

	return results;
}

fn LspDiagnostic[] LspWorkspace.get_diagnostics(&self, String path)
{
	if (try list = self.diagnostics.get(path))
	{
		return list.array_view();
	}
	return {};
}

fn void LspWorkspace.clear_diagnostics_for_path(&self, String path)
{
	if (try list = self.diagnostics.get(path))
	{
		foreach (d : list)
		{
			d.message.free(self.allocator);
		}
		list.free();
		(void)self.diagnostics.remove(path);
	}
}

fn bool LspWorkspace.parse_and_register_file(&self, String path, String text)
{
	self.clear_diagnostics_for_path(path);

	active_workspace = self;
	active_processing_path = path;
	diagnostics::callback = &on_analyzer_diagnostic;

	bool ok = context::parse_and_register(self.ctx, text, path);

	active_workspace = null;
	active_processing_path = "";

	return ok;
}

fn bool LspWorkspace.analyze_file(&self, String path)
{
	active_workspace = self;
	active_processing_path = path;
	diagnostics::callback = &on_analyzer_diagnostic;

	bool ok = context::analyze_file(self.ctx, path);

	active_workspace = null;
	active_processing_path = "";

	return ok;
}

fn bool LspWorkspace.process_file(&self, String path, String text)
{
	self.clear_diagnostics_for_path(path);

	active_workspace = self;
	active_processing_path = path;
	diagnostics::callback = &on_analyzer_diagnostic;

	bool ok = context::process(self.ctx, text, path);

	active_workspace = null;
	active_processing_path = "";

	return ok;
}
