module lsp::server;

import lsp, uri, std::io, std::thread, std::time, std::os::process, std::collections::object, std::collections::list;

bool is_ready;
bool cli_std_path_set;
bool cli_compiler_path_set;
bool running @local;
LogLevel log_level;
String log_path;
String std_path;
String compiler_path;
ProjectManager project_manager;

<*
 Replaces `std_path` with a heap copy of `path` without trailing separators; an empty `path` clears it.
*>
fn void set_std_path(String path)
{
	path = path.trim_right("/\\");
	String old = std_path;
	std_path = path.len > 0 ? path.copy(mem) : {};
	alloc::free(mem, old.ptr);
}

<*
 Replaces `compiler_path` with a heap copy of `path`; an empty `path` clears it.
*>
fn void set_compiler_path(String path)
{
	String old = compiler_path;
	compiler_path = path.len > 0 ? path.copy(mem) : {};
	alloc::free(mem, old.ptr);
}

struct Document
{
	Uri uri;
	LspProject* project;
}

<*
 Parses `raw_uri` and finds or creates the project owning it.
 @return? builtin::NOT_FOUND : "`raw_uri` is not a valid uri"
*>
fn Document? open_document(String raw_uri)
{
	Uri u = uri::parse(tmem, raw_uri)!;
	return { u, project_manager.get_or_create_project_for_uri(u) };
}

fn LspProject* get_project_for_raw_uri(String raw_uri)
{
	Uri? u = uri::parse(tmem, raw_uri);
	if (catch u) return &project_manager.default_project;
	return project_manager.get_or_create_project_for_uri(u);
}

struct LspResponse <Result>
{
	String jsonrpc;
	int id;
	Result result;
}

<*
 Writes the JSON-RPC response to `message` carrying `result`.
