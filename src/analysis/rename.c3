module lsp::analysis::rename;

import analyzer::core;
import analyzer::cursor;

import std::collections::list;
import std::collections::map;
import std::io;

import lsp::core;
import lsp;
import lsp::analysis::references;
import uri;

fn LspRange? prepare_rename(LspProject* project, Uri uri, LspPosition pos)
{
	Location loc = {
		.line = (int)pos.line,
		.column = (int)pos.character
	};

	SourceFile* sf = project.workspace.get_source_file_by_path(uri.path);
	if (!sf) return NOT_FOUND~;

	Range target_range = {.start = loc,.end = loc };
	Node* target_node = cursor::find_at(sf.ast.statements.array_view(), target_range);
	if (!target_node || target_node.kind == ERROR) return NOT_FOUND~;

	Range node_range = {};
	bool is_renameable = false;

	switch (target_node.kind)
	{
		case IDENT_EXPR:
			{
				IdentExpr* ie = target_node.as(IdentExpr);
				if (ie.ident && ie.ident.range.contains(loc))
				{
					node_range = ie.ident.range;
					is_renameable = true;
				}
			}
		case TYPE_EXPR:
			{
				TypeExpr* te = target_node.as(TypeExpr);
				if (te.type_kind == TYPE_IDENTIFIER && te.unresolved.name && te.unresolved.name.range.contains(loc))
				{
					node_range = te.unresolved.name.range;
					is_renameable = true;
				}
			}
		case VAR_DECL:
			{
				VarDecl* vd = target_node.as(VarDecl);
				if (vd.name && vd.name.range.contains(loc))
				{
					node_range = vd.name.range;
					is_renameable = true;
				}
			}
		case FN_DECL:
			{
				FnDecl* fd = target_node.as(FnDecl);
				if (fd.name && fd.name.range.contains(loc))
				{
					node_range = fd.name.range;
					is_renameable = true;
				}
			}
		case MACRO_DECL:
			{
				MacroDecl* md = target_node.as(MacroDecl);
				if (md.name && md.name.range.contains(loc))
				{
					node_range = md.name.range;
					is_renameable = true;
				}
			}
		case STRUCT_DECL:
			{
				StructDecl* sd = target_node.as(StructDecl);
				if (sd.name && sd.name.range.contains(loc))
				{
					node_range = sd.name.range;
					is_renameable = true;
				}
			}
		case ENUM_DECL:
			{
				EnumDecl* ed = target_node.as(EnumDecl);
				if (ed.name && ed.name.range.contains(loc))
				{
					node_range = ed.name.range;
					is_renameable = true;
				}
			}
		case TYPEDEF_DECL:
			{
				TypedefDecl* td = target_node.as(TypedefDecl);
				if (td.name && td.name.range.contains(loc))
				{
					node_range = td.name.range;
					is_renameable = true;
				}
			}
		case ALIAS_DECL:
			{
				AliasDecl* ad = target_node.as(AliasDecl);
				if (ad.name && ad.name.range.contains(loc))
				{
					node_range = ad.name.range;
					is_renameable = true;
				}
			}
		default:
			break;
	}

	if (!is_renameable) return NOT_FOUND~;

	return {
		.start = {
			.line = (uint)node_range.start.line,
			.character = (uint)node_range.start.column
		},
		.end = {
			.line = (uint)node_range.end.line,
			.character = (uint)node_range.end.column
		}
	};
}

alias TextEditList = List{TextEdit};
alias FileEditsMap = HashMap{String, TextEditList};

fn WorkspaceEdit? rename(LspProject* project, Uri uri, LspPosition pos, String new_name)
{
	if (new_name.len == 0) return NOT_FOUND~;

	LspLocation[]? refs = references::find_references(project, uri, pos, {.includeDeclaration = true });
	if (catch refs) return NOT_FOUND~;
	if (refs.len == 0) return NOT_FOUND~;

	FileEditsMap edits_per_file;
	edits_per_file.tinit();

	foreach (ref_loc : refs)
	{
		TextEdit edit = {
			.range = ref_loc.range,
			.newText = new_name
		};

		TextEditList* file_edits = edits_per_file.get_or_create_ref(ref_loc.uri);
		if (!file_edits.is_initialized())
		{
			file_edits.tinit();
		}
		file_edits.push(edit);
	}

	List{TextDocumentEdit} doc_edits;
	doc_edits.tinit();

	edits_per_file.@each(; doc_uri, edits_list)
	{
		doc_edits.push(
		{
			.textDocument = {
				.uri = doc_uri,
				.version = 0
			},
			.edits = edits_list.array_view()
		}
		);
	};

	return {
		.documentChanges = doc_edits.array_view()
	};
}
