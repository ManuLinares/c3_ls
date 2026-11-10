module lsp;

import std::collections::object;
import std::encoding::json;
// https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification
alias LspUri = String;
alias DocumentUri = String;

struct WorkspaceFolder
{
	LspUri uri;
	String name;
}

struct TextDocumentItem
{
	DocumentUri uri;
	String language_id @Json("languageId");
	int version;
	String text;
}

struct LspPosition
{
	uint line;
	uint character;
}

struct LspRange
{
	LspPosition start;
	LspPosition end;
}

struct LspLocation
{
	DocumentUri uri;
	LspRange range;
}

struct Diagnostic
{
	LspRange range;
	DiagnosticSeverity severity;
	String source;
	String message;
	DiagnosticTag[] tags;
}

struct MarkedString
{
	String language;
	String value;
}

struct MarkupContent
{
	MarkupKind kind;
	String value;
}

struct SaveOptions
{
	bool includeText;
}

struct TextDocumentSyncOptions
{
	bool openClose;
	TextDocumentSyncKind change;
	SaveOptions save;
}

struct CompletionContext
{
	CompletionTriggerKind triggerKind;
	String triggerCharacter;
}

struct CompletionItem
{
	String label;
	CompletionItemKind kind @JsonOmitEmpty;
	String detail @JsonOmitEmpty;
	MarkupContent documentation @JsonOmitEmpty;
	String insertText @JsonOmitEmpty;
	InsertTextFormat insertTextFormat @JsonOmitEmpty;
	String filterText @JsonOmitEmpty;
	String sortText @JsonOmitEmpty;
	String data @JsonOmitEmpty;
	TextEdit* textEdit @JsonOmitEmpty; // Replaces the typed range; insertText is used when null.
}

struct VersionedTextDocumentIdentifier
{
	DocumentUri uri;
	int version;
}

struct ParameterInformation
{
	String label;
	String documentation;
}

struct SignatureInformation
{
	String label;
	MarkupContent documentation;
	ParameterInformation[] parameters;
	uint activeParameter;
}

struct SignatureHelpResult
{
	SignatureInformation[] signatures;
	uint activeSignature;
	uint activeParameter;
}

struct TextEdit
{
	LspRange range;
	String newText;
}

<*
 `version` is null when the server does not know the document version.
*>
struct OptionalVersionedTextDocumentIdentifier
{
	DocumentUri uri;
	Object* version;
}

struct TextDocumentEdit
{
	OptionalVersionedTextDocumentIdentifier textDocument;
	TextEdit[] edits;
}

struct WorkspaceEdit
{
	TextDocumentEdit[] documentChanges;
}

struct SemanticTokensResult
{
	uint[] data;
}

struct SymbolInformation
{
	String name;
	SymbolKind kind;
	LspLocation location;
	String containerName;
}

struct DocumentSymbolParams
{
	TextDocumentIdentifier text_document @Json("textDocument");
}

struct WorkspaceSymbolParams
{
	String query;
}

struct InlayHint
{
	LspPosition position;
	String label;
	InlayHintKind kind;
	bool paddingLeft;
	bool paddingRight;
}

struct InlayHintParams
{
	TextDocumentIdentifier text_document @Json("textDocument");
	LspRange range;
}

struct FoldingRange
{
	uint startLine;
	uint startCharacter;
	uint endLine;
	uint endCharacter;
	String kind;
}

struct FoldingRangeParams
{
	TextDocumentIdentifier text_document @Json("textDocument");
}

struct Command
{
	String title;
	String command;
	String[] arguments;
}

struct CodeAction
{
	String title;
	String kind;
	LspDiagnostic[] diagnostics;
	bool isPreferred;
	Command command;
}

struct CodeActionContext
{
	LspDiagnostic[] diagnostics;
	String[] only;
}

struct CodeActionParams
{
	TextDocumentIdentifier text_document @Json("textDocument");
	LspRange range;
	CodeActionContext context;
}

struct ExecuteCommandParams
{
	String command;
	String[] arguments;
}

struct FileEvent
{
	DocumentUri uri;
	int type;
}

struct DidChangeWatchedFilesParams
{
	FileEvent[] changes;
}