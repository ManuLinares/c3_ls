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
	$foreach $m : MessageParams::members:
		$if $m.has_tag("kind"):
			if (self.method == $m.get_tag("kind")) object::recursively_free{$m.type}(self.allocator, &self.params.$m);
		$endif
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

	$foreach $k : MessageKind::values:
		int $n = 0;
		$foreach $m : MessageParams::members:
			$if $m.has_tag("kind") &&& $m.get_tag("kind") == $k:
				$n++;
			$endif
		$endforeach
		$assert $n == (int)$k.has_params : "MessageParams tag mismatch";
	$endforeach
	$foreach $m : MessageParams::members:
		$if $m.has_tag("kind"):
			if (msg.method == $m.get_tag("kind")) msg.params.$m = @params(allocator, message, $m.type)!;
		$endif
	$endforeach

	return {
		.message = msg,
		.len = message.len
	};
}
