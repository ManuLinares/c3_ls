// src/common/common.c3
module lsp;

import std::collections::object;
import std::collections::maybe;

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
	String language_id;
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

struct TextDocumentSyncOptions
{
	bool openClose;
	TextDocumentSyncKind change;
}

struct CompletionContext
{
	CompletionTriggerKind triggerKind;
	Maybe{String} triggerCharacter;
}

struct CompletionItem
{
	String label;
    CompletionItemKind kind;
    String detail;
	MarkupContent documentation;
	String insertText;
	InsertTextFormat insertTextFormat;
	String filterText;
	String sortText;
	String data;
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

struct TextDocumentEdit
{
	VersionedTextDocumentIdentifier textDocument;
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
	TextDocumentIdentifier text_document;
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
	TextDocumentIdentifier text_document;
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
	TextDocumentIdentifier text_document;
}