module lsp::server;

import lsp, uri, std::io, std::thread, std::time, std::os::process, std::collections::object, std::collections::list;

bool is_ready;
bool is_std_path_alloc;
bool is_compiler_path_alloc;
bool cli_std_path_set;
bool cli_compiler_path_set;
bool running @local;
LogLevel log_level;
String log_path;
String std_path;
String compiler_path;
ProjectManager project_manager;

fn LspProject* get_project_for_raw_uri(String raw_uri)
{
	Uri? u = uri::parse(tmem, raw_uri);
	if (catch u) return &project_manager.default_project;
	return project_manager.get_or_create_project_for_uri(u);
}

struct LspInitializeResponse
{
	String jsonrpc;
	int id;
	InitializeResult result;
}

struct InitializeResult
{
	LspServerCapabilities capabilities;
	ServerInfo serverInfo;
}

struct ServerInfo
{
	String name;
	String version;
}

struct LspShutdownResponse
{
	String jsonrpc;
	int id;
	Object* result;
}

struct LspHoverResponse
{
	String jsonrpc;
	int id;
	HoverResult result;
}

struct HoverResult
{
	MarkupContent contents;
}

struct LspFormattingResponse
{
	String jsonrpc;
	int id;
	TextEdit[] result;
}

struct LspGoToDefinitionResponse
{
	String jsonrpc;
	int id;
	LspLocation[] result;
}

struct LspCompletionResponse
{
	String jsonrpc;
	int id;
	CompletionResult result;
}

struct CompletionResult
{
	bool isIncomplete;
	CompletionItem[] items;
}

struct LspCompletionResolveResponse
{
	String jsonrpc;
	int id;
	CompletionItem result;
}

struct LspSignatureHelpResponse
{
	String jsonrpc;
	int id;
	SignatureHelpResult result;
}

struct LspReferencesResponse
{
	String jsonrpc;
	int id;
	LspLocation[] result;
}

struct LspPrepareRenameResponse
{
	String jsonrpc;
	int id;
	LspRange result;
}

struct LspRenameResponse
{
	String jsonrpc;
	int id;
	WorkspaceEdit result;
}

struct LspSemanticTokensResponse
{
	String jsonrpc;
	int id;
	SemanticTokensResult result;
}

struct LspDocumentSymbolResponse
{
	String jsonrpc;
	int id;
	SymbolInformation[] result;
}

struct LspWorkspaceSymbolResponse
{
	String jsonrpc;
	int id;
	SymbolInformation[] result;
}

struct LspInlayHintResponse
{
	String jsonrpc;
	int id;
	InlayHint[] result;
}

struct LspFoldingRangeResponse
{
	String jsonrpc;
	int id;
	FoldingRange[] result;
}

struct LspCodeActionResponse
{
	String jsonrpc;
	int id;
	CodeAction[] result;
}

struct LspExecuteCommandResponse
{
	String jsonrpc;
	int id;
	Object* result;
}

struct LspPublishDiagnosticsNotification
{
	String jsonrpc;
	String method;
	PublishDiagnosticsResult params;
}

struct PublishDiagnosticsResult
{
	DocumentUri uri;
	LspDiagnostic[] diagnostics;
}

fn void publish_diagnostics_for_path(String file_path, LspWorkspace* ws) => @pool()
{
	if (!ws || file_path.len == 0) return;

	Uri file_uri = uri::from_file_path(tmem, file_path);
	DocumentUri formatted_uri = (DocumentUri)file_uri.to_raw_string(tmem);

	LspDiagnostic[] diags = ws.get_diagnostics(file_path);

	LspPublishDiagnosticsNotification notif = {
		.jsonrpc = "2.0",
		.method = "textDocument/publishDiagnostics",
		.params = {
			.uri = formatted_uri,
			.diagnostics = diags,
		}
	};

	String response_json = translator::encode(notif, tmem);
	log::debug("Sending diagnostics for file: %s", response_json);
	io_handler::write(response_json);
}

