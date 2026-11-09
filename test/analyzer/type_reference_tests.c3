module type_reference_tests;

import diag_capture;

fn void generic_type_params_resolve_in_its_methods() @test
{
	Diag[] errs = diag_capture::errors_for(`module other;
struct Type { int x; }
module t;
struct Box (Printable) <Type, MAX>
{
	Type value;
}
fn void Box.set(&self, Type element) { self.value = element; }
macro Type Box.get(&self) => self.value;
`);
	assert(errs.len == 0, "%s", errs);
}

fn void type_from_unimported_module_in_method_is_reported() @test
{
	Diag[] errs = diag_capture::errors_for(`module other;
struct Type { int x; }
module t;
struct Box { int value; }
fn void Box.set(&self, Type element) {}
`);
	assert(errs.len == 1, "%s", errs);
	assert(errs[0].message.contains("import other"), "%s", errs);
}

fn void child_sees_parent_public_types() @test
{
	Diag[] errs = diag_capture::errors_for(`module par;
struct PNode { int x; }
module par::child;
fn int use(PNode* n) => n.x;
`);
	assert(errs.len == 0, "%s", errs);
}

fn void import_reaches_parent_modules() @test
{
	Diag[] errs = diag_capture::errors_for(`module par;
struct PNode { int x; }
module par::other::deep;
int z;
module zz;
import par::other::deep;
fn int use(PNode* n) => n.x;
`);
	assert(errs.len == 0, "%s", errs);
}

fn void norecurse_import_does_not_reach_parent_modules() @test
{
	Diag[] errs = diag_capture::errors_for(`module par;
struct PNode { int x; }
module par::other;
int z;
module zz;
import par::other @norecurse;
fn int use(PNode* n) => n.x;
`);
	assert(errs.len == 1, "%s", errs);
	assert(errs[0].message.contains("import par'"), "%s", errs);
}

<*
 As in std::gfx::win32, which reaches the private types of std::gfx through
 `import std::gfx::egl @public`.
*>
fn void public_import_reaches_parent_private_types() @test
{
	Diag[] errs = diag_capture::errors_for(`module par @feat(WIN32) @private;
struct PNode { int x; }
module par::other;
int z;
module par::child @feat(WIN32) @private;
import par::other @public;
fn int use(PNode* n) => n.x;
module zz;
import par::other @public;
fn int use2(PNode* n) => n.x;
`);
	assert(errs.len == 0, "%s", errs);
}

fn void public_import_does_not_reach_sibling_private_types() @test
{
	Diag[] errs = diag_capture::errors_for(`module par::third @private;
struct TNode { int t; }
module par::other;
int z;
module zz;
import par::other @public;
fn int use(TNode* n) => n.t;
`);
	assert(errs.len == 1, "%s", errs);
}
