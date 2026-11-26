module analyzer::sema::scope;

import analyzer::core;

fn Scope* create(Allocator alloc, Range range, Scope* parent = null)
{
	Scope* scope = alloc::new(alloc, Scope);

	scope.parent = parent;
	scope.range = range;
	scope.children.init(alloc);
	scope.functions.init(alloc);
	scope.variables.init(alloc);
	scope.types.init(alloc);

	return scope;
}

fn void add_variable(Scope* scope, Allocator alloc, String name, Node* node)
{
	VariableInfo* variable = alloc::new(alloc, VariableInfo);

	variable.name = name;
	variable.mod = name;
	variable.node = node;

	scope.variables.set(name, variable);
}

fn bool has_variable(Scope* scope, String name)
{
	switch (true)
	{
		case scope.variables.has_key(name):
			return true;
		case scope.parent != null:
			return has_variable(scope.parent, name);
		default:
			return false;
	}
}

fn VariableInfo*? get_variable(Scope* scope, String name)
{
	return scope.variables.get(name) ?? (scope.parent ? get_variable(scope.parent, name) : NOT_FOUND~);
}

fn bool has_function(Scope* scope, String name)
{
	switch (true)
	{
		case scope.functions.has_key(name):
			return true;
		case scope.parent != null:
			return has_function(scope.parent, name);
		default:
			return false;
	}
}

fn FunctionInfo*? get_function(Scope* scope, String name)
{
	return scope.functions.get(name) ?? (scope.parent ? get_function(scope.parent, name) : NOT_FOUND~);
}
