module lsp;

import std::collections::object;
import std::collections::maybe;

enum LogLevel : char (String name)
{
	NONE  { "none" },
	DEBUG { "debug" },
	INFO  { "info" },
	WARN  { "warn" },
	ERROR { "error" }
}

constdef MarkupKind : inline String
{
PLAIN_TEXT = "plaintext",
MARKDOWN = "markdown"}

constdef TraceKind : inline String
{
	OFF = "off",
	MESSAGES = "messages",
	VERBOSE = "verbose",
}

constdef InsertTextFormat : int
{
	PLAIN_TEXT = 1,
	SNIPPET = 2,
}

constdef DiagnosticSeverity : int
{
	ERROR = 1,
	WARNING = 2,
	INFORMATION = 3,
	HINT = 4,
}

constdef DiagnosticTag : int
{
	UNNECESSARY = 1,
	DEPRECATED = 2,
}

constdef TextDocumentSyncKind : int
{
	NONE = 0,
	FULL = 1,
	INCREMENTAL = 2,
}

constdef CompletionTriggerKind : int
{
	INVOKED = 1,
	TRIGGER_CHARACTER = 2,
	TRIGGER_FOR_INCOMPLETE_COMPLETIONS = 3,
}

constdef MessageType : int
{
	ERROR = 1,
	WARNING = 2,
	INFO = 3,
	LOG = 4
}

constdef CompletionItemKind : int
{
	TEXT = 1,
	METHOD = 2,
	FUNCTION = 3,
	CONSTRUCTOR = 4,
	FIELD = 5,
	VARIABLE = 6,
	CLASS = 7,
	INTERFACE = 8,
	MODULE = 9,
	PROPERTY = 10,
	UNIT = 11,
	VALUE = 12,
	ENUM = 13,
	KEYWORD = 14,
	SNIPPET = 15,
	COLOR = 16,
	FILE = 17,
	REFERENCE = 18,
	FOLDER = 19,
	ENUMMEMBER = 20,
	CONSTANT = 21,
	STRUCT = 22,
	EVENT = 23,
	OPERATOR = 24,
	TYPEPARAMETER = 25,
}

constdef SymbolKind : int
{
	FILE = 1,
	MODULE = 2,
	NAMESPACE = 3,
	PACKAGE = 4,
	CLASS = 5,
	METHOD = 6,
	PROPERTY = 7,
	FIELD = 8,
	CONSTRUCTOR = 9,
	ENUM = 10,
	INTERFACE = 11,
	FUNCTION = 12,
	VARIABLE = 13,
	CONSTANT = 14,
	STRING = 15,
	NUMBER = 16,
	BOOLEAN = 17,
	ARRAY = 18,
	OBJECT = 19,
	KEY = 20,
	NULL = 21,
	ENUMMEMBER = 22,
	STRUCT = 23,
	EVENT = 24,
	OPERATOR = 25,
	TYPEPARAMETER = 26
}

constdef InlayHintKind : int
{
	TYPE = 1,
	PARAMETER = 2,
}

constdef FoldingRangeKind : inline String
{
COMMENT = "comment",
IMPORTS = "imports",
REGION = "region",}

// Keywords and Primitives are defined in analyzer::core::constants
