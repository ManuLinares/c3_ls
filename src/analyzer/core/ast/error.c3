module analyzer::core::ast;

import std::collections::list;

struct Error
{
	inline Node node;
	NodeArray inner;
}
