module lsp;

import std::collections::object;
import std::collections::ref;
import std::encoding::json;
import uri;

enum MessageKind : char (String name, bool has_params)
{
	UNKNOWN      { "unknown", false },
	INITIALIZE   { "initialize", true },
	INITIALIZED  { "initialized", false },
	DID_OPEN     { "textDocument/didOpen", true },
	DID_CHANGE   { "textDocument/didChange", true },
	DID_CLOSE    { "textDocument/didClose", true },
	DID_SAVE     { "textDocument/didSave", true },
	FULL         { "textDocument/semanticTokens/full", true },
	SYMBOL       { "textDocument/documentSymbol", true },
	HOVER        { "textDocument/hover", true },
	COMPLETION   { "textDocument/completion", true },
	DEFINITION   { "textDocument/definition", true },
	DECLERATION  { "textDocument/declaration", false },
	REFERENCES   { "textDocument/references", true },
	HELP         { "textDocument/signatureHelp", true },
	RENAME             { "textDocument/rename", true },
	PREPARE_RENAME     { "textDocument/prepareRename", true },
	WILL_SAVE          { "textDocument/willSave", false },
	WILL_SAVE_WAIT     { "textDocument/willSaveWaitUntil", false },
	FORMATTING         { "textDocument/formatting", true },
	RANGE_FORMATTING   { "textDocument/rangeFormatting", true },
	ON_TYPE_FORMAT     { "textDocument/onTypeFormatting", false },
	CODE_ACTION        { "textDocument/codeAction", true },
	CODE_LENS          { "textDocument/codeLens", false },
	CODE_LENS_RESOLVE  { "textDocument/codeLens/resolve", false },
	FOLDING_RANGE      { "textDocument/foldingRange", true },
	SELECTION_RANGE    { "textDocument/selectionRange", false },
	TYPE_DEFINITION    { "textDocument/typeDefinition", false },
	IMPLEMENTATION     { "textDocument/implementation", false },
	INLAY_HINT         { "textDocument/inlayHint", true },
	INLAY_HINT_RESOLVE { "textDocument/inlayHint/resolve", false },
	DIAGNOSTIC         { "textDocument/diagnostic", false },
	SEM_TOKENS_RANGE   { "textDocument/semanticTokens/range", false },
	SEM_TOKENS_DELTA   { "textDocument/semanticTokens/full/delta", false },
	PREPARE_CALL_HIER  { "textDocument/prepareCallHierarchy", false },
	LINKED_EDITING     { "textDocument/linkedEditingRange", false },
	MONIKER            { "textDocument/moniker", false },

	PUB_DIAG         { "textDocument/publishDiagnostics", false },

	SHOW_MESSAGE     { "window/showMessage", false },
	LOG_MESSAGE      { "window/logMessage", false },
	SHOW_MSG_REQUEST { "window/showMessageRequest", false },
	SHOW_DOCUMENT    { "window/showDocument", false },
	WDP_CREATE       { "window/workDoneProgress/create", false },
	WDP_CANCEL       { "window/workDoneProgress/cancel", false },

	WS_CHANGE_CONFIG    { "workspace/didChangeConfiguration", false },
	WS_CHANGE_WATCHED   { "workspace/didChangeWatchedFiles", true },
	WS_CHANGE_FOLDERS   { "workspace/didChangeWorkspaceFolders", false },
	WS_SYMBOL           { "workspace/symbol", true },
	WS_EXECUTE_COMMAND  { "workspace/executeCommand", true },
	WS_APPLY_EDIT       { "workspace/applyEdit", false },
	WS_CONFIGURATION    { "workspace/configuration", false },
	WS_DIAGNOSTIC       { "workspace/diagnostic", false },
	WS_DIAG_REFRESH     { "workspace/diagnostic/refresh", false },
	WS_SEM_REFRESH      { "workspace/semanticTokens/refresh", false },
	WS_CODELENS_REFRESH { "workspace/codeLens/refresh", false },
	WS_INLAY_REFRESH    { "workspace/inlayHint/refresh", false },

	CALL_INCOMING    { "callHierarchy/incomingCalls", false },
	CALL_OUTGOING    { "callHierarchy/outgoingCalls", false },
	TYPE_SUPERTYPES  { "typeHierarchy/supertypes", false },
	TYPE_SUBTYPES    { "typeHierarchy/subtypes", false },

	COMPLETION_RESOLVE { "completionItem/resolve", true },

	SHUTDOWN     { "shutdown", false },
	EXIT         { "exit", false },
	CANCEL       { "$/cancelRequest", false },
	SET_TRACE    { "$/setTrace", false },
	PROGRESS     { "$/progress", false },
	LOG_TRACE    { "$/logTrace", false },
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
	ERROR = 1,
	WARNING = 2,
	INFO = 3,
	HINT = 4,
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
	InitializeParams initialize @tag("kind", MessageKind.INITIALIZE);
	DidOpenParams did_open @tag("kind", MessageKind.DID_OPEN);
	DidChangeParams did_change @tag("kind", MessageKind.DID_CHANGE);
	DidCloseParams did_close @tag("kind", MessageKind.DID_CLOSE);
	DidSaveParams did_save @tag("kind", MessageKind.DID_SAVE);
	HoverParams hover @tag("kind", MessageKind.HOVER);
	CompletionParams completion @tag("kind", MessageKind.COMPLETION);
	CompletionItem completion_resolve @tag("kind", MessageKind.COMPLETION_RESOLVE);
	GoToDefinitionParams definition @tag("kind", MessageKind.DEFINITION);
	SignatureHelpParams signature_help @tag("kind", MessageKind.HELP);
	ReferenceParams references @tag("kind", MessageKind.REFERENCES);
	PrepareRenameParams prepare_rename @tag("kind", MessageKind.PREPARE_RENAME);
	RenameParams rename @tag("kind", MessageKind.RENAME);
	SemanticTokensParams semantic_tokens @tag("kind", MessageKind.FULL);
	DocumentSymbolParams document_symbol @tag("kind", MessageKind.SYMBOL);
	WorkspaceSymbolParams workspace_symbol @tag("kind", MessageKind.WS_SYMBOL);
	InlayHintParams inlay_hint @tag("kind", MessageKind.INLAY_HINT);
	FoldingRangeParams folding_range @tag("kind", MessageKind.FOLDING_RANGE);
	DocumentFormattingParams formatting @tag("kind", MessageKind.FORMATTING);
	DocumentRangeFormattingParams range_formatting @tag("kind", MessageKind.RANGE_FORMATTING);
	CodeActionParams code_action @tag("kind", MessageKind.CODE_ACTION);
	ExecuteCommandParams execute_command @tag("kind", MessageKind.WS_EXECUTE_COMMAND);

	PublishDiagnosticsParams pub_diag;
	LogMessageParams log_message;

	CancelParams cancel;
	SetTraceParams set_trace;

	DidChangeWatchedFilesParams did_change_watched @tag("kind", MessageKind.WS_CHANGE_WATCHED);
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