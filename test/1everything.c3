#!/usr/bin/env c3c
// Helper module for non-recursive and public import testing
module all_features::helper;

// Helper function in imported module
fn int helper_val() => 42;

// Generic module section parameterized with type and constant
<* @require CAPACITY > 0 *>
module all_features::generic_stack <Type, CAPACITY>;

// Parameterized struct inside generic module
struct GenericStack
{
	Type[CAPACITY] items;
	sz count;
}

// Parameterized method inside generic module
fn void GenericStack.push(&self, Type item)
{
	if (self.count < CAPACITY)
	{
		self.items[self.count++] = item;
	}
}

// Root module declaration
module all_features;

// Imports with @norecurse and @public attributes
import all_features::helper @norecurse @public;
import all_features::generic_stack;
import net_utils;
import net::utils;

// External C function declaration with @cname
extern fn int puts(char* str) @cname("puts");

// External function with C-style variadics
extern fn int c_variadic_stub(char* fmt, ...) @cname("printf");

// External heap functions for standalone execution
extern fn void* malloc(sz size);
extern fn void free(void* ptr);

// User-defined attribute definition
attrdef @HotInline = @inline, @nodiscard;

// Fault definitions with @obfuscate attribute
faultdef INVALID_ARG, OUT_OF_BOUNDS, CALC_FAILED, SUB_FAULT @obfuscate;

// Decimal, hexadecimal, binary, and octal integer literals
const int DEC_VAL = 1_000_000;
const uint HEX_VAL = 0xDEAD_BEEF;
const uint BIN_VAL = 0b1010_0101;
const uint OCT_VAL = 0o755;

// 64-bit and 128-bit integer literal suffixes
const long LONG_VAL = 123456789L;
const ulong ULONG_VAL = 0xABCD_EF01UL;
const int128 INT128_VAL = 1234567890123456789LL;
const uint128 UINT128_VAL = 0xFFFF_FFFF_FFFF_FFFF_FFFFULL;

// Standard single-byte character literal
const char ASCII_CHAR = 'Z';

// Multi-byte character literals
const ushort TWO_CC = 'AB';
const uint FOUR_CC = 'TEST';
const ulong EIGHT_CC = 'FOOBAR11';

// Hexadecimal and Base64 byte array literals
const char[*] HEX_DATA = x"4865 6c6c 6f";
const char[*] B64_DATA = b64"SGVsbG8=";

// String literals and raw multiline strings
const String ESCAPED_STR = "Line1\nLine2\t\e[0m";
const String RAW_STR = `Raw string
Path: C:\test\dir
Doubled backtick: `` `;

// Floating-point literals and suffixes
const float FLOAT_VAL = 3.14159f;
const double DOUBLE_VAL = 2.718281828459045d;
const double HEX_FLOAT = 0x1.fp3;

// Numeric type properties for limits, infinity, and NaN
const int INT_MAX_LIMIT = int::max;
const int INT_MIN_LIMIT = int::min;
const float FLOAT_INF_VAL = float::inf;
const float FLOAT_NAN_VAL = float::nan;

// Compile-time array concatenation with +++
const int[4] CONCAT_ARR = (int[2]){ 1, 2 } +++ (int[2]){ 3, 4 };

// Compile-time string concatenation using +++
const String CT_CONCAT_STR = "Hello, " +++ "C3!";

// Compile-time logical operators &&& and |||
const bool CT_BOOL = $defined(int) &&& (false ||| true);

// Distinct type definition with @constinit
typedef UserID @constinit = ulong;

// Inline distinct type definition
typedef FileDescriptor = inline int;

// Function and constant aliases
alias global_fn_alias = puts;
alias GLOBAL_CONST_ALIAS = DEC_VAL;

// Mutable global variable and alias
int global_mut_val = 100;
alias global_mut_alias = global_mut_val;

// Aligned distinct type definition
typedef IntAlign2 = int @align(2);

// Method defined directly on distinct type
fn UserID UserID.offset(self, ulong n) => self + (UserID)n;

// Method defined on primitive integer type
fn int int.double_val(self) => self * 2;

// Type aliases and conditional type alias
alias Byte = char;
alias PlatformWord = $defined(long) ? long : int;

// Conditional alias based on feature flag
alias FeatureWord = $feat(WIN32) ? ulong : uint;

// Function pointer type alias with default arguments
alias TransformFn = fn int(int value, int step = 1);
alias SingleIntOp = fn int(int value);

// Struct with anonymous union, anonymous sub-struct, and named sub-struct
struct ComplexRecord
{
	int id;
	union
	{
		long l_val;
		double d_val;
	}
	struct
	{
		int anon_sub_field;
	}
	union tagged_choice
	{
		int choice_i;
		float choice_f;
	}
	struct config
	{
		bool active;
		ushort flags;
	}
}

// Struct with flexible array member
struct HeaderWithFlexArray
{
	sz len;
	int[*] payload;
}

// Struct with @mustinit attribute
struct StrictData @mustinit
{
	int id;
}

// Base struct for subtyping
struct BaseEntity
{
	int entity_id;
	float x;
	float y;
}

// Struct subtyping with inline member
struct Player
{
	inline BaseEntity base;
	int health;
}

// Packed and aligned struct
struct AlignedHeader @packed @align(16)
{
	int magic;
	short version_id;
}

// Standalone named union
union NumberUnion
{
	int i_val;
	float f_val;
}

// Bitstruct with bit ranges and backing type
bitstruct DeviceFlags : ushort
{
	int mode     : 0..3;
	int channel  : 4..7;
	bool enabled : 8;
	bool ready   : 9;
}

// Bitstruct backed by char array
bitstruct CharArrayBacked : char[4]
{
	ushort p1 : 0..15;
	ushort p2 : 16..31;
}

// Bitstruct with endianness attributes
bitstruct BigEndianData : uint @bigendian
{
	ushort high : 0..15;
	ushort low  : 16..31;
}

bitstruct LittleEndianData : uint @littleendian
{
	ushort high : 0..15;
	ushort low  : 16..31;
}

// Bitstruct with @overlap attribute
bitstruct OverlapData : char @overlap
{
	int a : 0..3;
	int b : 2..5;
}

