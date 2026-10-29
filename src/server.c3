module lsp::server;

import lsp::io_handler;
import lsp::analysis;
import lsp::analysis::hover;
import lsp::analysis::goto_definition;
import lsp::analysis::completion;
import lsp::analysis::signature_help;
import lsp::analysis::references;
import lsp::analysis::rename;
import lsp::analysis::semantic_tokens;
import lsp::analysis::document_symbols;
import lsp::analysis::workspace_symbols;
import lsp::analysis::inlay_hints;
import lsp::analysis::folding_ranges;
import lsp::analysis::formatting;
import lsp::analysis::code_actions;
import lsp::bindgen;
import lsp::translator;
import lsp::core::config;
import lsp::core::logger;
import lsp;

import std::io;
import std::core::log;
import std::thread;
import std::time;
import uri;
import std::os::process;
import std::collections::object;
import std::collections::list;

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
		case INITIALIZE:
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

				if (try init_opts = message.params.initialize.initialization_options.get())
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

				if (try value = message.params.initialize.trace.get())
				{
					if (value == VERBOSE) log::set_priority_all(VERBOSE);
				}
				if (try value = message.params.initialize.workspace_folders.get() && value.len > 0)
				{
					foreach (wf : value)
					{
						project_manager.add_workspace_folder(wf);
					}
				}
				else if (try root_uri_str = message.params.initialize.root_uri.get() && root_uri_str.len > 0)
				{
					WorkspaceFolder wf = {.uri = root_uri_str,.name = "" };
					project_manager.add_workspace_folder(wf);
				}
			}

		case INITIALIZED:
			log::info("received Initialized");
			is_ready = true;
			project_manager.initial_process_all();

		case DID_OPEN:
			{
				LspProject* proj = get_project_for_raw_uri(message.params.did_open.document.uri);
				proj.open_file(message.params.did_open.document);
			}

		case DID_CHANGE:
			{
				LspProject* proj = get_project_for_raw_uri(message.params.did_change.document.uri);
				proj.change_file(message.params.did_change);
			}

		case DID_CLOSE:
			{
				LspProject* proj = get_project_for_raw_uri(message.params.did_close.document.uri);
				proj.close_document(message.params.did_close.document.uri);
			}

		case DID_SAVE:
			{
				LspProject* proj = get_project_for_raw_uri(message.params.did_save.document.uri);
				proj.save_file(message.params.did_save.document.uri);
			}

		case COMPLETION:
			{
				Uri? file_uri = uri::parse(tmem, message.params.completion.text_document.uri);
				if (catch file_uri) return;
				LspProject* proj = project_manager.get_or_create_project_for_uri(file_uri);
				CompletionItem[]? items = completion::resolve(proj, file_uri, message.params.completion.position);
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

		case COMPLETION_RESOLVE:
			{
				CompletionItem item = message.params.completion_resolve.item;
				completion::resolve_item(project_manager.get_active_project(), &item);
				LspCompletionResolveResponse res = {
					.jsonrpc = message.rpc,
					.id = message.has_id ? message.id : -1,
					.result = item
				};
				io_handler::write(translator::encode(res, tmem));
			}

		case HOVER:
			{
				Uri? file_uri = uri::parse(tmem, message.params.hover.document.uri);
				if (catch file_uri) return;
				LspProject* proj = project_manager.get_or_create_project_for_uri(file_uri);
				String? h = hover::hover(proj, file_uri, message.params.hover.position);
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

		case DEFINITION:
			{
				Uri? file_uri = uri::parse(tmem, message.params.definition.document.uri);
				if (catch file_uri) return;
				LspProject* proj = project_manager.get_or_create_project_for_uri(file_uri);
				LspLocation[]? defs = goto_definition::goto_definition(proj, file_uri, message.params.definition.position);
				LspGoToDefinitionResponse resp = {
					.jsonrpc = message.rpc,
					.id = message.has_id ? message.id : -1,
					.result = defs ?? {}
				};
				io_handler::write(translator::encode(resp, tmem));
			}

		case HELP:
			{
				Uri? file_uri = uri::parse(tmem, message.params.signature_help.text_document.uri);
				if (catch file_uri) return;
				LspProject* proj = project_manager.get_or_create_project_for_uri(file_uri);
				SignatureHelpResult? help_res = signature_help::signature_help(proj, file_uri, message.params.signature_help.position);
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

		case REFERENCES:
			{
				Uri? file_uri = uri::parse(tmem, message.params.references.text_document.uri);
				if (catch file_uri) return;
				LspProject* proj = project_manager.get_or_create_project_for_uri(file_uri);
				LspLocation[]? refs = references::find_references(proj, file_uri, message.params.references.position, message.params.references.context);
				LspReferencesResponse resp = {
					.jsonrpc = message.rpc,
					.id = message.has_id ? message.id : -1,
					.result = refs ?? {}
				};
				io_handler::write(translator::encode(resp, tmem));
			}

		case PREPARE_RENAME:
			{
				Uri? file_uri = uri::parse(tmem, message.params.prepare_rename.text_document.uri);
				if (catch file_uri) return;
				LspProject* proj = project_manager.get_or_create_project_for_uri(file_uri);
				LspRange? prep_res = rename::prepare_rename(proj, file_uri, message.params.prepare_rename.position);
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

		case RENAME:
			{
				Uri? file_uri = uri::parse(tmem, message.params.rename.text_document.uri);
				if (catch file_uri) return;
				LspProject* proj = project_manager.get_or_create_project_for_uri(file_uri);
				WorkspaceEdit? edit_res = rename::rename(proj, file_uri, message.params.rename.position, message.params.rename.newName);
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

		case FULL:
			{
				Uri? file_uri = uri::parse(tmem, message.params.semantic_tokens.text_document.uri);
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

		case SYMBOL:
			{
				Uri? file_uri = uri::parse(tmem, message.params.document_symbol.text_document.uri);
				if (catch file_uri) return;
				LspProject* proj = project_manager.get_or_create_project_for_uri(file_uri);
				SymbolInformation[]? syms = document_symbols::get_document_symbols(proj, file_uri);
				LspDocumentSymbolResponse resp = {
					.jsonrpc = message.rpc,
					.id = message.has_id ? message.id : -1,
					.result = syms ?? {}
				};
				io_handler::write(translator::encode(resp, tmem));
			}

		case WS_SYMBOL:
			{
				List{SymbolInformation} all_syms;
				all_syms.tinit();
				if (try syms = workspace_symbols::query_workspace_symbols(&project_manager.default_project, message.params.workspace_symbol.query))
				{
					all_syms.push_all(syms);
				}
				project_manager.projects.@each(; root, proj)
				{
					if (try syms = workspace_symbols::query_workspace_symbols(proj, message.params.workspace_symbol.query))
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

		case INLAY_HINT:
			{
				Uri? file_uri = uri::parse(tmem, message.params.inlay_hint.text_document.uri);
				if (catch file_uri) return;
				LspProject* proj = project_manager.get_or_create_project_for_uri(file_uri);
				InlayHint[]? hints = inlay_hints::get_inlay_hints(proj, file_uri, message.params.inlay_hint.range);
				LspInlayHintResponse resp = {
					.jsonrpc = message.rpc,
					.id = message.has_id ? message.id : -1,
					.result = hints ?? {}
				};
				io_handler::write(translator::encode(resp, tmem));
			}

		case FOLDING_RANGE:
			{
				Uri? file_uri = uri::parse(tmem, message.params.folding_range.text_document.uri);
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

		case FORMATTING:
			{
				Uri? file_uri = uri::parse(tmem, message.params.formatting.text_document.uri);
				if (catch file_uri) return;
				LspProject* proj = project_manager.get_or_create_project_for_uri(file_uri);
				TextEdit[]? edits = formatting::format_document(proj, file_uri, message.params.formatting.options);
				LspFormattingResponse resp = {
					.jsonrpc = message.rpc,
					.id = message.has_id ? message.id : -1,
					.result = edits ?? {}
				};
				io_handler::write(translator::encode(resp, tmem));
			}

		case RANGE_FORMATTING:
			{
				Uri? file_uri = uri::parse(tmem, message.params.range_formatting.text_document.uri);
				if (catch file_uri) return;
				LspProject* proj = project_manager.get_or_create_project_for_uri(file_uri);
				TextEdit[]? edits = formatting::format_range(proj, file_uri, message.params.range_formatting.range, message.params.range_formatting.options);
				LspFormattingResponse resp = {
					.jsonrpc = message.rpc,
					.id = message.has_id ? message.id : -1,
					.result = edits ?? {}
				};
				io_handler::write(translator::encode(resp, tmem));
			}

		case CODE_ACTION:
			{
				Uri? file_uri = uri::parse(tmem, message.params.code_action.text_document.uri);
				if (catch file_uri) return;
				LspProject* proj = project_manager.get_or_create_project_for_uri(file_uri);
				CodeAction[]? actions = code_actions::get_code_actions(proj, file_uri, message.params.code_action);
				LspCodeActionResponse resp = {
					.jsonrpc = message.rpc,
					.id = message.has_id ? message.id : -1,
					.result = actions ?? {}
				};
				io_handler::write(translator::encode(resp, tmem));
			}

		case WS_EXECUTE_COMMAND:
			{
				String cmd_name = message.params.execute_command.command;
				if (cmd_name == code_actions::CMD_GENERATE_BINDINGS)
				{
					String[] args = message.params.execute_command.arguments;
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

		case WS_CHANGE_WATCHED:
			{
				foreach (ev : message.params.did_change_watched.changes)
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

		case SET_TRACE:
			break;

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

		default:
			log::verbose("Unhandled LSP method: %s", message.method);
	}
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