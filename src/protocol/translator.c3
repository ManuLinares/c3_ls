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
	<* The request's id as sent, a number or a string; null for a notification. *>
	Object* id;
	MessageParams params;
	Allocator allocator;
}

fn void LspMessage.free(&self)
{
	if (self.allocator == tmem) return;
	self.rpc.free(self.allocator);
	if (self.id) self.id.free();
	$foreach $m : MessageParams::members:
		if (self.method.params == $m.type) object::recursively_free{$m.type}(self.allocator, &self.params.$m);
	$endforeach
}

<*
 Turn data into JSONRPC string
 @param [in] expr
 @return "JSONRPC string allocated with `allocator`"
*>
macro String encode(expr, Allocator allocator, int indent = 0)
{
	String expr_json = json::marshal(allocator, expr, NONE);
	// Appended, not formatted with `%s`: the formatter copies a string one character at a time.
	DString out;
	out.init(allocator, expr_json.len + 32);
	out.appendf("Content-Length: %d\r\n\r\n", expr_json.len);
	out.append(expr_json);
	return out.str_view();
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

fn ParamsType? params(Allocator allocator, String message) <ParamsType> @local
{
	return json::unmarshal(allocator, message, Request{ParamsType}).params ?? INVALID_MESSAGE~!;
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
	};
	if (envelope.id && envelope.id.is_int()) msg.id = object::new_int(allocator, envelope.id.i);
	if (envelope.id && envelope.id.is_string()) msg.id = object::new_string(allocator, envelope.id.s);

	$foreach $k : MessageKind::values:
		int $n = 0;
		$foreach $m : MessageParams::members:
			$if $m.type == $k.params: $n++;
			$endif
		$endforeach
		$assert $n == (int)($k.params != void) : "MessageParams must hold exactly one member per params type";
	$endforeach
	$foreach $m : MessageParams::members:
		if (msg.method.params == $m.type) msg.params.$m = params{$m.type}(allocator, message)!;
	$endforeach

	return {
		.message = msg,
		.len = message.len
	};
}
