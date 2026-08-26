module lsp::translator;

import std::io;
import std::encoding::json;
import std::collections::maybe;
import std::collections::object;
import std::core::string;
import uri;

import lsp;

faultdef
INVALID_MESSAGE,
INCOMPLETE_JSON;

struct LspMessage
{
	String rpc;
	MessageKind method;
	int id;
	bool has_id;
	MessageParams params;
	Allocator allocator;
}

fn void LspMessage.free(&self)
{
	if (self.allocator == tmem) return;

	self.rpc.free(self.allocator);
	switch (self.method)
	{
		case INITIALIZE:
			self.params.initialize.locale.free(self.allocator);
			if (self.params.initialize.root_uri.has_value)
			{
				self.params.initialize.root_uri.value.free(self.allocator);
			}
			if (self.params.initialize.workspace_folders.has_value)
			{
				foreach (wf : self.params.initialize.workspace_folders.value)
				{
					wf.uri.free(self.allocator);
					wf.name.free(self.allocator);
				}
				alloc::free(self.allocator, self.params.initialize.workspace_folders.value);
			}
			self.params.initialize.client_info.name.free(self.allocator);
			self.params.initialize.client_info.version.free(self.allocator);
			if (self.params.initialize.initialization_options.has_value)
			{
				self.params.initialize.initialization_options.value.compiler_path.free(self.allocator);
				self.params.initialize.initialization_options.value.stdlib_path.free(self.allocator);
			}
		case DID_OPEN:
			self.params.did_open.document.uri.free(self.allocator);
			self.params.did_open.document.language_id.free(self.allocator);
			self.params.did_open.document.text.free(self.allocator);
		case DID_CLOSE:
			self.params.did_close.document.uri.free(self.allocator);
		case DID_CHANGE:
			self.params.did_change.document.uri.free(self.allocator);
			if (self.params.did_change.content_changes.len > 0)
			{
				foreach (c : self.params.did_change.content_changes)
				{
					c.text.free(self.allocator);
				}
				alloc::free(self.allocator, self.params.did_change.content_changes);
			}
		case HOVER:
			self.params.hover.document.uri.free(self.allocator);
		case DEFINITION:
			self.params.definition.document.uri.free(self.allocator);
		case COMPLETION:
			self.params.completion.text_document.uri.free(self.allocator);
		case COMPLETION_RESOLVE:
			self.params.completion_resolve.item.label.free(self.allocator);
			self.params.completion_resolve.item.detail.free(self.allocator);
			self.params.completion_resolve.item.insertText.free(self.allocator);
			self.params.completion_resolve.item.filterText.free(self.allocator);
			self.params.completion_resolve.item.sortText.free(self.allocator);
			self.params.completion_resolve.item.data.free(self.allocator);
		case HELP:
			self.params.signature_help.text_document.uri.free(self.allocator);
		case REFERENCES:
			self.params.references.text_document.uri.free(self.allocator);
		case PREPARE_RENAME:
			self.params.prepare_rename.text_document.uri.free(self.allocator);
		case RENAME:
			self.params.rename.text_document.uri.free(self.allocator);
			self.params.rename.newName.free(self.allocator);
		case FULL:
			self.params.semantic_tokens.text_document.uri.free(self.allocator);
		case SYMBOL:
			self.params.document_symbol.text_document.uri.free(self.allocator);
		case WS_SYMBOL:
			self.params.workspace_symbol.query.free(self.allocator);
		case INLAY_HINT:
			self.params.inlay_hint.text_document.uri.free(self.allocator);
		case FOLDING_RANGE:
			self.params.folding_range.text_document.uri.free(self.allocator);
		case FORMATTING:
			self.params.formatting.text_document.uri.free(self.allocator);
		case RANGE_FORMATTING:
			self.params.range_formatting.text_document.uri.free(self.allocator);
		default:
			break;
	}
}

<*
	Turn data into JSONRPC string
	@param [in] expr
	@return "JSONRPC string allocated with `allocator`"
*>
macro String encode(expr, Allocator allocator, int indent = 0)
{
	String expr_json = json::marshal(allocator, expr, NONE);
	usz expr_size = expr_json.len;

	return string::format(allocator,
	"Content-Length: %d\r\n\r\n%s",
	expr_size,
	expr_json
	);
}

struct IoDecodeResult
{
	LspMessage message;
	usz len;
}

<*
	Decode JSONRPC message
	@param [in] message : `json message without the header`
	@return "LSP message allocated with `allocator`, as well as length of whole message"
	@return? INCOMPLETE_JSON
	@return? INVALID_MESSAGE
