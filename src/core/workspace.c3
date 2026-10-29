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
	HashMap{String, List{LspDiagnostic}} c3c_diagnostics;
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
	self.c3c_diagnostics.init(allocator);
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

	self.clear_all_c3c_diagnostics();
	self.c3c_diagnostics.free();

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

fn bool positions_less_than(LspPosition p1, LspPosition p2) @local
{
	if (p1.line < p2.line) return true;
	if (p1.line > p2.line) return false;
	return p1.character < p2.character;
}

fn bool positions_less_than_or_equal(LspPosition p1, LspPosition p2) @local
{
	if (p1.line < p2.line) return true;
	if (p1.line > p2.line) return false;
	return p1.character <= p2.character;
}

fn bool ranges_overlap(LspRange a, LspRange b) @local
{
	if (a.start.line == b.start.line && a.start.character == b.start.character) return true;
	if (a.start.line == a.end.line && a.start.character == a.end.character)
	{
		return positions_less_than_or_equal(b.start, a.start) && positions_less_than(a.start, b.end);
	}
	if (b.start.line == b.end.line && b.start.character == b.end.character)
	{
		return positions_less_than_or_equal(a.start, b.start) && positions_less_than(b.start, a.end);
	}
	return positions_less_than(a.start, b.end) && positions_less_than(b.start, a.end);
}

