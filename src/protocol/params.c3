module lsp;

import std::collections::object;
import std::collections::ref;
import std::encoding::json;
import uri;

enum MessageKind : char (String name, typeid params)
{
	UNKNOWN             { "unknown", void },
	INITIALIZE          { "initialize", InitializeParams },
	INITIALIZED         { "initialized", void },
	DID_OPEN            { "textDocument/didOpen", DidOpenParams },
	DID_CHANGE          { "textDocument/didChange", DidChangeParams },
	DID_CLOSE           { "textDocument/didClose", DidCloseParams },
	DID_SAVE            { "textDocument/didSave", DidSaveParams },
	FULL                { "textDocument/semanticTokens/full", SemanticTokensParams },
	SYMBOL              { "textDocument/documentSymbol", DocumentSymbolParams },
	HOVER               { "textDocument/hover", HoverParams },
	COMPLETION          { "textDocument/completion", CompletionParams },
	DEFINITION          { "textDocument/definition", GoToDefinitionParams },
	DECLERATION         { "textDocument/declaration", void },
	REFERENCES          { "textDocument/references", ReferenceParams },
	HELP                { "textDocument/signatureHelp", SignatureHelpParams },
	RENAME              { "textDocument/rename", RenameParams },
	PREPARE_RENAME      { "textDocument/prepareRename", PrepareRenameParams },
	WILL_SAVE           { "textDocument/willSave", void },
	WILL_SAVE_WAIT      { "textDocument/willSaveWaitUntil", void },
	FORMATTING          { "textDocument/formatting", DocumentFormattingParams },
	RANGE_FORMATTING    { "textDocument/rangeFormatting", DocumentRangeFormattingParams },
	ON_TYPE_FORMAT      { "textDocument/onTypeFormatting", void },
	CODE_ACTION         { "textDocument/codeAction", CodeActionParams },
	CODE_LENS           { "textDocument/codeLens", void },
	CODE_LENS_RESOLVE   { "textDocument/codeLens/resolve", void },
	FOLDING_RANGE       { "textDocument/foldingRange", FoldingRangeParams },
	SELECTION_RANGE     { "textDocument/selectionRange", void },
	TYPE_DEFINITION     { "textDocument/typeDefinition", void },
	IMPLEMENTATION      { "textDocument/implementation", void },
	INLAY_HINT          { "textDocument/inlayHint", InlayHintParams },
	INLAY_HINT_RESOLVE  { "textDocument/inlayHint/resolve", void },
	DIAGNOSTIC          { "textDocument/diagnostic", void },
	SEM_TOKENS_RANGE    { "textDocument/semanticTokens/range", void },
	SEM_TOKENS_DELTA    { "textDocument/semanticTokens/full/delta", void },
	PREPARE_CALL_HIER   { "textDocument/prepareCallHierarchy", void },
	LINKED_EDITING      { "textDocument/linkedEditingRange", void },
	MONIKER             { "textDocument/moniker", void },

	PUB_DIAG            { "textDocument/publishDiagnostics", void },

	SHOW_MESSAGE        { "window/showMessage", void },
	LOG_MESSAGE         { "window/logMessage", void },
	SHOW_MSG_REQUEST    { "window/showMessageRequest", void },
	SHOW_DOCUMENT       { "window/showDocument", void },
	WDP_CREATE          { "window/workDoneProgress/create", void },
	WDP_CANCEL          { "window/workDoneProgress/cancel", void },

	WS_CHANGE_CONFIG    { "workspace/didChangeConfiguration", void },
	WS_CHANGE_WATCHED   { "workspace/didChangeWatchedFiles", DidChangeWatchedFilesParams },
	WS_CHANGE_FOLDERS   { "workspace/didChangeWorkspaceFolders", void },
	WS_SYMBOL           { "workspace/symbol", WorkspaceSymbolParams },
	WS_EXECUTE_COMMAND  { "workspace/executeCommand", ExecuteCommandParams },
	WS_APPLY_EDIT       { "workspace/applyEdit", void },
	WS_CONFIGURATION    { "workspace/configuration", void },
	WS_DIAGNOSTIC       { "workspace/diagnostic", void },
	WS_DIAG_REFRESH     { "workspace/diagnostic/refresh", void },
	WS_SEM_REFRESH      { "workspace/semanticTokens/refresh", void },
	WS_CODELENS_REFRESH { "workspace/codeLens/refresh", void },
	WS_INLAY_REFRESH    { "workspace/inlayHint/refresh", void },

	CALL_INCOMING    { "callHierarchy/incomingCalls", void },
	CALL_OUTGOING    { "callHierarchy/outgoingCalls", void },
	TYPE_SUPERTYPES  { "typeHierarchy/supertypes", void },
	TYPE_SUBTYPES    { "typeHierarchy/subtypes", void },

	COMPLETION_RESOLVE { "completionItem/resolve", CompletionItem },

	SHUTDOWN     { "shutdown", void },
	EXIT         { "exit", void },
	CANCEL       { "$/cancelRequest", void },
	SET_TRACE    { "$/setTrace", void },
	PROGRESS     { "$/progress", void },
	LOG_TRACE    { "$/logTrace", void },
}

fn MessageKind message_kind_from_string(String s)
{
	$foreach $val : MessageKind::values:
		if (s == $val.name) return $val;
	$endforeach
	return UNKNOWN;
}

struct ClientInfo
{
	String name;
	String version;
}

