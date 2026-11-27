module analyzer::core::ast;

struct Error
{
	inline Node node;
	NodeArray inner;
}