fn void start(CliArgs args)
{
	@assert_leak()
	{
		log::set_logger(&& (LspLogger){});
		log_level = args.log_level;
		log::set_priority_all(VERBOSE);

		log_path = args.log_path;
		std_path = args.stdlib_path;
		compiler_path = args.compiler_path.len > 0 ? args.compiler_path : "c3c";
		log_level = args.log_level;

		logger::init();
		defer logger::close();

		log::info("LogPath = %s", log_path);
		log::info("std_path = %s", std_path);
		log::info("compiler_path = %s", compiler_path);
		log::info("log_level = %s", log_level);

		io_handler::init();

		project_manager.init(mem);
		defer project_manager.free();

		running = true;

		if (std_path.len == 0)
		{
			setup_stdlib_path();
		}
		else
		{
			std_path = std_path.trim_right("/\\");
		}

		cli_std_path_set = args.stdlib_path.len > 0;
		cli_compiler_path_set = args.compiler_path.len > 0;

		defer
		{
			if (is_std_path_alloc)
			{
				std_path.free(mem);
			}
			if (is_compiler_path_alloc)
			{
				compiler_path.free(mem);
			}
		};

		loop();
	};
}

fn void loop()
{
	while (running) @pool()
	{
		LspMessage? data = io_handler::read(tmem);
		if (catch err = data)
		{
			if (err == io::EOF)
			{
				log::info("Client disconnected (EOF). Terminating process.");
				running = false;
				break;
			}
			log::error("Stream read error encountered: %s", err);
			continue;
		}

		dispatch(&data);

		if (is_ready)
		{
			project_manager.update_all();
		}
	};
}

fn void dispatch(LspMessage* message)
{
	switch (message.method)
	{
		case INITIALIZE: on_initialize(message, &message.params.initialize);
		case INITIALIZED:
			log::info("received Initialized");
			is_ready = true;
			project_manager.initial_process_all();
		case DID_OPEN: on_did_open(message, &message.params.did_open);
		case DID_CHANGE: on_did_change(message, &message.params.did_change);
		case DID_CLOSE: on_did_close(message, &message.params.did_close);
		case DID_SAVE: on_did_save(message, &message.params.did_save);
		case FULL: on_semantic_tokens(message, &message.params.semantic_tokens);
		case SYMBOL: on_document_symbol(message, &message.params.document_symbol);
		case HOVER: on_hover(message, &message.params.hover);
		case COMPLETION: on_completion(message, &message.params.completion);
		case DEFINITION: on_definition(message, &message.params.definition);
		case REFERENCES: on_references(message, &message.params.references);
		case HELP: on_signature_help(message, &message.params.signature_help);
		case RENAME: on_rename(message, &message.params.rename);
		case PREPARE_RENAME: on_prepare_rename(message, &message.params.prepare_rename);
		case FORMATTING: on_formatting(message, &message.params.formatting);
		case RANGE_FORMATTING: on_range_formatting(message, &message.params.range_formatting);
		case CODE_ACTION: on_code_action(message, &message.params.code_action);
		case FOLDING_RANGE: on_folding_range(message, &message.params.folding_range);
		case INLAY_HINT: on_inlay_hint(message, &message.params.inlay_hint);
		case WS_CHANGE_WATCHED: on_did_change_watched(message, &message.params.did_change_watched);
		case WS_SYMBOL: on_workspace_symbol(message, &message.params.workspace_symbol);
		case WS_EXECUTE_COMMAND: on_execute_command(message, &message.params.execute_command);
		case COMPLETION_RESOLVE: on_completion_resolve(message, &message.params.completion_resolve);
		case SHUTDOWN:
			{
				LspShutdownResponse response = {
					.jsonrpc = message.rpc,
					.id = message.has_id ? message.id : -1,
					.result = null,
				};
				io_handler::write(translator::encode(response, tmem));
			}
		case EXIT:
			log::info("Exit notification received. Terminating process.");
			running = false;
		case SET_TRACE:
			break;
		case UNKNOWN:
		case DECLERATION:
		case WILL_SAVE:
		case WILL_SAVE_WAIT:
		case ON_TYPE_FORMAT:
		case CODE_LENS:
		case CODE_LENS_RESOLVE:
		case SELECTION_RANGE:
		case TYPE_DEFINITION:
		case IMPLEMENTATION:
		case INLAY_HINT_RESOLVE:
		case DIAGNOSTIC:
		case SEM_TOKENS_RANGE:
		case SEM_TOKENS_DELTA:
		case PREPARE_CALL_HIER:
		case LINKED_EDITING:
		case MONIKER:
		case PUB_DIAG:
		case SHOW_MESSAGE:
		case LOG_MESSAGE:
		case SHOW_MSG_REQUEST:
		case SHOW_DOCUMENT:
		case WDP_CREATE:
		case WDP_CANCEL:
		case WS_CHANGE_CONFIG:
		case WS_CHANGE_FOLDERS:
		case WS_APPLY_EDIT:
		case WS_CONFIGURATION:
		case WS_DIAGNOSTIC:
		case WS_DIAG_REFRESH:
		case WS_SEM_REFRESH:
		case WS_CODELENS_REFRESH:
		case WS_INLAY_REFRESH:
		case CALL_INCOMING:
		case CALL_OUTGOING:
		case TYPE_SUPERTYPES:
		case TYPE_SUBTYPES:
		case CANCEL:
		case PROGRESS:
		case LOG_TRACE:
			log::verbose("Unhandled LSP method: %s", message.method);
	}
}