// Boolean-only bitstruct with inferred bit positions
bitstruct StatusMask : char
{
	bool flag_read;
	bool flag_write;
	bool flag_exec;
}

// Enum with associated static values and @obfuscate
enum HttpStatus : int (int code, String message) @obfuscate
{
	OK             { 200, "OK" },
	NOT_FOUND_ERR  { 404, "Not Found" },
	INTERNAL_ERR   { 500, "Internal Server Error" }
}

// Constdef for sparse constant sets
constdef KeyMapping : int
{
	KEY_ESC    = 27,
	KEY_ENTER  = 13,
	KEY_SPACE  = 32,
	KEY_CUSTOM = 100,
}

// Inline constdef allowing implicit conversion
constdef InlineStatus : inline int
{
	STATUS_OK   = 0,
	STATUS_FAIL = 1,
}

// Constdef with @constinit attribute
constdef ConstInitDef : int @constinit
{
	INIT_A = 10,
	INIT_B = 20,
}

// Interface with standard and @optional methods
interface Describable
{
	fn String describe();
	fn void reset() @optional;
}

// Interface implementation on struct
struct Widget (Describable)
{
	int serial;
}

// Dynamic method implementation
fn String Widget.describe(Widget* self) @dynamic
{
	return "Widget";
}

fn void Widget.reset(Widget* self) @dynamic
{
	self.serial = 0;
}

// TypeKind reflection enumeration
enum TypeKind : char
{
	VOID,
	BOOL,
	SIGNED_INT,
	UNSIGNED_INT,
	FLOAT,
	TYPEID,
	FAULT,
	ANY,
	ENUM,
	CONSTDEF,
	STRUCT,
	UNION,
	BITSTRUCT,
	FUNC,
	OPTIONAL,
	ARRAY,
	SLICE,
	VECTOR,
	TYPEDEF,
	POINTER,
	INTERFACE,
	UNTYPEDLIST,
}

// Generic struct with @if conditional member
struct Box <Type>
{
	Type item;
	bool occupied;
	int extra_tag @if((int)Type::kind == (int)TypeKind.SIGNED_INT);
}

// Generic type alias
alias IntBox = Box{int};

// Parameterized generic alias declaration
alias GenericPair<Type> = Type[2];

// Generic function definition
fn Type identity_fn(Type input) <Type> => input;

// Methods on generic types
fn Type Box.get_item(&self) => self.item;

// Method on specific generic instantiation
fn int Box{int}.specific_calc(&self) => self.item * 2;

// Ad-hoc dynamic method on primitive type
fn String int.type_label(int*) @dynamic => "int_primitive";

// Operator overloading for arithmetic and equality
struct Vector2D
{
	float x;
	float y;
}

fn Vector2D Vector2D.add(self, Vector2D other) @operator(+)
{
	return { self.x + other.x, self.y + other.y };
}

fn Vector2D Vector2D.add_assign(&self, Vector2D other) @operator(+=)
{
	self.x += other.x;
	self.y += other.y;
	return *self;
}

fn Vector2D Vector2D.scale_sym(self, float scalar) @operator_s(*)
{
	return { self.x * scalar, self.y * scalar };
}

macro Vector2D Vector2D.sub_from_scalar(self, float scalar) @operator_r(-)
{
	return { scalar - self.x, scalar - self.y };
}

fn bool Vector2D.equals(self, Vector2D other) @operator(==)
{
	return self.x == other.x && self.y == other.y;
}

// Relational operator overloading (<)
fn bool Vector2D.less(self, Vector2D other) @operator(<)
{
	return self.x < other.x;
}

// Container subscript operator overloading
struct IntBuffer
{
	int[16] buffer;
	sz count;
}

fn sz IntBuffer.len(&self) @operator(len) => self.count;
fn int IntBuffer.get(&self, sz idx) @operator([]) => self.buffer[idx];
fn int* IntBuffer.get_ref(&self, sz idx) @operator(&[]) => &self.buffer[idx];
fn void IntBuffer.set(&self, sz idx, int val) @operator([]=)
{
	self.buffer[idx] = val;
}

// Function contracts and parameter lifecycle annotations
<*
 @param [&in] a : "Pointer to non-null value"
 @param [out] out_val : "Destination for written value"
 @param [inout] io_val : "In-out pointer"
 @require *a >= 0 : "Must be non-negative"
 @ensure return >= 0
 @pure
 @return? divide_safe!, CALC_FAILED
*>
fn int? calculate_with_contracts(int* a, int* out_val, int* io_val)
{
	int res = *a * 2;
	*out_val = res;
	*io_val += res;
	return res;
}

// Parameter lifecycle annotations for ownership
<*
 @param [own] a : "Retained pointer"
 @param [drop] b : "Deallocated pointer"
 @param [init] c : "Initialized pointer"
*>
fn void lifecycle_contracts_demo(int* a, int* b, int* c)
{
	*c = 0;
	(void)a;
	(void)b;
}

// Function contract with [&inout] non-null parameter
<*
 @param [&inout] val : "Non-null inout parameter"
*>
fn void non_null_inout_demo(int* val)
{
	*val += 1;
}

// Function with pinpoint parameter contract
<* @require [x] x > 0 : "Must be strictly positive" *>
fn int pinpoint_contract_demo(int x) => x * 2;

// Function with default parameters and short body
fn int compute_offset(int base, int multiplier = 10, int addend = 5) => base * multiplier + addend;

// Function accepting lambda callback
fn int apply_op(int x, SingleIntOp op) => op(x);

// Functions with typed and any varargs
fn int sum_typed_va(int... nums)
{
	int total = 0;
	foreach (n : nums)
	{
		total += n;
	}
	return total;
}

fn void inspect_any_va(args...)
{
	foreach (item : args)
	{
		(void)item.type;
	}
}

// Helper functions for argument splatting
fn void take_three(int a, int b, int c)
{
	(void)a; (void)b; (void)c;
}

struct Point { int x; int y; }

fn void take_two(int a, int b)
{
	(void)a; (void)b;
}

