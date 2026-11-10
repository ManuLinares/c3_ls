module lsp;

import std::collections::object;
import std::collections::ref;
import std::encoding::json;
import uri;

enum MessageKind : char (String name)
{
	UNKNOWN      { "unknown" },
	INITIALIZE   { "initialize" },
	INITIALIZED  { "initialized" },
	DID_OPEN     { "textDocument/didOpen" },
	DID_CHANGE   { "textDocument/didChange" },
	DID_CLOSE    { "textDocument/didClose" },
	DID_SAVE     { "textDocument/didSave" },
	FULL         { "textDocument/semanticTokens/full" },
	SYMBOL       { "textDocument/documentSymbol" },
	HOVER        { "textDocument/hover" },
	COMPLETION   { "textDocument/completion" },
	DEFINITION   { "textDocument/definition" },
	DECLERATION  { "textDocument/declaration" },
	REFERENCES   { "textDocument/references" },
	HELP         { "textDocument/signatureHelp" },
	RENAME             { "textDocument/rename" },
	PREPARE_RENAME     { "textDocument/prepareRename" },
	WILL_SAVE          { "textDocument/willSave" },
	WILL_SAVE_WAIT     { "textDocument/willSaveWaitUntil" },
	FORMATTING         { "textDocument/formatting" },
	RANGE_FORMATTING   { "textDocument/rangeFormatting" },
	ON_TYPE_FORMAT     { "textDocument/onTypeFormatting" },
	CODE_ACTION        { "textDocument/codeAction" },
	CODE_LENS          { "textDocument/codeLens" },
	CODE_LENS_RESOLVE  { "textDocument/codeLens/resolve" },
	FOLDING_RANGE      { "textDocument/foldingRange" },
	SELECTION_RANGE    { "textDocument/selectionRange" },
	TYPE_DEFINITION    { "textDocument/typeDefinition" },
	IMPLEMENTATION     { "textDocument/implementation" },
	INLAY_HINT         { "textDocument/inlayHint" },
	INLAY_HINT_RESOLVE { "textDocument/inlayHint/resolve" },
	DIAGNOSTIC         { "textDocument/diagnostic" },
	SEM_TOKENS_RANGE   { "textDocument/semanticTokens/range" },
	SEM_TOKENS_DELTA   { "textDocument/semanticTokens/full/delta" },
	PREPARE_CALL_HIER  { "textDocument/prepareCallHierarchy" },
	LINKED_EDITING     { "textDocument/linkedEditingRange" },
	MONIKER            { "textDocument/moniker" },

	PUB_DIAG         { "textDocument/publishDiagnostics" },

	SHOW_MESSAGE     { "window/showMessage" },
	LOG_MESSAGE      { "window/logMessage" },
	SHOW_MSG_REQUEST { "window/showMessageRequest" },
	SHOW_DOCUMENT    { "window/showDocument" },
	WDP_CREATE       { "window/workDoneProgress/create" },
	WDP_CANCEL       { "window/workDoneProgress/cancel" },

	WS_CHANGE_CONFIG    { "workspace/didChangeConfiguration" },
	WS_CHANGE_WATCHED   { "workspace/didChangeWatchedFiles" },
	WS_CHANGE_FOLDERS   { "workspace/didChangeWorkspaceFolders" },
	WS_SYMBOL           { "workspace/symbol" },
	WS_EXECUTE_COMMAND  { "workspace/executeCommand" },
	WS_APPLY_EDIT       { "workspace/applyEdit" },
	WS_CONFIGURATION    { "workspace/configuration" },
	WS_DIAGNOSTIC       { "workspace/diagnostic" },
	WS_DIAG_REFRESH     { "workspace/diagnostic/refresh" },
	WS_SEM_REFRESH      { "workspace/semanticTokens/refresh" },
	WS_CODELENS_REFRESH { "workspace/codeLens/refresh" },
	WS_INLAY_REFRESH    { "workspace/inlayHint/refresh" },

	CALL_INCOMING    { "callHierarchy/incomingCalls" },
	CALL_OUTGOING    { "callHierarchy/outgoingCalls" },
	TYPE_SUPERTYPES  { "typeHierarchy/supertypes" },
	TYPE_SUBTYPES    { "typeHierarchy/subtypes" },

	COMPLETION_RESOLVE { "completionItem/resolve" },

	SHUTDOWN     { "shutdown" },
	EXIT         { "exit" },
	CANCEL       { "$/cancelRequest" },
	SET_TRACE    { "$/setTrace" },
	PROGRESS     { "$/progress" },
	LOG_TRACE    { "$/logTrace" },
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

struct CompletionItemResolveParams
{
	inline CompletionItem item;
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
	InitializeParams initialize;
	DidOpenParams did_open;
	DidChangeParams did_change;
	DidCloseParams did_close;
	DidSaveParams did_save;
	HoverParams hover;
	CompletionParams completion;
	CompletionItemResolveParams completion_resolve;
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