fn void on_initialize(LspMessage* message, InitializeParams* params)
{
	LspInitializeResponse resp = {
		.jsonrpc = message.rpc,
		.id = message.has_id ? message.id : -1,
		.result = {
			.capabilities = {
				.textDocumentSync = {
					.openClose = true,
					.change = FULL,
					.save = { .includeText = false },
				},
				.completionProvider = {
					.triggerCharacters = { ".", ":", "@", " " },
					.resolveProvider = true,
					.completionItem = {.labelDetailSupport = true }
				},
				.hoverProvider = true,
				.definitionProvider = true,
				.signatureHelpProvider = {
					.triggerCharacters = { "(", "," },
					.retriggerCharacters = { "," }
				},
				.referencesProvider = true,
				.renameProvider = {.prepareProvider = true },
				.semanticTokensProvider = {
					.legend = {
						.tokenTypes = semantic_tokens::get_token_types(),
						.tokenModifiers = semantic_tokens::get_token_modifiers()
					},
					.full = true
				},
				.documentSymbolProvider = true,
				.workspaceSymbolProvider = true,
				.inlayHintProvider = true,
				.foldingRangeProvider = true,
				.documentFormattingProvider = true,
				.documentRangeFormattingProvider = true,
				.codeActionProvider = true,
				.executeCommandProvider = {
					.commands = { code_actions::CMD_GENERATE_BINDINGS }
				}
			},
			.serverInfo = {
				.name = "c3_ls",
				.version = env::PROJECT_VERSION,
			},
		},
	};
	io_handler::write(translator::encode(resp, tmem));

	InitializationOptions init_opts = params.options();
	{
		if (!cli_compiler_path_set && init_opts.compiler_path.len > 0)
		{
			if (is_compiler_path_alloc) compiler_path.free(mem);
			compiler_path = init_opts.compiler_path.copy(mem);
			is_compiler_path_alloc = true;
			log::info("Updated compiler_path from initializationOptions: %s", compiler_path);
			if (!cli_std_path_set && init_opts.stdlib_path.len == 0)
			{
				if (is_std_path_alloc)
				{
					std_path.free(mem);
					is_std_path_alloc = false;
				}
				setup_stdlib_path();
			}
		}
		if (!cli_std_path_set && init_opts.stdlib_path.len > 0)
		{
			if (is_std_path_alloc)
			{
				std_path.free(mem);
			}
			std_path = init_opts.stdlib_path.trim_right("/\\").copy(mem);
			is_std_path_alloc = true;
			log::info("Updated std_path from initializationOptions: %s", std_path);
		}
	}

	if (params.trace == TraceKind.VERBOSE) log::set_priority_all(VERBOSE);
	if (try pid = params.process_id.value()) watch_parent_process(pid);
	WorkspaceFolder[] folders = params.workspace_folders;
	foreach (wf : folders)
	{
		project_manager.add_workspace_folder(wf);
	}
	DocumentUri root = params.root(tmem);
	if (folders.len == 0 && root.len > 0)
	{
		project_manager.add_workspace_folder({ .uri = root });
	}
}