*>
fn void respond(LspMessage* message, Result result) <Result>
{
	LspResponse{Result} resp = {
		.jsonrpc = message.rpc,
		.id = message.has_id ? message.id : -1,
		.result = result,
	};
	io_handler::write(translator::encode(resp, tmem));
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

struct HoverResult
{
	MarkupContent contents;
}

struct CompletionResult
{
	bool isIncomplete;
	CompletionItem[] items;
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
		set_std_path(args.stdlib_path);
		set_compiler_path(args.compiler_path.len > 0 ? args.compiler_path : "c3c");
		defer
		{
			set_std_path("");
			set_compiler_path("");
		};
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

		if (std_path.len == 0) setup_stdlib_path();

		cli_std_path_set = args.stdlib_path.len > 0;
		cli_compiler_path_set = args.compiler_path.len > 0;

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

<*
 Handles `message`. A failed request is logged and answered with a null result, so the client stops waiting.
*>
fn void dispatch(LspMessage* message)
{
	if (catch err = route(message))
	{
		log::error("%s failed: %s", message.method, err);
		if (message.has_id) respond{Object*}(message, null);
	}
}

fn void? route(LspMessage* message) @local
{
	switch (message.method)
	{
		case INITIALIZE: on_initialize(message, &message.params.initialize)!;
		case INITIALIZED:
			log::info("received Initialized");
			is_ready = true;
			project_manager.initial_process_all();
		case DID_OPEN: on_did_open(message, &message.params.did_open)!;
		case DID_CHANGE: on_did_change(message, &message.params.did_change)!;
		case DID_CLOSE: on_did_close(message, &message.params.did_close)!;
		case DID_SAVE: on_did_save(message, &message.params.did_save)!;
		case FULL: on_semantic_tokens(message, &message.params.semantic_tokens)!;
		case SYMBOL: on_document_symbol(message, &message.params.document_symbol)!;
		case HOVER: on_hover(message, &message.params.hover)!;
		case COMPLETION: on_completion(message, &message.params.completion)!;
		case DEFINITION: on_definition(message, &message.params.definition)!;
		case REFERENCES: on_references(message, &message.params.references)!;
		case HELP: on_signature_help(message, &message.params.signature_help)!;
		case RENAME: on_rename(message, &message.params.rename)!;
		case PREPARE_RENAME: on_prepare_rename(message, &message.params.prepare_rename)!;
		case FORMATTING: on_formatting(message, &message.params.formatting)!;
		case RANGE_FORMATTING: on_range_formatting(message, &message.params.range_formatting)!;
		case CODE_ACTION: on_code_action(message, &message.params.code_action)!;
		case FOLDING_RANGE: on_folding_range(message, &message.params.folding_range)!;
		case INLAY_HINT: on_inlay_hint(message, &message.params.inlay_hint)!;
		case WS_CHANGE_WATCHED: on_did_change_watched(message, &message.params.did_change_watched)!;
		case WS_SYMBOL: on_workspace_symbol(message, &message.params.workspace_symbol)!;
		case WS_EXECUTE_COMMAND: on_execute_command(message, &message.params.execute_command)!;
		case COMPLETION_RESOLVE: on_completion_resolve(message, &message.params.completion_resolve)!;
		case SHUTDOWN: respond{Object*}(message, null);
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

fn void? on_initialize(LspMessage* message, InitializeParams* params)
{
	respond{InitializeResult}(message, {
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
	});

	InitializationOptions init_opts = params.options();
	{
		if (!cli_compiler_path_set && init_opts.compiler_path.len > 0)
		{
			set_compiler_path(init_opts.compiler_path);
			log::info("Updated compiler_path from initializationOptions: %s", compiler_path);
			if (!cli_std_path_set && init_opts.stdlib_path.len == 0) setup_stdlib_path();
		}
		if (!cli_std_path_set && init_opts.stdlib_path.len > 0)
		{
			set_std_path(init_opts.stdlib_path);
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

fn void? on_did_open(LspMessage* message, DidOpenParams* params)
{
	LspProject* proj = get_project_for_raw_uri(params.document.uri);
	proj.open_file(params.document);
}

fn void? on_did_change(LspMessage* message, DidChangeParams* params)
{
	LspProject* proj = get_project_for_raw_uri(params.document.uri);
	proj.change_file(*params);
}

fn void? on_did_close(LspMessage* message, DidCloseParams* params)
{
	LspProject* proj = get_project_for_raw_uri(params.document.uri);
	proj.close_document(params.document.uri);
}

fn void? on_did_save(LspMessage* message, DidSaveParams* params)
{
	LspProject* proj = get_project_for_raw_uri(params.document.uri);
	proj.save_file(params.document.uri);
}

fn void? on_completion(LspMessage* message, CompletionParams* params)
{
	Document doc = open_document(params.text_document.uri)!;
	CompletionItem[]? items = completion::resolve(doc.project, doc.uri, params.position);
	respond{CompletionResult}(message, {
		.isIncomplete = true,
		.items = items ?? {},
	});
}

fn void? on_completion_resolve(LspMessage* message, CompletionItem* params)
{
	CompletionItem item = *params;
	completion::resolve_item(project_manager.get_active_project(), &item);
	respond{CompletionItem}(message, item);
}

fn void? on_hover(LspMessage* message, HoverParams* params)
{
	Document doc = open_document(params.document.uri)!;
	String? h = hover::hover(doc.project, doc.uri, params.position);
	respond{HoverResult}(message, {
		.contents = {
			.kind = MARKDOWN,
			.value = h ?? "",
		},
	});
}

fn void? on_definition(LspMessage* message, GoToDefinitionParams* params)
{
	Document doc = open_document(params.document.uri)!;
	LspLocation[]? defs = definition::goto_definition(doc.project, doc.uri, params.position);
	respond{LspLocation[]}(message, defs ?? {});
}

fn void? on_signature_help(LspMessage* message, SignatureHelpParams* params)
{
	Document doc = open_document(params.text_document.uri)!;
	SignatureHelpResult? help_res = signature_help::signature_help(doc.project, doc.uri, params.position);
	respond{SignatureHelpResult}(message, help_res ?? { .signatures = {} });
}

fn void? on_references(LspMessage* message, ReferenceParams* params)
{
	Document doc = open_document(params.text_document.uri)!;
	LspLocation[]? refs = references::find_references(doc.project, doc.uri, params.position, params.context);
	respond{LspLocation[]}(message, refs ?? {});
}

fn void? on_prepare_rename(LspMessage* message, PrepareRenameParams* params)
{
	Document doc = open_document(params.text_document.uri)!;
	LspRange? prep_res = rename::prepare_rename(doc.project, doc.uri, params.position);
	if (catch prep_res)
	{
		respond{Object*}(message, null);
		return;
	}
	respond{LspRange}(message, prep_res);
}

fn void? on_rename(LspMessage* message, RenameParams* params)
{
	Document doc = open_document(params.text_document.uri)!;
	WorkspaceEdit? edit_res = rename::rename(doc.project, doc.uri, params.position, params.newName);
	respond{WorkspaceEdit}(message, edit_res ?? { .documentChanges = {} });
}

fn void? on_semantic_tokens(LspMessage* message, SemanticTokensParams* params)
{
	Document doc = open_document(params.text_document.uri)!;
	SemanticTokensResult? tokens_res = semantic_tokens::compute_semantic_tokens(doc.project, doc.uri);
	respond{SemanticTokensResult}(message, tokens_res ?? { .data = {} });
}

fn void? on_document_symbol(LspMessage* message, DocumentSymbolParams* params)
{
	Document doc = open_document(params.text_document.uri)!;
	SymbolInformation[]? syms = symbols::get_document_symbols(doc.project, doc.uri);
	respond{SymbolInformation[]}(message, syms ?? {});
}

fn void? on_workspace_symbol(LspMessage* message, WorkspaceSymbolParams* params)
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
	respond{SymbolInformation[]}(message, all_syms.to_tarray());
}

fn void? on_inlay_hint(LspMessage* message, InlayHintParams* params)
{
	Document doc = open_document(params.text_document.uri)!;
	InlayHint[]? hints = inlay_hints::get_inlay_hints(doc.project, doc.uri, params.range);
	respond{InlayHint[]}(message, hints ?? {});
}

fn void? on_folding_range(LspMessage* message, FoldingRangeParams* params)
{
	Document doc = open_document(params.text_document.uri)!;
	FoldingRange[]? ranges = folding_ranges::get_folding_ranges(doc.project, doc.uri);
	respond{FoldingRange[]}(message, ranges ?? {});
}

fn void? on_formatting(LspMessage* message, DocumentFormattingParams* params)
{
	Document doc = open_document(params.text_document.uri)!;
	TextEdit[]? edits = formatting::format_document(doc.project, doc.uri, params.options);
	respond{TextEdit[]}(message, edits ?? {});
}

fn void? on_range_formatting(LspMessage* message, DocumentRangeFormattingParams* params)
{
	Document doc = open_document(params.text_document.uri)!;
	TextEdit[]? edits = formatting::format_range(doc.project, doc.uri, params.range, params.options);
	respond{TextEdit[]}(message, edits ?? {});
}

fn void? on_code_action(LspMessage* message, CodeActionParams* params)
{
	Document doc = open_document(params.text_document.uri)!;
	CodeAction[]? actions = code_actions::get_code_actions(doc.project, doc.uri, *params);
	respond{CodeAction[]}(message, actions ?? {});
}

fn void? on_execute_command(LspMessage* message, ExecuteCommandParams* params)
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

	respond{Object*}(message, null);
}

fn void? on_did_change_watched(LspMessage* message, DidChangeWatchedFilesParams* params)
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
	String r = uri::normalize_path(tmem, (String)root);
	path = uri::normalize_path(tmem, path);
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
						set_std_path(raw_path);
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
				set_std_path(raw_path.ends_with("/lib") || raw_path.ends_with("/std") ? raw_path : string::tformat("%s/lib", raw_path));
				log::info("Set std-lib path: %s", std_path);
				return;
			}
		}
	}

	log::error("Failed to detect standard library path from %s", comp);
}