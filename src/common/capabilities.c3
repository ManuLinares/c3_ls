// src/common/capabilities.c3
module lsp;

struct CompletionItemCapability
{
	bool labelDetailSupport;
}

struct CompletionOptions
{
	String[] triggerCharacters;
	String[] allCommitCharacters;
	bool resolveProvider;
	CompletionItemCapability completionItem;
}

struct SignatureHelpOptions
{
	String[] triggerCharacters;
	String[] retriggerCharacters;
}

struct SemanticTokensLegend
{
	String[] tokenTypes;
	String[] tokenModifiers;
}

struct SemanticTokensOptions
{
	SemanticTokensLegend legend;
	bool full;
}

struct RenameOptions
{
	bool prepareProvider;
}

<*
	https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#serverCapabilities
*>
struct LspServerCapabilities
{
	TextDocumentSyncOptions textDocumentSync;
	CompletionOptions completionProvider;
	bool hoverProvider;
	bool definitionProvider;
	SignatureHelpOptions signatureHelpProvider;
	bool referencesProvider;
	RenameOptions renameProvider;
	SemanticTokensOptions semanticTokensProvider;
	bool documentSymbolProvider;
	bool workspaceSymbolProvider;
	bool inlayHintProvider;
	bool foldingRangeProvider;
	bool documentFormattingProvider;
	bool documentRangeFormattingProvider;
}