fn void on_did_open(LspMessage* message, DidOpenParams* params)
{
	LspProject* proj = get_project_for_raw_uri(params.document.uri);
	proj.open_file(params.document);
}

fn void on_did_change(LspMessage* message, DidChangeParams* params)
{
	LspProject* proj = get_project_for_raw_uri(params.document.uri);
	proj.change_file(*params);
}

fn void on_did_close(LspMessage* message, DidCloseParams* params)
{
	LspProject* proj = get_project_for_raw_uri(params.document.uri);
	proj.close_document(params.document.uri);
}

fn void on_did_save(LspMessage* message, DidSaveParams* params)
{
	LspProject* proj = get_project_for_raw_uri(params.document.uri);
	proj.save_file(params.document.uri);
}

fn void on_completion(LspMessage* message, CompletionParams* params)
{
	Uri? file_uri = uri::parse(tmem, params.text_document.uri);
	if (catch file_uri) return;
	LspProject* proj = project_manager.get_or_create_project_for_uri(file_uri);
	CompletionItem[]? items = completion::resolve(proj, file_uri, params.position);
	LspCompletionResponse res = {
		.jsonrpc = message.rpc,
		.id = message.has_id ? message.id : -1,
		.result = {
			.isIncomplete = true,
			.items = items ?? {},
		}
	};
	io_handler::write(translator::encode(res, tmem));
}

fn void on_completion_resolve(LspMessage* message, CompletionItem* params)
{
	CompletionItem item = *params;
	completion::resolve_item(project_manager.get_active_project(), &item);
	LspCompletionResolveResponse res = {
		.jsonrpc = message.rpc,
		.id = message.has_id ? message.id : -1,
		.result = item
	};
	io_handler::write(translator::encode(res, tmem));
}

fn void on_hover(LspMessage* message, HoverParams* params)
{
	Uri? file_uri = uri::parse(tmem, params.document.uri);
	if (catch file_uri) return;
	LspProject* proj = project_manager.get_or_create_project_for_uri(file_uri);
	String? h = hover::hover(proj, file_uri, params.position);
	LspHoverResponse resp = {
		.jsonrpc = message.rpc,
		.id = message.has_id ? message.id : -1,
		.result = {
			.contents = {
				.kind = MARKDOWN,
				.value = h ?? "",
			},
		}
	};
	io_handler::write(translator::encode(resp, tmem));
}

fn void on_definition(LspMessage* message, GoToDefinitionParams* params)
{
	Uri? file_uri = uri::parse(tmem, params.document.uri);
	if (catch file_uri) return;
	LspProject* proj = project_manager.get_or_create_project_for_uri(file_uri);
	LspLocation[]? defs = definition::goto_definition(proj, file_uri, params.position);
	LspGoToDefinitionResponse resp = {
		.jsonrpc = message.rpc,
		.id = message.has_id ? message.id : -1,
		.result = defs ?? {}
	};
	io_handler::write(translator::encode(resp, tmem));
}

fn void on_signature_help(LspMessage* message, SignatureHelpParams* params)
{
	Uri? file_uri = uri::parse(tmem, params.text_document.uri);
	if (catch file_uri) return;
	LspProject* proj = project_manager.get_or_create_project_for_uri(file_uri);
	SignatureHelpResult? help_res = signature_help::signature_help(proj, file_uri, params.position);
	LspSignatureHelpResponse resp = {
		.jsonrpc = message.rpc,
		.id = message.has_id ? message.id : -1,
		.result = help_res ??
		{
			.signatures = {}
		}
	};
	io_handler::write(translator::encode(resp, tmem));
}

