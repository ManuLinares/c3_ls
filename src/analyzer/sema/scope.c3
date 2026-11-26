module analyzer::sema::scope;

import analyzer::core;

fn Scope* create(Allocator alloc, Range range, Scope* parent = null)
{
	Scope* scope = alloc::new(alloc, Scope);

	scope.parent = parent;
	scope.range = range;
	scope.children.init(alloc);
	scope.variables.init(alloc);

	return scope;
}

fn void add_variable(Scope* scope, Allocator alloc, String name, Node* node)
{
	VariableInfo* variable = alloc::new(alloc, VariableInfo);

	variable.name = name;
	variable.node = node;

	scope.variables.set(name, variable);
}

fn VariableInfo*? get_variable(Scope* scope, String name)
{
	return scope.variables.get(name) ?? (scope.parent ? get_variable(scope.parent, name) : NOT_FOUND~);
}
