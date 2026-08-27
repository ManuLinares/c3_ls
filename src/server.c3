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
LspProject project;

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

fn void publish_diagnostics(FileInput[] processed_files, LspWorkspace* ws) => @pool()
{
	if (!ws) return;

	foreach (input_file : processed_files)
	{
		if (input_file.is_library) continue;

		String file_path = input_file.path;
		if (file_path.len == 0) file_path = input_file.uri;

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

		log::info("LogPath = %s", log_path);
		log::info("std_path = %s", std_path);
		log::info("compiler_path = %s", compiler_path);
		log::info("log_level = %s", log_level);

		io_handler::init();

		project.init(mem);
		defer project.free();

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

		logger::init();
		defer logger::close();

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
			project.update();
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
					config::load(&project, value[0], mem);
				}
				else if (try root_uri_str = message.params.initialize.root_uri.get() && root_uri_str.len > 0)
				{
					WorkspaceFolder wf = {.uri = root_uri_str,.name = "" };
					config::load(&project, wf, mem);
				}
			}

		case INITIALIZED:
			log::info("received Initialized");
			is_ready = true;
			project.initial_process();

		case DID_OPEN:
			project.open_file(message.params.did_open.document);

		case DID_CHANGE:
			project.change_file(message.params.did_change);

		case DID_CLOSE:
			project.close_file(message.params.did_close.document.uri);

		case COMPLETION:
			{
				Uri? file_uri = uri::parse(tmem, message.params.completion.text_document.uri);
				if (catch file_uri) return;
				CompletionItem[]? items = completion::resolve(&project, file_uri, message.params.completion.position);
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
				completion::resolve_item(&project, &item);
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
				String? h = hover::hover(&project, file_uri, message.params.hover.position);
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
				LspLocation[]? defs = goto_definition::goto_definition(&project, file_uri, message.params.definition.position);
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
				SignatureHelpResult? help_res = signature_help::signature_help(&project, file_uri, message.params.signature_help.position);
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
				LspLocation[]? refs = references::find_references(&project, file_uri, message.params.references.position, message.params.references.context);
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
				LspRange? prep_res = rename::prepare_rename(&project, file_uri, message.params.prepare_rename.position);
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
				WorkspaceEdit? edit_res = rename::rename(&project, file_uri, message.params.rename.position, message.params.rename.newName);
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
				SemanticTokensResult? tokens_res = semantic_tokens::compute_semantic_tokens(&project, file_uri);
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
				SymbolInformation[]? syms = document_symbols::get_document_symbols(&project, file_uri);
				LspDocumentSymbolResponse resp = {
					.jsonrpc = message.rpc,
					.id = message.has_id ? message.id : -1,
					.result = syms ?? {}
				};
				io_handler::write(translator::encode(resp, tmem));
			}

		case WS_SYMBOL:
			{
				SymbolInformation[]? syms = workspace_symbols::query_workspace_symbols(&project, message.params.workspace_symbol.query);
				LspWorkspaceSymbolResponse resp = {
					.jsonrpc = message.rpc,
					.id = message.has_id ? message.id : -1,
					.result = syms ?? {}
				};
				io_handler::write(translator::encode(resp, tmem));
			}

		case INLAY_HINT:
			{
				Uri? file_uri = uri::parse(tmem, message.params.inlay_hint.text_document.uri);
				if (catch file_uri) return;
				InlayHint[]? hints = inlay_hints::get_inlay_hints(&project, file_uri, message.params.inlay_hint.range);
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
				FoldingRange[]? ranges = folding_ranges::get_folding_ranges(&project, file_uri);
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
				TextEdit[]? edits = formatting::format_document(&project, file_uri, message.params.formatting.options);
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
				TextEdit[]? edits = formatting::format_range(&project, file_uri, message.params.range_formatting.range, message.params.range_formatting.options);
				LspFormattingResponse resp = {
					.jsonrpc = message.rpc,
					.id = message.has_id ? message.id : -1,
					.result = edits ?? {}
				};
				io_handler::write(translator::encode(resp, tmem));
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
	Process? process = process::spawn(
	{
		compiler_path, "--version"
	}
	);
	if (catch err = process)
	{
		log::error("failed to get compiler version: %s", err);
		return;
	}

	const BUF_SIZE = 4096;
	char[BUF_SIZE] stdout_buf;
	char[BUF_SIZE] stderr_buf;

	if (catch process.join())
	{
		log::error("Failed to join 'c3c_stdlib' process");
		return;
	}

	String result;

	if (try long len = process.read_stdout(&stdout_buf, BUF_SIZE))
	{
		result = (String)stdout_buf[:len];
	}

	if (try long len = process.read_stderr(&stderr_buf, BUF_SIZE))
	{
		log::error((String)stderr_buf[:len]);
	}

	String line = result.trim();
	String[] split_lines = line.tsplit("\n");
	if (split_lines.len < 2) return;

	line = split_lines[1];
	int? index = (int)line.index_of(":");
	if (catch index) return;

	String raw_path = line[index + 1..].trim().trim_right("/\\");
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
}