// Parameter with @noalias attribute
fn void copy_noalias(int* dst @noalias, int* src @noalias)
{
	*dst = *src;
}

// Function with @maydiscard attribute
fn int? discardable_call() @maydiscard
{
	return 1;
}

// Function with @naked attribute and assembly
fn void naked_assembly_fn() @naked
{
	asm("");
}

// Function with direct @noinline attribute
fn void noinline_decl_fn() @noinline
{
}

// Type methods with value and pointer self
fn void BaseEntity.translate(&self, float dx, float dy)
{
	self.x += dx;
	self.y += dy;
}

fn float BaseEntity.magnitude_sq(self) => self.x * self.x + self.y * self.y;

// Error handling with Optionals and fault returns
fn int? divide_safe(int num, int denom)
{
	if (denom == 0) return INVALID_ARG~;
	return num / denom;
}

// Rethrow operator helper
fn int? compute_rethrow(int a, int b)
{
	int res = divide_safe(a, b)!;
	return res;
}

// Function remapping optional fault on early return
fn int? rethrow_fault_helper(int a, int b)
{
	return divide_safe(a, b) ?? SUB_FAULT~!;
}

// Static initialization and finalization
fn void init_subsystem() @init(2000)
{
}

fn void shutdown_subsystem() @finalizer(2000)
{
}

