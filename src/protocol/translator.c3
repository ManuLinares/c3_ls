module lsp::translator;

import std::io;
import std::encoding::json;
import std::collections::maybe;
import std::collections::object;
import uri;

import lsp;

faultdef
INVALID_MESSAGE,
INCOMPLETE_JSON;

struct LspMessage
{
	String rpc;
	MessageKind method;
	int id;
	bool has_id;
	MessageParams params;
	Allocator allocator;
}

fn void LspMessage.free(&self)
{
	if (self.allocator == tmem) return;
	self.rpc.free(self.allocator);
	switch (self.method)
	{
		case INITIALIZE: object::recursively_free{InitializeParams}(self.allocator, &self.params.initialize);
		case DID_OPEN: object::recursively_free{DidOpenParams}(self.allocator, &self.params.did_open);
		case DID_CLOSE: object::recursively_free{DidCloseParams}(self.allocator, &self.params.did_close);
		case DID_SAVE: object::recursively_free{DidSaveParams}(self.allocator, &self.params.did_save);
		case DID_CHANGE: object::recursively_free{DidChangeParams}(self.allocator, &self.params.did_change);
		case HOVER: object::recursively_free{HoverParams}(self.allocator, &self.params.hover);
		case DEFINITION: object::recursively_free{GoToDefinitionParams}(self.allocator, &self.params.definition);
		case COMPLETION: object::recursively_free{CompletionParams}(self.allocator, &self.params.completion);
		case COMPLETION_RESOLVE: object::recursively_free{CompletionItem}(self.allocator, &self.params.completion_resolve.item);
		case HELP: object::recursively_free{SignatureHelpParams}(self.allocator, &self.params.signature_help);
		case REFERENCES: object::recursively_free{ReferenceParams}(self.allocator, &self.params.references);
		case PREPARE_RENAME: object::recursively_free{PrepareRenameParams}(self.allocator, &self.params.prepare_rename);
		case RENAME: object::recursively_free{RenameParams}(self.allocator, &self.params.rename);
		case FULL: object::recursively_free{SemanticTokensParams}(self.allocator, &self.params.semantic_tokens);
		case SYMBOL: object::recursively_free{DocumentSymbolParams}(self.allocator, &self.params.document_symbol);
		case WS_SYMBOL: object::recursively_free{WorkspaceSymbolParams}(self.allocator, &self.params.workspace_symbol);
		case INLAY_HINT: object::recursively_free{InlayHintParams}(self.allocator, &self.params.inlay_hint);
		case FOLDING_RANGE: object::recursively_free{FoldingRangeParams}(self.allocator, &self.params.folding_range);
		case FORMATTING: object::recursively_free{DocumentFormattingParams}(self.allocator, &self.params.formatting);
		case RANGE_FORMATTING: object::recursively_free{DocumentRangeFormattingParams}(self.allocator, &self.params.range_formatting);
		case CODE_ACTION: object::recursively_free{CodeActionParams}(self.allocator, &self.params.code_action);
		case WS_EXECUTE_COMMAND: object::recursively_free{ExecuteCommandParams}(self.allocator, &self.params.execute_command);
		case WS_CHANGE_WATCHED: object::recursively_free{DidChangeWatchedFilesParams}(self.allocator, &self.params.did_change_watched);
		default: break;
	}
}

<*
	Turn data into JSONRPC string
	@param [in] expr
	@return "JSONRPC string allocated with `allocator`"
*>
macro String encode(expr, Allocator allocator, int indent = 0)
{
	String expr_json = json::marshal(allocator, expr, NONE);
	usz expr_size = expr_json.len;

	return string::format(allocator,
	"Content-Length: %d\r\n\r\n%s",
	expr_size,
	expr_json
	);
}

struct IoDecodeResult
{
	LspMessage message;
	usz len;
}

struct Envelope @local
{
	String jsonrpc;
	Object* id;
	String method;
}

struct Request <Params> @local
{
	Params params;
}

macro @params(Allocator allocator, String message, $Params) @local
{
	Request{$Params}? request = json::unmarshal(allocator, message, Request{$Params});
	if (catch request) return INVALID_MESSAGE~;
	return request.params;
}

<*
	Decode JSONRPC message
	@param [in] message : `json message without the header`
	@return "LSP message allocated with `allocator`, as well as length of whole message"
	@return? INCOMPLETE_JSON
	@return? INVALID_MESSAGE
*>
fn IoDecodeResult? decode(Allocator allocator, String message) => @pool()
{
	if (message.len == 0) return INVALID_MESSAGE~;
	Envelope envelope = json::unmarshal(tmem, message, Envelope) ?? INVALID_MESSAGE~!;

	LspMessage msg = {
		.allocator = allocator,
		.rpc = (envelope.jsonrpc.len > 0 ? envelope.jsonrpc : "2.0").copy(allocator),
		.method = lsp::message_kind_from_string(envelope.method),
		.id = -1,
	};
	if (envelope.id && envelope.id.is_int())
	{
		msg.id = (int)envelope.id.i;
		msg.has_id = true;
	}

	switch (msg.method)
	{
		case INITIALIZE: msg.params.initialize = @params(allocator, message, InitializeParams)!;
		case DID_OPEN: msg.params.did_open = @params(allocator, message, DidOpenParams)!;
		case DID_CLOSE: msg.params.did_close = @params(allocator, message, DidCloseParams)!;
		case DID_SAVE: msg.params.did_save = @params(allocator, message, DidSaveParams)!;
		case DID_CHANGE: msg.params.did_change = @params(allocator, message, DidChangeParams)!;
		case HOVER: msg.params.hover = @params(allocator, message, HoverParams)!;
		case DEFINITION: msg.params.definition = @params(allocator, message, GoToDefinitionParams)!;
		case COMPLETION: msg.params.completion = @params(allocator, message, CompletionParams)!;
		case COMPLETION_RESOLVE: msg.params.completion_resolve.item = @params(allocator, message, CompletionItem)!;
		case HELP: msg.params.signature_help = @params(allocator, message, SignatureHelpParams)!;
		case REFERENCES: msg.params.references = @params(allocator, message, ReferenceParams)!;
		case PREPARE_RENAME: msg.params.prepare_rename = @params(allocator, message, PrepareRenameParams)!;
		case RENAME: msg.params.rename = @params(allocator, message, RenameParams)!;
		case FULL: msg.params.semantic_tokens = @params(allocator, message, SemanticTokensParams)!;
		case SYMBOL: msg.params.document_symbol = @params(allocator, message, DocumentSymbolParams)!;
		case WS_SYMBOL: msg.params.workspace_symbol = @params(allocator, message, WorkspaceSymbolParams)!;
		case INLAY_HINT: msg.params.inlay_hint = @params(allocator, message, InlayHintParams)!;
		case FOLDING_RANGE: msg.params.folding_range = @params(allocator, message, FoldingRangeParams)!;
		case FORMATTING: msg.params.formatting = @params(allocator, message, DocumentFormattingParams)!;
		case RANGE_FORMATTING: msg.params.range_formatting = @params(allocator, message, DocumentRangeFormattingParams)!;
		case CODE_ACTION: msg.params.code_action = @params(allocator, message, CodeActionParams)!;
		case WS_EXECUTE_COMMAND: msg.params.execute_command = @params(allocator, message, ExecuteCommandParams)!;
		case WS_CHANGE_WATCHED: msg.params.did_change_watched = @params(allocator, message, DidChangeWatchedFilesParams)!;
		default: break;
	}

	return {
		.message = msg,
		.len = message.len
	};
}
