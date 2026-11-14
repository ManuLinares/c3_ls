module lsp::analysis::rename;
import analyzer, lsp, uri, std;
import lsp::analysis::references;

<*
 Range of the renameable name token under the cursor. Fails when the
 cursor is not on a name, or the name does not resolve to a declaration
 spelled the same way.
*>
fn LspRange? prepare_rename(LspProject* project, Uri uri, LspPosition pos)
{
	Location loc = {
		.line = (int)pos.line,
		.column = (int)pos.character
	};

	SourceFile* sf = project.workspace.get_source_file_by_path(uri.path);
	if (!sf || !project.workspace.ctx) return NOT_FOUND~;

	Node* target = query::node_at(sf, loc);
	if (!target || target.kind == ERROR) return NOT_FOUND~;

	Ident* name = references::decl_name(target) ?: references::ref_name(target);
	if (!name || !name.range.touches(loc)) return NOT_FOUND~;

	Node* decl = query::resolve_symbol_at(project.workspace.ctx, sf, loc);
	if (!decl || decl.kind == MODULE_DECL) return NOT_FOUND~;
	if (decl.kind == TYPE_EXPR && constants::is_primitive(name.text)) return NOT_FOUND~;
	if (references::decl_symbol_name(decl) != name.text) return NOT_FOUND~;

	// Stdlib symbols are only renamed while editing the stdlib itself.
	SourceFile* decl_file = source_file::file_of(project.workspace.ctx, decl);
	if (decl_file && server::is_stdlib_file(decl_file.path) && !server::is_stdlib_file(uri.path)) return NOT_FOUND~;

	return {
		.start = {
			.line = (uint)name.range.start.line,
			.character = (uint)name.range.start.column
		},
		.end = {
			.line = (uint)name.range.end.line,
			.character = (uint)name.range.end.column
		}
	};
}

alias TextEditList = List{TextEdit};
alias FileEditsMap = HashMap{String, TextEditList};

fn WorkspaceEdit? rename(LspProject* project, Uri uri, LspPosition pos, String new_name)
{
	if (new_name.len == 0) return NOT_FOUND~;
	prepare_rename(project, uri, pos)!;

	LspLocation[] refs = references::find_references(project, uri, pos, {.includeDeclaration = true })!;
	if (refs.len == 0) return NOT_FOUND~;

	FileEditsMap edits_per_file;
	edits_per_file.tinit();

	foreach (ref_loc : refs)
	{
		TextEditList* file_edits = edits_per_file.get_or_create_ref(ref_loc.uri);
		if (!file_edits.is_initialized()) file_edits.tinit();
		file_edits.push({ .range = ref_loc.range, .newText = new_name });
	}

	List{TextDocumentEdit} doc_edits;
	doc_edits.tinit();

	edits_per_file.@each(; doc_uri, edits_list)
	{
		doc_edits.push({
			.textDocument = { .uri = doc_uri, .version = null },
			.edits = edits_list.array_view()
		});
	};

	return { .documentChanges = doc_edits.array_view() };
}