// Macro with expression parameters
macro @swap_values(#a, #b)
{
	var temp = #a;
	#a = #b;
	#b = temp;
}

// Macro with contract preconditions
<*
 @require $defined(#a = #b)
*>
macro void @guarded_assign(#a, #b)
{
	#a = #b;
}

// Macro capturing trailing body
macro @repeat_action(int times; @body(idx))
{
	for (int i = 0; i < times; i++)
	{
		@body(i);
	}
}

// Macro with compile-time variadic arguments and splatting
macro int @sum_macro_va(...)
{
	var $acc = 0;
	$for var $i = 0; $i < $vaarg.len; $i++:
		$acc += $vaarg[$i];
	$endfor
	return $acc;
}

// Macro forwarding with sliced variadic arguments
macro void @forward_macro_splat(...)
{
	take_three(...$vaarg);
	take_two(...$vaarg[1..]);
}

// Macro resolving type and stringifying variadic arguments
macro void @create_from_va(...)
{
	String va_name = $stringify($vaarg[0]);
	$Typefrom($vaarg[0]) temp_val = 0;
	(void)va_name;
	(void)temp_val;
}

// Macro method on user type
struct LocalContainer
{
	int item;
	bool occupied;
}

macro LocalContainer.unwrap_or(&self, fallback)
{
	return self.occupied ? self.item : fallback;
}

// Macro with @safemacro attribute
macro int safemacro_add(int a, int b) @safemacro => a + b;

// Macro with @const folding attribute
macro int ct_folded_mult(int $x) @const => $x * 2;

// Top-level constant initialized by compile-time macro
const int CT_FOLDED_VAL = ct_folded_mult(10);

// Builtin visibility attribute
fn void global_builtin_helper() @builtin
{
}

// Function with @local visibility
fn void local_visibility_fn() @local
{
}

// Function with @nostrip attribute
fn void kept_symbol() @nostrip
{
}

// Struct with @tag reflection attribute
struct TaggedRecord @tag("entity_type", "record")
{
	int tag_id;
}

// Explicit reflection metadata attribute
struct ReflectedEntity @reflect
{
	int entity_id;
}

// SIMD storage attribute on vector typedef
typedef SimdFloat4 = float[<4>] @simd;

// Compact and no-padding struct layout attributes
struct CompactData @compact
{
	int a;
	int b;
}

struct NoPadData @nopadding
{
	int x;
	int y;
}

// Calling convention attribute
fn void cdecl_calling_conv() @callconv("cdecl")
{
}

// Alternate calling conventions stdcall and veccall
fn void stdcall_calling_conv() @callconv("stdcall")
{
}

fn void veccall_calling_conv() @callconv("veccall")
{
}

// Custom section placement attribute
fn void section_placement_demo() @section(".text.custom")
{
}

// Weak symbol attribute
fn void weak_symbol_demo() @weak
{
}

// Weaklink global variable attribute
int global_weak_symbol @weaklink = 100;

// Function with @allow_deprecated attribute
fn void invoke_legacy_demo() @allow_deprecated
{
	legacy_function();
}

// Function with @format attribute on args...
fn void format_checker_demo(String fmt, args...) @format(0)
{
	(void)fmt;
}

// Standalone unreachable statement macro
macro void unreachable(String string = "Unreachable statement reached.", ...) @weak @noreturn
{
	$$unreachable();
}

// Function with @noreturn attribute and unreachable
fn void infinite_trap() @noreturn
{
	while (true)
	{
		unreachable("Unreachable loop exit");
	}
}

// Architecture redzone disable attribute
fn void no_redzone_demo() @noredzone
{
}

// Sanitizer suppression attribute
fn void no_sanitize_demo() @nosanitize("address")
{
}

// Stack probe and protection suppression attributes
fn void no_stack_check_demo() @nostackprobe @nostackprotector
{
}

// Stack probe and protector mode configuration attributes
fn void stack_config_demo() @stackprobe("none") @stackprotector("none")
{
}

// Testing attribute and runtime assert
fn void test_runner_demo() @test
{
	assert(true, "Condition must be true");
}

// Benchmark attribute
fn void benchmark_demo() @benchmark
{
}

// Local static variable in function
fn int local_static_demo()
{
	static int invocation_count = 0;
	return ++invocation_count;
}

// Compile-time assertions and built-in reflection
$assert($defined(int));
$assert($Typeof(10)::size == 4);
$echo "Building standalone validation module";

// Compile-time switch statement with expression
macro int @ct_switch(int $x)
{
	$switch $x:
		$case 1:
			return 100;
		$default:
			return 200;
	$endswitch
}

// Compile-time switch statement without expression
macro int @ct_switch_conditionless(int $x)
{
	$switch:
		$case $x > 10:
			return 1;
		$case $x < 0:
			return -1;
		$default:
			return 0;
	$endswitch
}

// Compile-time stringification and evaluation
macro int @eval_demo(#expr)
{
	String expr_name = $stringify(#expr);
	(void)expr_name;
	return #expr;
}

// Compile-time control flow and type inspection
macro void compile_time_inspect($Type)
{
	$if (int)$Type::kind == (int)TypeKind.STRUCT:
		$foreach $member : $Type::members:
			(void)$member.name;
		$endforeach
	$else
		(void)0;
	$endif
}

// Compile-time untyped list and iteration
macro void ct_untyped_list_demo()
{
	var $list = { 1, 2, 3 };
	$foreach $elem : $list:
		(void)$elem;
	$endforeach
}

// Compile-time code expansion with $expand
macro void @expand_code()
{
	$expand("int expanded_eval_var = 55; (void)expanded_eval_var;");
}

// Compile-time error directive guarded by condition
macro void ct_error_demo()
{
	$if false:
		$error("Compile-time error branch");
	$endif
}

// Compile-time binary file embed
const char[4] EMBEDDED_DATA = $embed($$FILE, 4);

// Standalone macro implementations for optional checking
macro fault @catch(#expr) @weak
{
	if (catch f = #expr) return f;
	return {};
}

macro bool @ok(#expr) @weak
{
	if (catch #expr) return false;
	return true;
}

// Standalone memory and atomic operations
macro @volatile_load(#x) @weak => $$volatile_load(&#x);
macro @volatile_store(#x, value) @weak => $$volatile_store(&#x, ($Typeof(#x))value);
macro @atomic_load(#x) @weak => $$atomic_load(&#x, false, 6, $reflect(#x).alignment);
macro @atomic_store(#x, value) @weak => $$atomic_store(&#x, value, false, 6, $reflect(#x).alignment);

// Distinct macro method on any type
macro any any.as_inner2(self) => $$any_make(self.ptr, self.type.inner);

// Exported function with @export and @nodiscard
fn int exported_compute(int x) @export("c3_exported_compute") @nodiscard
{
	return x * 2;
}

// Deprecated function with @deprecated
fn void legacy_function() @deprecated("Use compute_offset instead")
{
}

// Top-level conditional compilation with @feat
fn void conditional_feature_fn() @feat(FEATURE_TEST_GATED)
{
}

// Compound feature-list conditional compilation
fn void compound_feat_demo() @feat(POSIX, WIN32) @feat(!WASM)
{
}

// Thread-local variable declaration
tlocal int thread_local_counter = 0;

// Standalone main entry point exercising language features
fn int main()
{
	// Variable declarations with zero-init and @noinit
	int zeroed_var;
	int uninit_var @noinit;
	uninit_var = 10;

	// Variable usage attributes @used and @unused
	int used_val @used = 5;
	int unused_val @unused = 0;

	// Basic integer and floating-point types
	ichar i8 = -1;
	char u8 = 255;
	short i16 = -32000;
	ushort u16 = 65000;
	int i32 = -100000;
	uint u32 = 100000;
	long i64 = -1000000000L;
	ulong u64 = 1000000000UL;
	int128 i128 = -1;
	uint128 u128 = 1;
	sz signed_size = -10;
	usz unsigned_size = 10;
	iptr int_ptr = 0;
	uptr uint_ptr = 0;
	float f32 = 1.0f;
	double f64 = 2.0d;
	typeid f16_type = float16::typeid;
	typeid f128_type = float128::typeid;

	(void)i8; (void)u8; (void)i16; (void)u16;
	(void)i32; (void)u32; (void)i64; (void)u64;
	(void)i128; (void)u128; (void)signed_size; (void)unsigned_size;
	(void)int_ptr; (void)uint_ptr; (void)f32; (void)f64;
	(void)f16_type; (void)f128_type;

	// Invocations through function, variable, and constant aliases
	(void)&global_fn_alias;
	(void)GLOBAL_CONST_ALIAS;
	global_mut_alias = 200;
	(void)ASCII_CHAR;

	// Compound literal and inferred initialization
	BaseEntity ent = (BaseEntity){ 1, 10.0f, 20.0f };
	ComplexRecord rec = { .id = 100, .l_val = 0x1234L, .config = { true, 1 } };
	rec.anon_sub_field = 7;
	rec.tagged_choice.choice_i = 8;
	(void)rec;

	// Struct splatting initialization
	BaseEntity ent_splat = { ...ent, .x = 15.0f };
	Player plyr = { .base = ent, .health = 100 };
	(void)ent_splat;
	(void)plyr;

	// Substruct value truncation on assignment to base type
	BaseEntity truncated_entity = plyr;
	(void)truncated_entity;

	// Distinct types with methods and aligned typedef
	UserID uid = 500;
	UserID offset_uid = uid.offset(10);
	IntAlign2 aligned_int = (IntAlign2)100;
	int prim_meth_val = (21).double_val();
	(void)offset_uid;
	(void)aligned_int;
	(void)prim_meth_val;

	// Bitstruct instances and distinct attributes
	BigEndianData be_data = { .high = 1, .low = 2 };
	LittleEndianData le_data = { .high = 1, .low = 2 };
	OverlapData ov_data = { .a = 1, .b = 2 };
	StatusMask sm = { .flag_read = true, .flag_write = false };
	StrictData sd = { .id = 1 };
	NumberUnion num_u = { .i_val = 10 };
	CharArrayBacked cab = { .p1 = 1, .p2 = 2 };
	(void)be_data; (void)le_data; (void)ov_data; (void)sm; (void)sd; (void)num_u; (void)cab;

	// Bitwise operations on boolean bitstructs
	StatusMask sm1 = { .flag_read = true };
	StatusMask sm2 = { .flag_write = true };
	StatusMask sm_or = sm1 | sm2;
	StatusMask sm_and = sm1 & sm2;
	StatusMask sm_xor = sm1 ^ sm2;
	StatusMask sm_not = ~sm1;
	(void)sm_or; (void)sm_and; (void)sm_xor; (void)sm_not;

	// Inline constdef conversion
	int inline_st = InlineStatus.STATUS_OK;
	(void)inline_st;

	// Constdef with @constinit initialization
	ConstInitDef cid = 10;
	(void)cid;

	// Arrays and pointer-to-array dereference indexing
	int[4] fixed_arr = { 1, 2, 3, 4 };
	int[*] inferred_arr = { 10, 20, 30 };
	int[3]* arr_ptr = &inferred_arr;
	int indexed_via_ptr = arr_ptr.[1];
	(void)indexed_via_ptr;

	// Multi-dimensional array indexing
	int[2][3] matrix = { { 1, 2 }, { 3, 4 }, { 5, 6 } };
	int matrix_val = matrix[1][0];
	(void)matrix_val;

	// Irregular multi-dimensional array
	int[][2] irregular_arr = { { 1 }, { 2, 3 } };
	(void)irregular_arr;

	// Slice creation, inclusive range, offset, and end index
	int[] slice_full = fixed_arr[..];
	int[] slice_range = fixed_arr[1..3];
	int[] slice_offset = fixed_arr[1:2];
	int slice_last = fixed_arr[^1];
	int[] slice_reverse = fixed_arr[1..^1];
	(void)slice_full; (void)slice_offset; (void)slice_last; (void)slice_reverse;

	// Open-ended slice expressions and end-relative length slicing
	int[] slice_from_start = fixed_arr[2..];
	int[] slice_from_end = fixed_arr[^2..];
	int[] slice_len_from_end = fixed_arr[0 : ^0];
	(void)slice_from_start;
	(void)slice_from_end;
	(void)slice_len_from_end;

	// Slice element assignment and range copying
	int[4] copy_target;
	copy_target[0..1] = 99;
	copy_target[0..2] = fixed_arr[0..2];

	// SIMD vectors, swizzling, and vector arithmetic
	int[<4>] vec_a = { 1, 2, 3, 4 };
	int[<4>] vec_b = vec_a * 2;
	int[<4>] vec_swizzled = vec_b.wzyx;
	(void)vec_swizzled;

	// Wildcard length vector and RGBA swizzling
	int[<*>] inferred_vec = { 10, 20 };
	char[<4>] rgba_vec = { 1, 2, 3, 4 };
	char[<2>] rg_sub = rgba_vec.rg;
	(void)inferred_vec;
	(void)rg_sub;

	// Vector equality and inequality comparisons
	int[<4>] cmp_va = { 1, 5, 3, 7 };
	int[<4>] cmp_vb = { 2, 4, 3, 8 };
	bool vec_eq = cmp_va == cmp_vb;
	bool vec_ne = cmp_va != cmp_vb;
	(void)vec_eq;
	(void)vec_ne;

	// Vector component-range designated initialization
	int[<3>] desig_vec = { .xy = 1, .z = 2 };
	(void)desig_vec;

	// Any type construction, anycast, and type inspection
	int original_int = 42;
	any dynamic_any = $$any_make(&original_int, int::typeid);
	if (dynamic_any.type == int::typeid)
	{
		int* unwrapped_ptr = (int*)dynamic_any.ptr;
		*unwrapped_ptr = 43;
	}

	switch (dynamic_any.type)
	{
		case int:
			break;
		default:
			break;
	}

	// Any type custom method invocation
	any inner_any = dynamic_any.as_inner2();
	(void)inner_any;

	// Type reflection properties
	sz type_align = int::alignment;
	sz type_sz = int::size;
	typeid inner_type = int[]::inner;
	String int_type_name = int::name;
	typeid bitstruct_inner = DeviceFlags::inner;
	(void)int_type_name;
	(void)bitstruct_inner;
	bool has_tag_val = TaggedRecord::has_tag("entity_type");
	String tag_content = TaggedRecord::get_tag("entity_type");
	String qname_str = BaseEntity::qname;
	String cname_str = AlignedHeader::cname;
	bool has_eq = Vector2D::has_equals;
	bool is_ord = int::is_ordered;
	bool is_sub = Player::is_substruct;
	String p0_name = TransformFn::params[0].name;
	typeid ret_t = TransformFn::returns;
	typeid p_struct = TransformFn::param_struct;
	sz m_offset = $reflect(BaseEntity.x).offset;
	sz b_offset = $reflect(DeviceFlags.mode).bitoffset;
	sz b_size = $reflect(DeviceFlags.mode).bitsize;

	(void)type_align; (void)type_sz; (void)inner_type;
	(void)has_tag_val; (void)tag_content; (void)qname_str; (void)cname_str;
	(void)has_eq; (void)is_ord; (void)is_sub;
	(void)p0_name; (void)ret_t; (void)p_struct;
	(void)m_offset; (void)b_offset; (void)b_size;

	// Type methods and parent reflection properties
	String[] entity_methods = BaseEntity::methods;
	typeid player_parent = Player::parent;
	(void)entity_methods;
	(void)player_parent;

	// Generic type reflection properties
	bool is_gen = IntBox::is_generic(Box);
	typeid gen_arg0 = IntBox::generic_args[0];
	String gen_qname = IntBox::generic_qname;
	(void)is_gen; (void)gen_arg0; (void)gen_qname;

	// Enum reflection properties
	sz enum_len = HttpStatus::len;
	String[] enum_names = HttpStatus::names;
	HttpStatus? looked_up = HttpStatus::lookup_field(code, 200);
	HttpStatus from_ord = HttpStatus::from_ordinal(0);
	int ord_val = from_ord.ordinal;
	sz status_members_count = HttpStatus::members.len;
	(void)enum_len; (void)enum_names; (void)looked_up; (void)ord_val; (void)status_members_count;

	// Dynamic interface method invocation and query
	Widget my_widget = { 101 };
	Describable iface_ptr = &my_widget;
	String iface_desc = iface_ptr.describe();
	(void)iface_desc;

	any dyn_any = &my_widget;
	Describable dyn_desc = (Describable)dyn_any;
	if (&dyn_desc.describe)
	{
		String desc_queried = dyn_desc.describe();
		(void)desc_queried;
	}

	// Invocation of optional interface method
	if (&dyn_desc.reset)
	{
		dyn_desc.reset();
	}

	// Anonymous lambda function invocation
	TransformFn lambda_fn = fn int(int v, int s) => v + s;
	int lambda_res = lambda_fn(10, 5);
	(void)lambda_res;

	// Inferred lambda argument syntax
	int inferred_lambda_res = apply_op(5, fn (x) => x * 3);
	(void)inferred_lambda_res;

	// Temporary address operator &&
	int* temp_addr = &&42;
	(void)temp_addr;

	// Temporary address of compound literal array
	int[2]* comp_temp_ptr = &&(int[2]){ 100, 200 };
	(void)comp_temp_ptr;

	// Elvis operator and truthy fallback
	String empty_s = "";
	String elvis_s = empty_s ?: "fallback_string";
	(void)elvis_s;

	// Optional default fallback ??, rethrow !, and force unwrap !!
	int opt_fallback = divide_safe(10, 0) ?? -1;
	int force_unwrapped = divide_safe(20, 2)!!;
	int rethrow_val = compute_rethrow(20, 2) ?? 0;
	(void)opt_fallback;
	(void)force_unwrapped;
	(void)rethrow_val;

	// Optional fault remapping with ??
	int? remapped_fault = divide_safe(10, 0) ?? SUB_FAULT~;
	int? rethrow_remap = rethrow_fault_helper(10, 0);
	(void)remapped_fault;
	(void)rethrow_remap;

	// Automatic method flat-mapping on Optional types
	int? opt_num = 5;
	int? opt_doubled = opt_num.double_val();
	(void)opt_doubled;

	// Bitwise operations and precedence
	int bit_res = (1 | 2) + (~4);
	(void)bit_res;

	// Compound bitshift assignments <<= and >>=
	int shift_val = 8;
	shift_val <<= 1;
	shift_val >>= 1;
	(void)shift_val;

	// If-try unwrap and condition declaration chaining
	if (try int div_res = divide_safe(100, 2) && div_res > 10)
	{
		(void)div_res;
	}

	// If-catch error handling with automatic flow-typing
	int? opt_calc = divide_safe(50, 5);
	if (catch err = opt_calc)
	{
		return 1;
	}
	int flow_typed_val = opt_calc;
	(void)flow_typed_val;

	// Strict if-else bracing
	if (flow_typed_val > 0)
	{
		flow_typed_val++;
	}
	else
	{
		flow_typed_val--;
	}

	// Switch on enum with implicit break and nextcase
	HttpStatus status_val = HttpStatus.OK;
	switch (status_val)
	{
		case OK:
			nextcase;
		case NOT_FOUND_ERR:
		case INTERNAL_ERR:
			break;
	}

	// Switch with case ranges and computed nextcase jumps
	int range_sw = 2;
	switch (range_sw)
	{
		case 1..3:
			nextcase 4;
		case 4:
			nextcase default;
		default:
			break;
	}

	// Backward switch jump forming a loop
	int duff_iter = 2;
	switch (duff_iter)
	{
		case 0:
			break;
		case 1:
			if (--duff_iter >= 0) nextcase 0;
		default:
			nextcase 1;
	}

	// Switch with assignment header
	int sw_header_src = 10;
	int sw_captured;
	switch (sw_captured = sw_header_src, sw_captured)
	{
		case 10:
			break;
		default:
			break;
	}

	// Conditionless runtime switch without expression
	switch
	{
		case flow_typed_val < 0:
			break;
		case flow_typed_val > 0:
			break;
		default:
			break;
	}

	// Runtime evaluation switch with explicit true expression
	switch (true)
	{
		case flow_typed_val > 0:
			break;
		default:
			break;
	}

	// Jumptable switch with @jump
	int jump_index = 1;
	switch (jump_index) @jump
	{
		case 0:
			break;
		case 1:
			break;
		default:
			break;
	}

	// Labelled while loop with break and continue
	int while_idx = 0;
	while WHILE_LABEL: (while_idx < 10)
	{
		while_idx++;
		if (while_idx == 2) continue WHILE_LABEL;
		if (while_idx == 5) break WHILE_LABEL;
	}

	// While loop with condition declaration
	int count_down = 3;
	while (int curr = count_down)
	{
		count_down--;
		if (curr == 1) break;
	}

	// Standard for loop with multiple declarations
	for (int i = 0, int j = 10; i < 5; i++, j--)
	{
		(void)i; (void)j;
	}

	// Infinite for loop syntax
	for (;;)
	{
		break;
	}

	// Foreach by copy, by reference, and reverse
	foreach (val : fixed_arr)
	{
		(void)val;
	}

	foreach (idx, &elem : fixed_arr)
	{
		*elem += (int)idx;
	}

	foreach_r (val : fixed_arr)
	{
		(void)val;
	}

	// Reverse iteration with index and value
	foreach_r (r_idx, r_val : fixed_arr)
	{
		(void)r_idx;
		(void)r_val;
	}

	// Foreach on custom type with overloaded operators
	IntBuffer custom_buf;
	custom_buf.count = 2;
	custom_buf[0] = 100;
	custom_buf[1] = 200;
	foreach (elem : custom_buf)
	{
		(void)elem;
	}

	// Do statement without while
	do
	{
		if (true) break;
	};

	// Standard do-while loop with conditional termination
	int do_count = 2;
	do
	{
		do_count--;
	} while (do_count > 0);

	// Labelled if statement with break
	if IF_LABEL: (true)
	{
		break IF_LABEL;
	}

	// Defer, defer-try, and defer-catch statements
	defer { int def_a = 1; (void)def_a; };
	defer try { int def_t = 1; (void)def_t; };
	defer catch { int def_c = 1; (void)def_c; };
	defer (catch err) { (void)err; };

	// Memory allocation on heap
	void* heap_mem = malloc(32);
	free(heap_mem);

	// Macro invocations with trailing blocks and parameters
	@repeat_action(2; int rep_idx)
	{
		(void)rep_idx;
	};

	int swap_x = 1;
	int swap_y = 2;
	@swap_values(swap_x, swap_y);
	@guarded_assign(swap_x, swap_y);

	int macro_sum = @sum_macro_va(1, 2, 3, 4);
	(void)macro_sum;

	@forward_macro_splat(1, 2, 3);
	@create_from_va(int, 42);

	LocalContainer boxed = { 42, true };
	int unwrapped = boxed.unwrap_or(0);
	(void)unwrapped;

	int safemacro_res = safemacro_add(10, 20);
	(void)safemacro_res;

	// Reverse operator overloading invocation
	Vector2D vec2d_a = { 1.0f, 2.0f };
	Vector2D rev_sub = 10.0f - vec2d_a;
	bool vec_is_less = vec2d_a < rev_sub;
	(void)rev_sub;
	(void)vec_is_less;

	// Function argument splatting
	take_three(...fixed_arr[:3]);
	Point pt = { 10, 20 };
	take_two(...pt);

	// Named parameter call syntax
	int named_arg_res = compute_offset(10, addend: 20);
	(void)named_arg_res;

	// Call-site inlining attribute overrides
	(void)exported_compute(5) @inline;
	(void)exported_compute(5) @noinline;

	// Volatile memory operations
	int vol_target = 10;
	@volatile_store(vol_target, 20);
	int vol_read = @volatile_load(vol_target);
	(void)vol_read;

	// Atomic memory operations and compare-exchange
	int atom_target = 30;
	@atomic_store(atom_target, 40);
	int atom_read = @atomic_load(atom_target);
	(void)atom_read;
	$$compare_exchange(&atom_target, 40, 50, false, false, 6, 6, 0);

	// Built-in @catch and @ok macros on Optionals
	fault caught_fault = @catch(divide_safe(10, 0));
	bool is_valid_opt = @ok(divide_safe(10, 2));
	(void)caught_fault;
	(void)is_valid_opt;

	// Call to sub-module function with module prefix
	int sub_res = submodule::sub_module_compute(5);
	(void)sub_res;

	// Dynamic code resolution using $eval and $Typefrom
	int eval_target_var = 10;
	$eval("eval_target_var") = 20;
	$Typefrom(int::typeid) typefrom_var = 30;
	(void)typefrom_var;

	// Expression reflection using $reflect
	sz reflected_size = $reflect(eval_target_var).size;
	(void)reflected_size;

	// Macro evaluation and code expansion
	@expand_code();
	int eval_res = @eval_demo(100);
	(void)eval_res;
	int ct_sw_res = @ct_switch(1);
	int ct_sw_condless_res = @ct_switch_conditionless(5);
	(void)ct_sw_res;
	(void)ct_sw_condless_res;
	compile_time_inspect(BaseEntity);
	ct_untyped_list_demo();

	// Generic container usage
	Box{int} int_container = { 77, true, 1 };
	int box_val = int_container.get_item();
	int spec_val = int_container.specific_calc();
	(void)box_val;
	(void)spec_val;

	// Generic alias instantiation
	GenericPair{int} gen_pair = { 10, 20 };
	(void)gen_pair;

	// Generic module instantiation and method invocation
	generic_stack::GenericStack{int, 8} gen_stack;
	gen_stack.push(99);

	// Pinpoint contract invocation
	int pinpoint_res = pinpoint_contract_demo(5);
	(void)pinpoint_res;

	// In-out non-null contract invocation
	int inout_target = 10;
	non_null_inout_demo(&inout_target);

	// Compiler built-in location and time constants
	String curr_file = $$FILE;
	String curr_func = $$FUNC;
	int curr_line = $$LINE;
	String curr_mod = $$MODULE;
	String curr_date = $$DATE;
	String curr_time = $$TIME;
	String fpath = $$FILEPATH;
	int line_raw = $$LINE_RAW;
	void*[] t_fns = $$TEST_FNS;
	String[] t_names = $$TEST_NAMES;
	void*[] b_fns = $$BENCHMARK_FNS;
	String[] b_names = $$BENCHMARK_NAMES;
	void* fn_ptr = &$$FUNCTION;
	String fn_name_from_id = $reflect($$FUNCTION).name;

	(void)curr_file; (void)curr_func; (void)curr_line;
	(void)curr_mod; (void)curr_date; (void)curr_time;
	(void)fpath; (void)line_raw; (void)t_fns; (void)t_names;
	(void)b_fns; (void)b_names;
	(void)fn_ptr;
	(void)fn_name_from_id;

	// Null literal assignment
	void* null_ref = null;
	(void)null_ref;

	// Inline assembly string and block statements
	asm("");
	asm { }

	// Invoke C-backend edge case tests
	backend_cases::run_c_backend_tests(false);
	net_utils::init();
	net::utils::init();

	return 0;
}

// Private module section with local visibility
module all_features @private;

// Function with module-private visibility
fn void private_helper_fn()
{
}

// Sub-module demonstrating cross-module visibility
module all_features::submodule;

// Function in sub-module
fn int sub_module_compute(int x)
{
	return x + 10;
}

// POSIX feature-gated module section
module all_features::posix @feat(POSIX);

// POSIX platform-specific function
fn void posix_platform_init()
{
}

// Windows feature-gated module section
module all_features::win32 @feat(WIN32);

// Windows platform-specific function
fn void win32_platform_init()
{
}

// WebAssembly feature-gated module section
module all_features::wasm @feat(WASM);

// WebAssembly export attribute
fn void wasm_entry_demo() @wasm
{
}

// Compiler synthetic runtime hook for enum lookup
module std::core::runtime;
import all_features;

// Enum field lookup implementation macro
macro @enum_lookup($Type, $name, value) @weak
{
	$foreach $val : $Type::values:
		if ($val.$name == value) return $val;
	$endforeach
	return all_features::INVALID_ARG~;
}

// =========================================================================
// C BACKEND REPRODUCTION AND VERIFICATION TESTS
// =========================================================================

// Issue 15: Symbol collisions between flat and nested modules
module net_utils;
fn void init() {}

module net::utils;
fn void init() {}

// Issue 14: Module containing only an enum with associated values
module isolated_enum_module;
enum StandaloneAssocEnum : int (String tag)
{
	FIRST  { "first" },
	SECOND { "second" }
}

// Module exercising backend edge cases
module all_features::backend_cases;
import isolated_enum_module;

fn String get_isolated_enum_tag() => StandaloneAssocEnum.FIRST.tag;

// Issue 1: 64-bit bitstruct top field wiping
bitstruct Bitstruct64 : ulong
{
	uint lo : 0..31;
	uint hi : 32..63;
}

// Issue 3: Size mismatch on lowered floating-point types in structs
struct Float16Pair
{
	float16 a;
	float16 b;
}

struct BFloat16Pair
{
	bfloat a;
	bfloat b;
}

struct Float128Box
{
	float128 val;
}

// Issue 17: Variadic function pointer triggering pre-C23 typedef emission
alias CVariadicFnPtr = fn int(char* fmt, ...);

// Issue 9: Multiple finalizers with ordered priorities
fn void finalizer_prio_1() @finalizer(1) {}
fn void finalizer_prio_2() @finalizer(2) {}
fn void finalizer_prio_default() @finalizer {}

// Helpers for Issue 11: Side-effect order tracking
int g_eval_order_tracker = 0;
fn sz eval_index()
{
	g_eval_order_tracker = g_eval_order_tracker * 10 + 1;
	return 0;
}
fn int eval_value()
{
	g_eval_order_tracker = g_eval_order_tracker * 10 + 2;
	return 5;
}

// Helper for Issue 12: Optional returning function
fn int? opt_val_provider(int v) => v;

// Test function exercising C-backend specific issues
fn void run_c_backend_tests(bool cond)
{
	// Issue 1: 64-bit bitstruct write wiping adjacent fields
	Bitstruct64 bs64;
	bs64.lo = cond ? 1 : 0;
	bs64.hi = cond ? 2 : 0;
	(void)bs64.lo;

	// Issue 2: Signed sat_mul wrong saturation (runtime inputs prevent folding)
	long min_l = cond ? long::min : 0;
	long mul_l = cond ? 1000L : 1;
	long sat_mul_res = $$sat_mul(min_l, mul_l);
	(void)sat_mul_res;

	// Issue 3: Size mismatch on lowered floating-point types
	Float16Pair f16_p = { (float16)(cond ? 1.0 : 0.0), (float16)2.0 };
	BFloat16Pair bf16_p = { (bfloat)(cond ? 1.0 : 0.0), (bfloat)2.0 };
	sz f16_pair_size = Float16Pair::size;
	Float128Box f128_b;
	(void)f16_p;
	(void)bf16_p;
	(void)f16_pair_size;
	(void)f128_b;

	// Issue 4: Narrow negative sign extension & sat_shl
	int neg_one = cond ? -1 : 0;
	short neg_short = (short)neg_one;
	int max_i = cond ? int::max : 0;
	int pop_res = $$popcount(neg_one);
	int pop_short = $$popcount(neg_short);
	int clz_res = $$clz(neg_one);
	int sat_shl_res = $$sat_shl(max_i, 1);
	(void)pop_res;
	(void)pop_short;
	(void)clz_res;
	(void)sat_shl_res;

	// Issue 5: roundeven mapped to round
	float dyn_f = cond ? 1.5f : 0.5f;
	float rnd_even = $$roundeven(dyn_f);
	(void)rnd_even;

	// Issue 6: sysclock
	ulong clk = $$sysclock();
	(void)clk;

	// Issue 7: breakpoint abort (guarded by runtime condition, not constant false)
	if (cond) $$breakpoint();

	// Issue 8: Ternary temporary pointer and slice dangling
	int* ternary_ptr = cond ? &&5 : &&7;
	int[] ternary_slice = cond ? (int[]){ 1, 2 } : (int[]){ 3, 4 };
	(void)ternary_ptr;
	(void)ternary_slice;

	// Issue 10: Null member address calculation and load through null address
	all_features::BaseEntity* null_entity = null;
	float* null_field_addr = &null_entity.x;
	(void)null_field_addr;
	if (cond)
	{
		float null_loaded_val = null_entity.x;
		(void)null_loaded_val;
	}

	// Issue 11: Compound assignment evaluation ordering
	int[2] target_arr = { 10, 20 };
	target_arr[eval_index()] += eval_value();

	// Issue 12: Binary operations on Optionals skipping emission of fallback label
	int? opt_shifted = opt_val_provider(3) << 2;
	(void)opt_shifted;

	// Issue 13: Integer overflow for trap-on-wrap (runtime inputs prevent folding)
	int dyn_max_s = cond ? int::max : 0;
	uint dyn_max_u = cond ? uint::max : 0;
	int signed_wrap = dyn_max_s + 1;
	uint unsigned_wrap = dyn_max_u + 1;
	(void)signed_wrap;
	(void)unsigned_wrap;

	// Issue 14: Link check for isolated enum module
	String assoc_tag = get_isolated_enum_tag();
	(void)assoc_tag;

	// Issue 17: C-style variadic function pointer usage
	CVariadicFnPtr va_fp = null;
	(void)va_fp;

	// Issue 18: Safe mode checks (emitted to C, guarded dynamically)
	if (cond)
	{
		int[2] bounds_arr = { 1, 2 };
		sz dynamic_idx = cond ? 5 : 0;
		int oob = bounds_arr[dynamic_idx];
		int zero_div = cond ? 0 : 1;
		int div_zero = oob / zero_div;
		int[] bad_slice = bounds_arr[dynamic_idx..dynamic_idx + 1];
		all_features::HttpStatus bad_ord = all_features::HttpStatus::from_ordinal((int)dynamic_idx + 100);
		(void)div_zero;
		(void)bad_slice;
		(void)bad_ord;
	}

	// Issue 19: Unhandled builtins falling to default 0 in C backend
	int[<2>] vec_to_rev = { 1, 2 };
	int[<2>] vec_revers_res = $$reverse(vec_to_rev);
	(void)vec_revers_res;

	int r_mode = $$get_rounding_mode();
	(void)r_mode;

	uint u_atom = 0;
	uint inc_wrap_res = $$atomic_fetch_inc_wrap(&u_atom, 10u, false, 6, uint::alignment);
	uint dec_wrap_res = $$atomic_fetch_dec_wrap(&u_atom, 10u, false, 6, uint::alignment);
	(void)inc_wrap_res;
	(void)dec_wrap_res;
}