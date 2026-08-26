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

enum TraceKind : char (String name)
{
	OFF      { "off" },
	MESSAGES { "messages" },
	VERBOSE  { "verbose" }
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

enum Keywords : int (String name, String docs)
{
	ALIAS     { "alias", "" },
	ASSERT    { "assert", "" },
	ASM       { "asm", "" },
	ATTRDEF   { "attrdef", "" },
	BITSTRUCT { "bitstruct", "" },
	BREAK     { "break", "" },
	CASE      { "case", "" },
	CATCH     { "catch", "" },
	CONSTDEF  { "constdef", "" },
	CONST     { "const", "" },
	CONTINUE  { "continue", "" },
	DEFAULT   { "default", "" },
	DEFER     { "defer", "" },
	DO        { "do", "" },
	ELSE      { "else", "" },
	ENUM      { "enum", "" },
	EXTERN    { "extern", "" },
	FALSE     { "false", "" },
	FAULTDEF  { "faultdef", "" },
	FAULTSET  { "faultset", "" },
	FOR       { "for", "" },
	FOREACH   { "foreach", "" },
	FOREACH_R { "foreach_r", "" },
	FN        { "fn", "" },
	TLOCAL    { "tlocal", "" },
	IF        { "if", "" },
	INLINE    { "inline", "" },
	IMPORT    { "import", "" },
	LENGTHOF  { "lengthof", "" },
	MACRO     { "macro", "" },
	MODULE    { "module", "module decleration" },
	NEXTCASE  { "nextcase", "" },
	NULL      { "null", "" },
	INTERFACE { "interface", "" },
	RETURN    { "return", "" },
	STATIC    { "static", "" },
	STRUCT    { "struct", "" },
	SWITCH    { "switch", "" },
	TRUE      { "true", "" },
	TRY       { "try", "" },
	TYPEDEF   { "typedef", "" },
	UNION     { "union", "" },
	VAR       { "var", "" },
	WHILE     { "while", "" },
}

fn bool Keywords.is_top_level(self)
{
	switch (self)
	{
		case MODULE:
		case IMPORT:
		case ALIAS:
		case ATTRDEF:
		case BITSTRUCT:
		case CONSTDEF:
		case STRUCT:
		case CONST:
		case ENUM:
		case EXTERN:
		case FAULTDEF:
		case FAULTSET:
		case FN:
		case TLOCAL:
		case MACRO:
		case INTERFACE:
		case TYPEDEF:
		case UNION:
			return true;
		default:
			return false;
	}
}

fn bool Keywords.is_container(self)
{
	switch (self)
	{
		case INLINE:
		case TLOCAL:
			return true;
		default:
			return false;
	}
}

fn bool Keywords.is_statement(self)
{
	switch (self)
	{
		case ASSERT:
		case ASM:
		case CONST:
		case VAR:
		case IF:
		case FOR:
		case WHILE:
		case FOREACH:
		case FOREACH_R:
		case DEFER:
		case LENGTHOF:
			return true;
		default:
			return false;
	}
}

fn bool Keywords.is_expression(self)
{
	switch (self)
	{
		case TRUE:
		case FALSE:
		case NULL:
			return true;
		default:
			return false;
	}
}

fn bool Keywords.is_value(self)
{
	switch (self)
	{
		case TRUE:
		case FALSE:
		case NULL:
			return true;
		default:
			return false;
	}
}