fn LspDiagnostic[] LspWorkspace.get_diagnostics(&self, String path)
{
	String norm_path = path;
	if (norm_path.contains("\\"))
	{
		char[] p = norm_path.copy(tmem);
		for (sz i = 0; i < p.len; i++)
		{
			if (p[i] == '\\') p[i] = '/';
		}
		norm_path = (String)p;
	}

	List{LspDiagnostic}* analyzer_list = self.diagnostics.get_ref(path) ?? (norm_path != path ? self.diagnostics.get_ref(norm_path) : null) ?? null;
	List{LspDiagnostic}* c3c_list = self.c3c_diagnostics.get_ref(norm_path) ?? (norm_path != path ? self.c3c_diagnostics.get_ref(path) : null) ?? null;

	if (!c3c_list || c3c_list.len() == 0)
	{
		if (analyzer_list) return analyzer_list.array_view();
		return {};
	}

	if (!analyzer_list || analyzer_list.len() == 0)
	{
		return c3c_list.array_view();
	}

	List{LspDiagnostic} merged;
	merged.tinit();

	foreach (d : *analyzer_list)
	{
		merged.push(d);
	}

	foreach (cd : *c3c_list)
	{
		bool overlaps = false;
		foreach (ad : *analyzer_list)
		{
			if (ranges_overlap(ad.range, cd.range))
			{
				overlaps = true;
				break;
			}
		}
		if (!overlaps)
		{
			merged.push(cd);
		}
	}

	return merged.to_tarray();
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

fn void LspWorkspace.clear_c3c_diagnostics_for_path(&self, String path)
{
	String norm_path = path;
	if (norm_path.contains("\\"))
	{
		char[] p = norm_path.copy(tmem);
		for (sz i = 0; i < p.len; i++)
		{
			if (p[i] == '\\') p[i] = '/';
		}
		norm_path = (String)p;
	}

	if (try list = self.c3c_diagnostics.get_ref(norm_path))
	{
		foreach (d : *list)
		{
			d.message.free(self.allocator);
		}
		list.clear();
	}
	else if (norm_path != path)
	{
		if (try list = self.c3c_diagnostics.get_ref(path))
		{
			foreach (d : *list)
			{
				d.message.free(self.allocator);
			}
			list.clear();
		}
	}
}

fn void LspWorkspace.clear_all_c3c_diagnostics(&self)
{
	self.c3c_diagnostics.@each(; path, list)
	{
		foreach (d : list)
		{
			d.message.free(self.allocator);
		}
		list.free();
	};
	self.c3c_diagnostics.clear();
}

fn void LspWorkspace.add_c3c_diagnostic(&self, String path, LspDiagnostic diag)
{
	if (path.len == 0) return;

	if (try List{LspDiagnostic}* existing_list = self.c3c_diagnostics.get_ref(path))
	{
		if (existing_list.len() >= MAX_DIAGNOSTICS_PER_FILE) return;
		existing_list.push(diag);
	}
	else
	{
		List{LspDiagnostic} list;
		list.init(self.allocator);
		list.push(diag);
		self.c3c_diagnostics.set(path, list);
	}
}

fn void LspWorkspace.parse_c3c_lsp_output(&self, String output, String root_path = "")
{
	self.clear_all_c3c_diagnostics();

	String[] lines = output.tsplit("\n");
	bool in_protocol = false;

	foreach (line : lines)
	{
		String l = line.trim();
		if (l.starts_with(">"))
		{
			l = l[1..].trim();
		}

		if (l == "BEGINLSP")
		{
			in_protocol = true;
			continue;
		}
		if (l == "ENDLSP-OK" || l == "ENDLSP-ERROR")
		{
			in_protocol = false;
			break;
		}

		if (!in_protocol) continue;
		if (!l.starts_with("LSPERR|")) continue;

		String rem = l["LSPERR|".len..];

		sz? p1 = rem.index_of_char('|');
		if (catch p1) continue;
		String sev_str = rem[:p1].trim();
		rem = rem[p1 + 1..];

		sz? p2 = rem.index_of_char('|');
		if (catch p2) continue;
		String raw_file = rem[:p2].trim();
		if (raw_file.starts_with("\"") && raw_file.ends_with("\"") && raw_file.len >= 2)
		{
			raw_file = raw_file[1 : ^2];
		}
		rem = rem[p2 + 1..];

		sz? p3 = rem.index_of_char('|');
		if (catch p3) continue;
		String line_str = rem[:p3].trim();
		rem = rem[p3 + 1..];

		sz? p4 = rem.index_of_char('|');
		if (catch p4) continue;
		String col_str = rem[:p4].trim();
		String raw_msg = rem[p4 + 1..].trim();
		if (raw_msg.starts_with("\"") && raw_msg.ends_with("\"") && raw_msg.len >= 2)
		{
			raw_msg = raw_msg[1 : ^2];
		}

		uint l_num = line_str.to_uint() ?? 0;
		uint c_num = col_str.to_uint() ?? 0;
		if (l_num == 0 || c_num == 0) continue;
		uint l_0 = l_num > 0 ? l_num - 1 : 0;
		uint c_0 = c_num > 0 ? c_num - 1 : 0;

		int severity = 1;
		switch (sev_str)
		{
			case "error": severity = 1;
			case "warn":  severity = 2;
			case "note":  severity = 4;
			default:      continue;
		}

		String norm_file = raw_file.copy(tmem);
		for (sz i = 0; i < norm_file.len; i++)
		{
			if (norm_file[i] == '\\') norm_file[i] = '/';
		}

		$if env::WIN32:
			if (norm_file.len >= 2 && norm_file[0].is_lower() && norm_file[1] == ':')
			{
				char[] p = norm_file.copy(tmem);
				p[0] = p[0].to_upper();
				norm_file = (String)p;
			}
		$endif

		if (!norm_file.starts_with("/") && !(norm_file.len >= 2 && norm_file[1] == ':'))
		{
			if (root_path.len > 0)
			{
				norm_file = string::tformat("%s/%s", root_path, norm_file);
			}
		}

		LspDiagnostic diag = {
			.range = {
				.start = { .line = l_0, .character = c_0 },
				.end = { .line = l_0, .character = c_0 + 1 }
			},
			.severity = severity,
			.message = raw_msg.copy(self.allocator),
			.source = "c3c"
		};

		self.add_c3c_diagnostic(norm_file, diag);
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
