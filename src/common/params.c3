module lsp;

import std::collections::object;
import std::collections::maybe;

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

struct InitializeParams
{
	int process_id;
	ClientInfo client_info;
	String locale;
	Maybe{DocumentUri} root_uri;
	Maybe{TraceKind} trace;
	Maybe{WorkspaceFolder[]} workspace_folders;
}

struct DidOpenParams
{
	TextDocumentItem document;
}

struct TextDocumentIdentifier
{
	DocumentUri uri;
}

struct DidCloseParams
{
	TextDocumentIdentifier document;
}

struct HoverParams
{
	TextDocumentIdentifier document;
	LspPosition position;
}

struct GoToDefinitionParams
{
	TextDocumentIdentifier document;
	LspPosition position;
}

struct SignatureHelpParams
{
	TextDocumentIdentifier text_document;
	LspPosition position;
}

struct ReferenceContext
{
	bool includeDeclaration;
}

struct ReferenceParams
{
	TextDocumentIdentifier text_document;
	LspPosition position;
	ReferenceContext context;
}

struct PrepareRenameParams
{
	TextDocumentIdentifier text_document;
	LspPosition position;
}

struct RenameParams
{
	TextDocumentIdentifier text_document;
	LspPosition position;
	String newName;
}

struct SemanticTokensParams
{
	TextDocumentIdentifier text_document;
}

struct CompletionTextDocument
{
	String uri;
}

struct CompletionParams
{
	CompletionTextDocument text_document;
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
	uint range_length;
	String text;
}

struct DidChangeParams
{
	VersionedTextDocumentIdentifier document;
	TextDocumentContentChangeEvent[] content_changes;
}

struct LogMessageParams
{
	int type;
	String message;
}

union MessageParams
{
	Object* unknown;
	InitializeParams initialize;
	DidOpenParams did_open;
	DidChangeParams did_change;
	DidCloseParams did_close;
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

	PublishDiagnosticsParams pub_diag;
	LogMessageParams log_message;

	CancelParams cancel;
	SetTraceParams set_trace;
}

struct FormattingOptions
{
	uint tab_size;
	bool insert_spaces;
	bool trim_trailing_whitespace;
	bool insert_final_newline;
	bool trim_final_newlines;
}

struct DocumentFormattingParams
{
	TextDocumentIdentifier text_document;
	FormattingOptions options;
}

struct DocumentRangeFormattingParams
{
	TextDocumentIdentifier text_document;
	LspRange range;
	FormattingOptions options;
}