fn void on_references(LspMessage* message, ReferenceParams* params)
{
	Uri? file_uri = uri::parse(tmem, params.text_document.uri);
	if (catch file_uri) return;
	LspProject* proj = project_manager.get_or_create_project_for_uri(file_uri);
	LspLocation[]? refs = references::find_references(proj, file_uri, params.position, params.context);
	LspReferencesResponse resp = {
		.jsonrpc = message.rpc,
		.id = message.has_id ? message.id : -1,
		.result = refs ?? {}
	};
	io_handler::write(translator::encode(resp, tmem));
}

fn void on_prepare_rename(LspMessage* message, PrepareRenameParams* params)
{
	Uri? file_uri = uri::parse(tmem, params.text_document.uri);
	if (catch file_uri) return;
	LspProject* proj = project_manager.get_or_create_project_for_uri(file_uri);
	LspRange? prep_res = rename::prepare_rename(proj, file_uri, params.position);
	if (catch prep_res)
	{
		LspShutdownResponse null_resp = {
			.jsonrpc = message.rpc,
			.id = message.has_id ? message.id : -1,
			.result = null
		};
		io_handler::write(translator::encode(null_resp, tmem));
		return;
	}
	LspPrepareRenameResponse resp = {
		.jsonrpc = message.rpc,
		.id = message.has_id ? message.id : -1,
		.result = prep_res
	};
	io_handler::write(translator::encode(resp, tmem));
}

fn void on_rename(LspMessage* message, RenameParams* params)
{
	Uri? file_uri = uri::parse(tmem, params.text_document.uri);
	if (catch file_uri) return;
	LspProject* proj = project_manager.get_or_create_project_for_uri(file_uri);
	WorkspaceEdit? edit_res = rename::rename(proj, file_uri, params.position, params.newName);
	LspRenameResponse resp = {
		.jsonrpc = message.rpc,
		.id = message.has_id ? message.id : -1,
		.result = edit_res ??
		{
			.documentChanges = {}
		}
	};
	io_handler::write(translator::encode(resp, tmem));
}

fn void on_semantic_tokens(LspMessage* message, SemanticTokensParams* params)
{
	Uri? file_uri = uri::parse(tmem, params.text_document.uri);
	if (catch file_uri) return;
	LspProject* proj = project_manager.get_or_create_project_for_uri(file_uri);
	SemanticTokensResult? tokens_res = semantic_tokens::compute_semantic_tokens(proj, file_uri);
	LspSemanticTokensResponse resp = {
		.jsonrpc = message.rpc,
		.id = message.has_id ? message.id : -1,
		.result = tokens_res ??
		{
			.data = {}
		}
	};
	io_handler::write(translator::encode(resp, tmem));
}

fn void on_document_symbol(LspMessage* message, DocumentSymbolParams* params)
{
	Uri? file_uri = uri::parse(tmem, params.text_document.uri);
	if (catch file_uri) return;
	LspProject* proj = project_manager.get_or_create_project_for_uri(file_uri);
	SymbolInformation[]? syms = symbols::get_document_symbols(proj, file_uri);
	LspDocumentSymbolResponse resp = {
		.jsonrpc = message.rpc,
		.id = message.has_id ? message.id : -1,
		.result = syms ?? {}
	};
	io_handler::write(translator::encode(resp, tmem));
}

fn void on_workspace_symbol(LspMessage* message, WorkspaceSymbolParams* params)
{
	List{SymbolInformation} all_syms;
	all_syms.tinit();
	if (try syms = symbols::query_workspace_symbols(&project_manager.default_project, params.query))
	{
		all_syms.push_all(syms);
	}
	project_manager.projects.@each(; root, proj)
	{
		if (try syms = symbols::query_workspace_symbols(proj, params.query))
		{
			all_syms.push_all(syms);
		}
	};
	LspWorkspaceSymbolResponse resp = {
		.jsonrpc = message.rpc,
		.id = message.has_id ? message.id : -1,
		.result = all_syms.to_tarray()
	};
	io_handler::write(translator::encode(resp, tmem));
}

