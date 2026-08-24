// src/analyzer/sema/scope.c3
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

fn void free(Scope* scope)
{
	if (!scope) return;

	scope.children.free();
	scope.functions.free();
	scope.variables.free();
	scope.types.free();
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

fn VariableInfo* get_variable(Scope* scope, String name)
{
	switch (true)
	{
		case scope.variables.has_key(name):
			return scope.variables.get(name)!!;
		case scope.parent != null:
			return get_variable(scope.parent, name);
		default:
			return null;
	}
}

fn FunctionInfo* add_function(Scope* scope, Allocator alloc, String name, String mod, Node* node)
{
	FunctionInfo* function = alloc::new(alloc, FunctionInfo);

	function.mod  = mod;
	function.node = node;

	scope.functions.set(name, function);

	return function;
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

fn FunctionInfo* get_function(Scope* scope, String name)
{
	switch (true)
	{
		case scope.functions.has_key(name):
			return scope.functions.get(name)!!;
		case scope.parent != null:
			return get_function(scope.parent, name);
		default:
			return null;
	}
}