*>
fn IoDecodeResult? decode(Allocator allocator, String message) => @pool()
{
	if (message.len == 0) return INVALID_MESSAGE~;

	Object*? parsed = json::tparse(message);
	if (catch parsed)
	{
		return INVALID_MESSAGE~;
	}

	Object* dom = parsed;
	if (dom == null) return INVALID_MESSAGE~;

	LspMessage msg;
	msg.allocator = allocator;

	String rpc = dom.get_string("jsonrpc") ?? "2.0";
	msg.rpc = rpc.copy(allocator);

	if (try id_val = dom.get_int("id"))
	{
		msg.id = (int)id_val;
		msg.has_id = true;
	}
	else
	{
		msg.id = -1;
		msg.has_id = false;
	}

	String method_str = dom.get_string("method") ?? "";
	msg.method = lsp::message_kind_from_string(method_str);

	if (try params_obj = dom.get("params"))
	{
		switch (msg.method)
		{
			case INITIALIZE:
				{
					InitializeParams init_params;
					init_params.process_id = (int)(params_obj.get_int("processId") ?? 0);
					String loc = params_obj.get_string("locale") ?? "";
					init_params.locale = loc.copy(allocator);

					if (try root_uri = params_obj.get_string("rootUri"))
					{
						init_params.root_uri = maybe::value((DocumentUri)root_uri.copy(allocator));
					}
					else if (try root_path = params_obj.get_string("rootPath"))
					{
						Uri u = uri::from_file_path(allocator, root_path);
						init_params.root_uri = maybe::value((DocumentUri)u.to_raw_string(allocator));
					}

					if (try wf_obj = params_obj.get("workspaceFolders"))
					{
						if (wf_obj.is_array() && wf_obj.len() > 0)
						{
							sz count = wf_obj.len();
							WorkspaceFolder[] wf_arr = alloc::alloc_array(allocator, WorkspaceFolder, count);
							for (sz i = 0; i < count; i++)
							{
								if (Object* f = wf_obj.get_at(i))
								{
									String wuri = f.get_string("uri") ?? "";
									String wname = f.get_string("name") ?? "";
									wf_arr[i] = {
										.uri = wuri.copy(allocator),
										.name = wname.copy(allocator)
									};
								}
							}
							init_params.workspace_folders = maybe::value(wf_arr);
						}
					}

					if (try client_info = params_obj.get("clientInfo"))
					{
						String cname = client_info.get_string("name") ?? "";
						String cver = client_info.get_string("version") ?? "";
						init_params.client_info.name = cname.copy(allocator);
						init_params.client_info.version = cver.copy(allocator);
					}

					if (try init_opts = params_obj.get("initializationOptions"))
					{
						String c_path = init_opts.get_string("compiler-path") ?? init_opts.get_string("compilerPath") ?? init_opts.get_string("compiler_path") ?? "";
						String s_path = init_opts.get_string("stdlib-path") ?? init_opts.get_string("stdlibPath") ?? init_opts.get_string("stdlib_path") ?? "";
						if (c_path.len > 0 || s_path.len > 0)
						{
							init_params.initialization_options = maybe::value((InitializationOptions){
								.compiler_path = c_path.copy(allocator),
								.stdlib_path = s_path.copy(allocator),
							});
						}
					}
					msg.params.initialize = init_params;
				}

			case DID_OPEN:
				{
					DidOpenParams open_params;
					if (try td = params_obj.get("textDocument"))
					{
						String uri_str = td.get_string("uri") ?? "";
						String lang_str = td.get_string("languageId") ?? "";
						String text_str = td.get_string("text") ?? "";
						open_params.document.uri = uri_str.copy(allocator);
						open_params.document.language_id = lang_str.copy(allocator);
						open_params.document.version = (int)(td.get_int("version") ?? 0);
						open_params.document.text = text_str.copy(allocator);
					}
					msg.params.did_open = open_params;
				}

			case DID_CLOSE:
				{
					DidCloseParams close_params;
					if (try td = params_obj.get("textDocument"))
					{
						String uri_str = td.get_string("uri") ?? "";
						close_params.document.uri = uri_str.copy(allocator);
					}
					msg.params.did_close = close_params;
				}

			case DID_CHANGE:
				{
					DidChangeParams change_params;
					if (try td = params_obj.get("textDocument"))
					{
						String uri_str = td.get_string("uri") ?? "";
						change_params.document.uri = uri_str.copy(allocator);
						change_params.document.version = (int)(td.get_int("version") ?? 0);
					}
					if (try changes = params_obj.get("contentChanges"))
					{
						if (changes.is_array())
						{
							sz count = changes.len();
							TextDocumentContentChangeEvent[] arr = alloc::alloc_array(allocator, TextDocumentContentChangeEvent, count);
							for (sz i = 0; i < count; i++)
							{
								if (Object* c = changes.get_at(i))
								{
									String ctext = c.get_string("text") ?? "";
									arr[i].text = ctext.copy(allocator);
								}
							}
							change_params.content_changes = arr;
						}
					}
					msg.params.did_change = change_params;
				}

			case HOVER:
				{
					HoverParams hover_params;
					if (try td = params_obj.get("textDocument"))
					{
						String uri_str = td.get_string("uri") ?? "";
						hover_params.document.uri = uri_str.copy(allocator);
					}
					if (try pos = params_obj.get("position"))
					{
						hover_params.position.line = (uint)(pos.get_int("line") ?? 0);
						hover_params.position.character = (uint)(pos.get_int("character") ?? 0);
					}
					msg.params.hover = hover_params;
				}

			case DEFINITION:
				{
					GoToDefinitionParams def_params;
					if (try td = params_obj.get("textDocument"))
					{
						String uri_str = td.get_string("uri") ?? "";
						def_params.document.uri = uri_str.copy(allocator);
					}
					if (try pos = params_obj.get("position"))
					{
						def_params.position.line = (uint)(pos.get_int("line") ?? 0);
						def_params.position.character = (uint)(pos.get_int("character") ?? 0);
					}
					msg.params.definition = def_params;
				}

			case COMPLETION:
				{
					CompletionParams comp_params;
					if (try td = params_obj.get("textDocument"))
					{
						String uri_str = td.get_string("uri") ?? "";
						comp_params.text_document.uri = uri_str.copy(allocator);
					}
					if (try pos = params_obj.get("position"))
					{
						comp_params.position.line = (uint)(pos.get_int("line") ?? 0);
						comp_params.position.character = (uint)(pos.get_int("character") ?? 0);
					}
					msg.params.completion = comp_params;
				}

			case COMPLETION_RESOLVE:
				{
					CompletionItem item;
					item.label = (params_obj.get_string("label") ?? "").copy(allocator);
					item.kind = (CompletionItemKind)(params_obj.get_int("kind") ?? 0);
					item.detail = (params_obj.get_string("detail") ?? "").copy(allocator);
					item.insertText = (params_obj.get_string("insertText") ?? "").copy(allocator);
					item.insertTextFormat = (InsertTextFormat)(params_obj.get_int("insertTextFormat") ?? 1);
					item.filterText = (params_obj.get_string("filterText") ?? "").copy(allocator);
					item.sortText = (params_obj.get_string("sortText") ?? "").copy(allocator);
					item.data = (params_obj.get_string("data") ?? "").copy(allocator);
					msg.params.completion_resolve.item = item;
				}

			case HELP:
				{
					SignatureHelpParams help_params;
					if (try td = params_obj.get("textDocument"))
					{
						String uri_str = td.get_string("uri") ?? "";
						help_params.text_document.uri = uri_str.copy(allocator);
					}
					if (try pos = params_obj.get("position"))
					{
						help_params.position.line = (uint)(pos.get_int("line") ?? 0);
						help_params.position.character = (uint)(pos.get_int("character") ?? 0);
					}
					msg.params.signature_help = help_params;
				}

			case REFERENCES:
				{
					ReferenceParams ref_params;
					if (try td = params_obj.get("textDocument"))
					{
						String uri_str = td.get_string("uri") ?? "";
						ref_params.text_document.uri = uri_str.copy(allocator);
					}
					if (try pos = params_obj.get("position"))
					{
						ref_params.position.line = (uint)(pos.get_int("line") ?? 0);
						ref_params.position.character = (uint)(pos.get_int("character") ?? 0);
					}
					if (try ctx_obj = params_obj.get("context"))
					{
						ref_params.context.includeDeclaration = ctx_obj.get_bool("includeDeclaration") ?? true;
					}
					msg.params.references = ref_params;
				}

			case PREPARE_RENAME:
				{
					PrepareRenameParams prep_params;
					if (try td = params_obj.get("textDocument"))
					{
						String uri_str = td.get_string("uri") ?? "";
						prep_params.text_document.uri = uri_str.copy(allocator);
					}
					if (try pos = params_obj.get("position"))
					{
						prep_params.position.line = (uint)(pos.get_int("line") ?? 0);
						prep_params.position.character = (uint)(pos.get_int("character") ?? 0);
					}
					msg.params.prepare_rename = prep_params;
				}

			case RENAME:
				{
					RenameParams ren_params;
					if (try td = params_obj.get("textDocument"))
					{
						String uri_str = td.get_string("uri") ?? "";
						ren_params.text_document.uri = uri_str.copy(allocator);
					}
					if (try pos = params_obj.get("position"))
					{
						ren_params.position.line = (uint)(pos.get_int("line") ?? 0);
						ren_params.position.character = (uint)(pos.get_int("character") ?? 0);
					}
					String new_name = params_obj.get_string("newName") ?? "";
					ren_params.newName = new_name.copy(allocator);
					msg.params.rename = ren_params;
				}

			case FULL:
				{
					SemanticTokensParams sem_params;
					if (try td = params_obj.get("textDocument"))
					{
						String uri_str = td.get_string("uri") ?? "";
						sem_params.text_document.uri = uri_str.copy(allocator);
					}
					msg.params.semantic_tokens = sem_params;
				}

			case SYMBOL:
				{
					DocumentSymbolParams sym_params;
					if (try td = params_obj.get("textDocument"))
					{
						String uri_str = td.get_string("uri") ?? "";
						sym_params.text_document.uri = uri_str.copy(allocator);
					}
					msg.params.document_symbol = sym_params;
				}

			case WS_SYMBOL:
				{
					WorkspaceSymbolParams ws_params;
					String q = params_obj.get_string("query") ?? "";
					ws_params.query = q.copy(allocator);
					msg.params.workspace_symbol = ws_params;
				}

			case INLAY_HINT:
				{
					InlayHintParams hint_params;
					if (try td = params_obj.get("textDocument"))
					{
						String uri_str = td.get_string("uri") ?? "";
						hint_params.text_document.uri = uri_str.copy(allocator);
					}
					if (try r = params_obj.get("range"))
					{
						if (try start_pos = r.get("start"))
						{
							hint_params.range.start.line = (uint)(start_pos.get_int("line") ?? 0);
							hint_params.range.start.character = (uint)(start_pos.get_int("character") ?? 0);
						}
						if (try end_pos = r.get("end"))
						{
							hint_params.range.end.line = (uint)(end_pos.get_int("line") ?? 0);
							hint_params.range.end.character = (uint)(end_pos.get_int("character") ?? 0);
						}
					}
					msg.params.inlay_hint = hint_params;
				}

			case FOLDING_RANGE:
				{
					FoldingRangeParams fold_params;
					if (try td = params_obj.get("textDocument"))
					{
						String uri_str = td.get_string("uri") ?? "";
						fold_params.text_document.uri = uri_str.copy(allocator);
					}
					msg.params.folding_range = fold_params;
				}

			case FORMATTING:
				{
					DocumentFormattingParams fmt_params;
					if (try td = params_obj.get("textDocument"))
					{
						String uri_str = td.get_string("uri") ?? "";
						fmt_params.text_document.uri = uri_str.copy(allocator);
					}
					if (try opt = params_obj.get("options"))
					{
						fmt_params.options.tab_size = (uint)(opt.get_int("tabSize") ?? 4);
						fmt_params.options.insert_spaces = opt.get_bool("insertSpaces") ?? false;
						fmt_params.options.trim_trailing_whitespace = opt.get_bool("trimTrailingWhitespace") ?? true;
						fmt_params.options.insert_final_newline = opt.get_bool("insertFinalNewline") ?? true;
						fmt_params.options.trim_final_newlines = opt.get_bool("trimFinalNewlines") ?? true;
					}
					msg.params.formatting = fmt_params;
				}

			case RANGE_FORMATTING:
				{
					DocumentRangeFormattingParams rfmt_params;
					if (try td = params_obj.get("textDocument"))
					{
						String uri_str = td.get_string("uri") ?? "";
						rfmt_params.text_document.uri = uri_str.copy(allocator);
					}
					if (try r = params_obj.get("range"))
					{
						if (try start_pos = r.get("start"))
						{
							rfmt_params.range.start.line = (uint)(start_pos.get_int("line") ?? 0);
							rfmt_params.range.start.character = (uint)(start_pos.get_int("character") ?? 0);
						}
						if (try end_pos = r.get("end"))
						{
							rfmt_params.range.end.line = (uint)(end_pos.get_int("line") ?? 0);
							rfmt_params.range.end.character = (uint)(end_pos.get_int("character") ?? 0);
						}
					}
					if (try opt = params_obj.get("options"))
					{
						rfmt_params.options.tab_size = (uint)(opt.get_int("tabSize") ?? 4);
						rfmt_params.options.insert_spaces = opt.get_bool("insertSpaces") ?? false;
						rfmt_params.options.trim_trailing_whitespace = opt.get_bool("trimTrailingWhitespace") ?? true;
						rfmt_params.options.insert_final_newline = opt.get_bool("insertFinalNewline") ?? true;
						rfmt_params.options.trim_final_newlines = opt.get_bool("trimFinalNewlines") ?? true;
					}
					msg.params.range_formatting = rfmt_params;
				}

			default:
				msg.params.unknown = params_obj;
		}
	}

	return {
		.message = msg,
		.len = message.len
	};
}