fn void on_inlay_hint(LspMessage* message, InlayHintParams* params)
{
	Uri? file_uri = uri::parse(tmem, params.text_document.uri);
	if (catch file_uri) return;
	LspProject* proj = project_manager.get_or_create_project_for_uri(file_uri);
	InlayHint[]? hints = inlay_hints::get_inlay_hints(proj, file_uri, params.range);
	LspInlayHintResponse resp = {
		.jsonrpc = message.rpc,
		.id = message.has_id ? message.id : -1,
		.result = hints ?? {}
	};
	io_handler::write(translator::encode(resp, tmem));
}

fn void on_folding_range(LspMessage* message, FoldingRangeParams* params)
{
	Uri? file_uri = uri::parse(tmem, params.text_document.uri);
	if (catch file_uri) return;
	LspProject* proj = project_manager.get_or_create_project_for_uri(file_uri);
	FoldingRange[]? ranges = folding_ranges::get_folding_ranges(proj, file_uri);
	LspFoldingRangeResponse resp = {
		.jsonrpc = message.rpc,
		.id = message.has_id ? message.id : -1,
		.result = ranges ?? {}
	};
	io_handler::write(translator::encode(resp, tmem));
}

fn void on_formatting(LspMessage* message, DocumentFormattingParams* params)
{
	Uri? file_uri = uri::parse(tmem, params.text_document.uri);
	if (catch file_uri) return;
	LspProject* proj = project_manager.get_or_create_project_for_uri(file_uri);
	TextEdit[]? edits = formatting::format_document(proj, file_uri, params.options);
	LspFormattingResponse resp = {
		.jsonrpc = message.rpc,
		.id = message.has_id ? message.id : -1,
		.result = edits ?? {}
	};
	io_handler::write(translator::encode(resp, tmem));
}

fn void on_range_formatting(LspMessage* message, DocumentRangeFormattingParams* params)
{
	Uri? file_uri = uri::parse(tmem, params.text_document.uri);
	if (catch file_uri) return;
	LspProject* proj = project_manager.get_or_create_project_for_uri(file_uri);
	TextEdit[]? edits = formatting::format_range(proj, file_uri, params.range, params.options);
	LspFormattingResponse resp = {
		.jsonrpc = message.rpc,
		.id = message.has_id ? message.id : -1,
		.result = edits ?? {}
	};
	io_handler::write(translator::encode(resp, tmem));
}

fn void on_code_action(LspMessage* message, CodeActionParams* params)
{
	Uri? file_uri = uri::parse(tmem, params.text_document.uri);
	if (catch file_uri) return;
	LspProject* proj = project_manager.get_or_create_project_for_uri(file_uri);
	CodeAction[]? actions = code_actions::get_code_actions(proj, file_uri, *params);
	LspCodeActionResponse resp = {
		.jsonrpc = message.rpc,
		.id = message.has_id ? message.id : -1,
		.result = actions ?? {}
	};
	io_handler::write(translator::encode(resp, tmem));
}