struct InitializationOptions
{
	String compiler_path;
	String stdlib_path;
}

struct InitializeParams
{
	Nullable{int} process_id @Json("processId");
	ClientInfo client_info @Json("clientInfo");
	String locale;
	DocumentUri root_uri @Json("rootUri");
	String root_path @Json("rootPath");
	TraceKind trace;
	WorkspaceFolder[] workspace_folders @Json("workspaceFolders");
	Object* initialization_options @Json("initializationOptions");
}

<*
 The workspace root: `rootUri`, or else the deprecated `rootPath` as a URI.
*>
fn DocumentUri InitializeParams.root(&self, Allocator allocator)
{
	if (self.root_uri.len > 0 || self.root_path.len == 0) return self.root_uri;
	return (DocumentUri)uri::from_file_path(allocator, self.root_path).to_raw_string(allocator);
}

<*
 Compiler and stdlib paths from `initializationOptions`, under any of the key spellings clients use.
*>
fn InitializationOptions InitializeParams.options(&self)
{
	Object* opts = self.initialization_options;
	if (!opts || !opts.is_map()) return {};
	return {
		.compiler_path = opts.get_string("compiler-path") ?? opts.get_string("compilerPath") ?? opts.get_string("compiler_path") ?? "",
		.stdlib_path = opts.get_string("stdlib-path") ?? opts.get_string("stdlibPath") ?? opts.get_string("stdlib_path") ?? "",
	};
}

struct DidOpenParams
{
	TextDocumentItem document @Json("textDocument");
}

struct TextDocumentIdentifier
{
	DocumentUri uri;
}

struct DidCloseParams
{
	TextDocumentIdentifier document @Json("textDocument");
}

struct DidSaveParams
{
	TextDocumentIdentifier document @Json("textDocument");
}

struct HoverParams
{
	TextDocumentIdentifier document @Json("textDocument");
	LspPosition position;
}

struct GoToDefinitionParams
{
	TextDocumentIdentifier document @Json("textDocument");
	LspPosition position;
}

struct SignatureHelpParams
{
	TextDocumentIdentifier text_document @Json("textDocument");
	LspPosition position;
}

struct ReferenceContext
{
	bool includeDeclaration;
}

struct ReferenceParams
{
	TextDocumentIdentifier text_document @Json("textDocument");
	LspPosition position;
	ReferenceContext context;
}

struct PrepareRenameParams
{
	TextDocumentIdentifier text_document @Json("textDocument");
	LspPosition position;
}

struct RenameParams
{
	TextDocumentIdentifier text_document @Json("textDocument");
	LspPosition position;
	String newName;
}

struct SemanticTokensParams
{
	TextDocumentIdentifier text_document @Json("textDocument");
}

struct CompletionTextDocument
{
	String uri;
}

struct CompletionParams
{
	CompletionTextDocument text_document @Json("textDocument");
	LspPosition position;
	CompletionContext context;
}

constdef MessageSeverityConst : int
{
	ERROR   = 1,
	WARNING = 2,
	INFO    = 3,
	HINT    = 4,
}

struct LspDiagnostic
{
	LspRange range;
	int severity;
	String message;
	String source;
}

struct PublishDiagnosticsParams
{
	DocumentUri uri;
	int version;
	bool has_version;
	LspDiagnostic[] diagnostics;
}

struct CancelParams
{
	int id;
}

struct SetTraceParams
{
	TraceKind value;
}

struct TextDocumentContentChangeEvent
{
	LspRange range;
	uint range_length @Json("rangeLength");
	String text;
}

struct DidChangeParams
{
	VersionedTextDocumentIdentifier document @Json("textDocument");
	TextDocumentContentChangeEvent[] content_changes @Json("contentChanges");
}

struct LogMessageParams
{
	int type;
	String message;
}

union MessageParams
{
	InitializeParams initialize;
	DidOpenParams did_open;
	DidChangeParams did_change;
	DidCloseParams did_close;
	DidSaveParams did_save;
	HoverParams hover;
	CompletionParams completion;
	CompletionItem completion_resolve;
	GoToDefinitionParams definition;
	SignatureHelpParams signature_help;
	ReferenceParams references;
	PrepareRenameParams prepare_rename;
	RenameParams rename;
	SemanticTokensParams semantic_tokens;
	DocumentSymbolParams document_symbol;
	WorkspaceSymbolParams workspace_symbol;
	InlayHintParams inlay_hint;
	FoldingRangeParams folding_range;
	DocumentFormattingParams formatting;
	DocumentRangeFormattingParams range_formatting;
	CodeActionParams code_action;
	ExecuteCommandParams execute_command;

	PublishDiagnosticsParams pub_diag;
	LogMessageParams log_message;

	CancelParams cancel;
	SetTraceParams set_trace;

	DidChangeWatchedFilesParams did_change_watched;
}

struct FormattingOptions
{
	uint tab_size @Json("tabSize");
	bool insert_spaces @Json("insertSpaces");
	bool trim_trailing_whitespace @Json("trimTrailingWhitespace");
	bool insert_final_newline @Json("insertFinalNewline");
	bool trim_final_newlines @Json("trimFinalNewlines");
}

struct DocumentFormattingParams
{
	TextDocumentIdentifier text_document @Json("textDocument");
	FormattingOptions options;
}

struct DocumentRangeFormattingParams
{
	TextDocumentIdentifier text_document @Json("textDocument");
	LspRange range;
	FormattingOptions options;
}