fn void on_execute_command(LspMessage* message, ExecuteCommandParams* params)
{
	String cmd_name = params.command;
	if (cmd_name == code_actions::CMD_GENERATE_BINDINGS)
	{
		String[] args = params.arguments;
		if (args.len >= 3)
		{
			String header_path = args[0];
			String module_name = args[1];
			String output_path = args[2];

			sz last_slash = output_path.rindex_of_char('/') ?? output_path.rindex_of_char('\\') ?? (sz)0;
			if (last_slash > 0)
			{
				String dir = output_path[:last_slash];
				if (!file::exists(dir))
				{
					(void)path::mkdir(dir, recursive: true);
				}
			}

			bindgen::BindgenOptions opts = {
				.header_path = header_path,
				.output_path = output_path,
				.module_name = module_name,
				.type_prefix = "",
				.strip_func_prefix = "",
				.clang_path = "clang"
			};

			int run_res = bindgen::run_bindgen(opts, is_cli: false);
			if (run_res == 0)
			{
				Uri file_u = uri::from_file_path(tmem, output_path);
				DocumentUri out_uri = (DocumentUri)file_u.to_raw_string(tmem);
				LspProject* proj = project_manager.get_or_create_project_for_uri(file_u);
				proj.open_file({ .uri = out_uri }, from_disk: true);

				// Queue all open user documents for re-analysis so the new module clears diagnostics
				proj.files.@each(; path_key, lsp_f)
				{
					if (lsp_f && !lsp_f.is_library)
					{
						proj.process_queue.push({
							.source_text = lsp_f.text,
							.uri = lsp_f.uri.path,
							.path = lsp_f.uri.path,
							.is_library = false
						});
					}
				};

				proj.update();
			}
		}
	}

	LspExecuteCommandResponse resp = {
		.jsonrpc = message.rpc,
		.id = message.has_id ? message.id : -1,
		.result = null
	};
	io_handler::write(translator::encode(resp, tmem));
}

fn void on_did_change_watched(LspMessage* message, DidChangeWatchedFilesParams* params)
{
	foreach (ev : params.changes)
	{
		if (ev.type == 3) // FileChangeType.DELETED
		{
			LspProject* proj = get_project_for_raw_uri(ev.uri);
			proj.close_file(ev.uri);
			proj.files.@each(; path_key, lsp_f)
			{
				if (lsp_f && !lsp_f.is_library)
				{
					proj.process_queue.push({
						.source_text = lsp_f.text,
						.uri = lsp_f.uri.path,
						.path = lsp_f.uri.path,
						.is_library = false
					});
				}
			};
			proj.update();
		}
	}
}

<*
 True when `path` lies inside the stdlib directory.
*>
fn bool is_stdlib_file(String path)
{
	if (std_path.len == 0) return false;
	Path? root = path::tnew(std_path);
	if (catch root) return false;
	String r = (String)root;
	$if env::WIN32:
		// File keys use '/' (URI form) while normalized paths use '\\'.
		r = r.treplace("\\", "/");
		path = path.treplace("\\", "/");
	$endif
	return path.starts_with(r) && (path.len == r.len || path[r.len] == '/');
}

fn void setup_stdlib_path() => @pool()
{
	char[4096] buf;
	String comp = compiler_path.len > 0 ? compiler_path : "c3c";

	// stdlib path from `c3c compile --build-env`
	if (try out = process::run_capture_stdout(&buf, { comp, "compile", "--build-env" }))
	{
		foreach (line : out.trim().tsplit("\n"))
		{
			if (line.starts_with("Stdlib"))
			{
				if (try idx = (int)line.index_of(":"))
				{
					String raw_path = line[idx + 1..].trim().trim_right("/\\");
					if (raw_path.len > 0)
					{
						is_std_path_alloc = true;
						std_path = raw_path.copy(mem);
						log::info("Set std-lib path: %s", std_path);
						return;
					}
				}
			}
		}
	}

	// Fallback to `c3c --version`
	if (try out = process::run_capture_stdout(&buf, { comp, "--version" }))
	{
		String[] split_lines = out.trim().tsplit("\n");
		if (split_lines.len >= 2)
		{
			if (try idx = (int)split_lines[1].index_of(":"))
			{
				String raw_path = split_lines[1][idx + 1..].trim().trim_right("/\\");
				is_std_path_alloc = true;
				if (raw_path.ends_with("/lib") || raw_path.ends_with("/std"))
				{
					std_path = raw_path.copy(mem);
				}
				else
				{
					std_path = string::format(mem, "%s/lib", raw_path);
				}
				log::info("Set std-lib path: %s", std_path);
				return;
			}
		}
	}

	log::error("Failed to detect standard library path from %s", comp);
}