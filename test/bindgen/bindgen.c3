module lsp::bindgen_test @test;

import lsp::bindgen;
import lsp::bindgen_test::posix_signal;
import std;

fn void test_snake_case_conversion()
{
	test::eq(bindgen::to_snake_case(tmem, "InitWindow"), "init_window");
	test::eq(bindgen::to_snake_case(tmem, "GetFPS"), "get_fps");
	test::eq(bindgen::to_snake_case(tmem, "LoadUTF8"), "load_utf8");
	test::eq(bindgen::to_snake_case(tmem, "isWindowReady"), "is_window_ready");
	test::eq(bindgen::to_snake_case(tmem, "DrawLine3D"), "draw_line3d");
	test::eq(bindgen::to_snake_case(tmem, "LoadTexture2D"), "load_texture2d");
}

fn void test_keyword_sanitization()
{
	test::eq(bindgen::to_snake_case(tmem, "default"), "default_");
	test::eq(bindgen::to_snake_case(tmem, "struct"), "struct_");
	test::eq(bindgen::to_snake_case(tmem, "switch"), "switch_");
	test::eq(bindgen::to_snake_case(tmem, "return"), "return_");
	test::eq(bindgen::to_snake_case(tmem, "main"), "main_");
}

fn void test_type_sanitization_and_prefix()
{
	test::eq(bindgen::sanitize_c3_type_name(tmem, "size_t", ""), "usz");
	test::eq(bindgen::sanitize_c3_type_name(tmem, "uint32_t", ""), "uint");
	test::eq(bindgen::sanitize_c3_type_name(tmem, "va_list", ""), "CVaList");

	// ALL_CAPS C type with prefix
	test::eq(bindgen::sanitize_c3_type_name(tmem, "HANDLE", "Win32"), "Win32_HANDLE");

	// Lowercase snake_case C type
	test::eq(bindgen::sanitize_c3_type_name(tmem, "sqlite3_stmt", "Sqlite3"), "Sqlite3Stmt");

	// Normal type with prefix applied
	test::eq(bindgen::sanitize_c3_type_name(tmem, "Image", "RL"), "RLImage");
	test::eq(bindgen::sanitize_c3_type_name(tmem, "RLTexture", "RL"), "RLTexture");
	test::eq(bindgen::sanitize_c3_type_name(tmem, "float16", ""), "Float16");
}

fn void test_c_type_mapping()
{
	HashSet{String} tags;
	tags.tinit();
	test::eq(bindgen::map_c_type_to_c3(tmem, "const char *", "", &tags, true), "ZString");
	test::eq(bindgen::map_c_type_to_c3(tmem, "const char *", "", &tags, false), "ZString");
	test::eq(bindgen::map_c_type_to_c3(tmem, "char *", "", &tags, false), "char*");
	test::eq(bindgen::map_c_type_to_c3(tmem, "long", "", &tags, false), "CLong");
	test::eq(bindgen::map_c_type_to_c3(tmem, "unsigned long", "", &tags, false), "CULong");
	test::eq(bindgen::map_c_type_to_c3(tmem, "int *", "", &tags, false), "int*");
	test::eq(bindgen::map_c_type_to_c3(tmem, "void **", "", &tags, false), "void**");
	test::eq(bindgen::map_c_type_to_c3(tmem, "void *[2]", "", &tags, false), "void*[2]");
	test::eq(bindgen::map_c_type_to_c3(tmem, "int *[10]", "", &tags, false), "int*[10]");
	test::eq(bindgen::map_c_type_to_c3(tmem, "const char **", "", &tags, true), "ZString*");
	test::eq(bindgen::map_c_type_to_c3(tmem, "const char *const *", "", &tags, true), "ZString*");
	test::eq(bindgen::map_c_type_to_c3(tmem, "char *const *", "", &tags, true), "char**");
	test::eq(bindgen::map_c_type_to_c3(tmem, "char *const", "", &tags, true), "char*");
	test::eq(bindgen::map_c_type_to_c3(tmem, "struct __va_list_tag *", "", &tags, true), "CVaList");
	test::eq(bindgen::map_c_type_to_c3(tmem, "va_list", "", &tags, true), "CVaList");
	test::eq(bindgen::map_c_type_to_c3(tmem, "png_const_charp", "", &tags, true, "const char *"), "ZString");
	test::eq(bindgen::map_c_type_to_c3(tmem, "png_charp", "", &tags, true, "char *"), "char*");
}

fn void test_clang_ast_json_mock_emission()
{
	String mock_json = `
	{
		"kind": "TranslationUnitDecl",
		"inner": [
			{
				"kind": "FunctionDecl",
				"name": "InitWindow",
				"loc": { "file": "test_lib.h" },
				"type": { "qualType": "void (int, int, const char *)" },
				"inner": [
					{ "kind": "ParmVarDecl", "name": "width", "type": { "qualType": "int" } },
					{ "kind": "ParmVarDecl", "name": "height", "type": { "qualType": "int" } },
					{ "kind": "ParmVarDecl", "name": "title", "type": { "qualType": "const char *" } }
				]
			},
			{
				"kind": "RecordDecl",
				"name": "Vector2",
				"tagUsed": "struct",
				"completeDefinition": true,
				"loc": { "file": "test_lib.h" },
				"inner": [
					{ "kind": "FieldDecl", "name": "x", "type": { "qualType": "float" } },
					{ "kind": "FieldDecl", "name": "y", "type": { "qualType": "float" } }
				]
			},
			{
				"kind": "EnumDecl",
				"name": "MouseButton",
				"loc": { "file": "test_lib.h" },
				"inner": [
					{ "kind": "EnumConstantDecl", "name": "MOUSE_BUTTON_LEFT" },
					{ "kind": "EnumConstantDecl", "name": "MOUSE_BUTTON_RIGHT" }
				]
			}
		]
	}
	`;

	Object* root_obj = json::tparse(mock_json)!!;

	BindgenOptions opts = {
		.header_path = "test_lib.h",
		.module_name = "test_lib",
		.type_prefix = "RL",
		.strip_func_prefix = ""
	};

	CTranslationUnit tu;
	tu.init(tmem);

	bindgen::parse_clang_ast_json(tmem, &tu, root_obj, opts);

	test::eq(tu.functions.len(), 1);
	test::eq(tu.structs.len(), 1);
	test::eq(tu.enums.len(), 1);

	String code = bindgen::emit_c3_bindings(tmem, &tu, opts);

	assert(code.contains("module test_lib;"));
	assert(code.contains("enum RLMouseButton\n{"));
	assert(code.contains("\tLEFT,\n\tRIGHT\n"));
	assert(code.contains("struct RLVector2"));
	assert(code.contains("float x;"));
	assert(code.contains("float y;"));
	assert(code.contains("extern fn void init_window(int width, int height, ZString title) @cname(\"InitWindow\");"));
}

fn void test_transitive_system_typedef_emission()
{
	String mock_json = `
	{
		"kind": "TranslationUnitDecl",
		"inner": [
			{
				"kind": "TypedefDecl",
				"name": "off_t",
				"loc": { "file": "/usr/include/sys/types.h" },
				"type": {
					"qualType": "__off_t",
					"desugaredQualType": "long int"
				}
			},
			{
				"kind": "FunctionDecl",
				"name": "seek_file",
				"loc": { "file": "my_header.h" },
				"type": { "qualType": "off_t (int, off_t)" },
				"inner": [
					{ "kind": "ParmVarDecl", "name": "fd", "type": { "qualType": "int" } },
					{ "kind": "ParmVarDecl", "name": "offset", "type": { "qualType": "off_t" } }
				]
			}
		]
	}
	`;

	Object* root_obj = json::tparse(mock_json)!!;

	BindgenOptions opts = {
		.header_path = "my_header.h",
		.module_name = "my_header",
		.type_prefix = ""
	};

	CTranslationUnit tu;
	tu.init(tmem);

	bindgen::parse_clang_ast_json(tmem, &tu, root_obj, opts);

	test::eq(tu.functions.len(), 1);
	test::eq(tu.typedefs.len(), 1);

	String code = bindgen::emit_c3_bindings(tmem, &tu, opts);

	// Verifies that OffT was synthesized as an alias to CLong
	assert(code.contains("alias OffT = CLong;"));
	assert(code.contains("extern fn OffT seek_file(int fd, OffT offset) @cname(\"seek_file\");"));
}

fn void test_opaque_and_complete_struct_deduplication()
{
	String mock_json = `
	{
		"kind": "TranslationUnitDecl",
		"inner": [
			{
				"kind": "RecordDecl",
				"name": "Fts5Tokenizer",
				"tagUsed": "struct",
				"completeDefinition": false,
				"loc": { "file": "test.h" }
			},
			{
				"kind": "RecordDecl",
				"name": "fts5_tokenizer",
				"tagUsed": "struct",
				"completeDefinition": true,
				"loc": { "file": "test.h" },
				"inner": [
					{ "kind": "FieldDecl", "name": "x_create", "type": { "qualType": "void *" } },
					{ "kind": "FieldDecl", "name": "x_delete", "type": { "qualType": "void *" } }
				]
			}
		]
	}
	`;

	Object* root_obj = json::tparse(mock_json)!!;

	BindgenOptions opts = {
		.header_path = "test.h",
		.module_name = "test",
		.type_prefix = ""
	};

	CTranslationUnit tu;
	tu.init(tmem);

	bindgen::parse_clang_ast_json(tmem, &tu, root_obj, opts);

	test::eq(tu.structs.len(), 1);
	test::eq(tu.structs.get(0).c3_name, "Fts5Tokenizer");
	test::eq(tu.structs.get(0).is_opaque, false);
	test::eq(tu.structs.get(0).fields.len(), 2);

	String code = bindgen::emit_c3_bindings(tmem, &tu, opts);
	assert(!code.contains("typedef Fts5Tokenizer = void;"));
	assert(code.contains("struct Fts5Tokenizer\n{\n\tvoid* x_create;\n\tvoid* x_delete;\n}"));
}

fn void test_nested_record_decl_in_struct()
{
	String mock_json = `
	{
		"kind": "TranslationUnitDecl",
		"inner": [
			{
				"kind": "RecordDecl",
				"name": "sqlite3_index_info",
				"tagUsed": "struct",
				"completeDefinition": true,
				"loc": { "file": "test.h" },
				"inner": [
					{
						"kind": "RecordDecl",
						"name": "sqlite3_index_constraint",
						"tagUsed": "struct",
						"completeDefinition": true,
						"loc": { "file": "test.h" },
						"inner": [
							{ "kind": "FieldDecl", "name": "iColumn", "type": { "qualType": "int" } }
						]
					},
					{
						"kind": "FieldDecl",
						"name": "nConstraint",
						"type": { "qualType": "int" }
					},
					{
						"kind": "FieldDecl",
						"name": "aConstraint",
						"type": { "qualType": "struct sqlite3_index_constraint *" }
					}
				]
			}
		]
	}
	`;

	Object* root_obj = json::tparse(mock_json)!!;

	BindgenOptions opts = {
		.header_path = "test.h",
		.module_name = "test",
		.type_prefix = ""
	};

	CTranslationUnit tu;
	tu.init(tmem);

	bindgen::parse_clang_ast_json(tmem, &tu, root_obj, opts);

	test::eq(tu.structs.len(), 2);
	test::eq(tu.structs.get(0).c3_name, "Sqlite3IndexConstraint");
	test::eq(tu.structs.get(1).c3_name, "Sqlite3IndexInfo");

	String code = bindgen::emit_c3_bindings(tmem, &tu, opts);
	assert(code.contains("struct Sqlite3IndexConstraint\n{\n\tint i_column;\n}"));
	assert(code.contains("Sqlite3IndexConstraint* a_constraint;"));
}

fn void test_bindgen_improvements()
{
	String mock_json = `
	{
		"kind": "TranslationUnitDecl",
		"inner": [
			{
				"kind": "FunctionDecl",
				"name": "sqlite3_errmsg",
				"loc": { "file": "test.h" },
				"type": { "qualType": "const char *(sqlite3 *)" },
				"inner": [
					{ "kind": "ParmVarDecl", "name": "db", "type": { "qualType": "sqlite3 *" } }
				]
			},
			{
				"kind": "FunctionDecl",
				"name": "sqlite3_exec",
				"loc": { "file": "test.h" },
				"type": { "qualType": "int (sqlite3 *, const char *, int (*)(void *, int, char **, char **), void *, char **)" },
				"inner": [
					{ "kind": "ParmVarDecl", "name": "db", "type": { "qualType": "sqlite3 *" } },
					{ "kind": "ParmVarDecl", "name": "sql", "type": { "qualType": "const char *" } },
					{ "kind": "ParmVarDecl", "name": "callback", "type": { "qualType": "int (*)(void *, int, char **, char **)" } },
					{ "kind": "ParmVarDecl", "name": "arg", "type": { "qualType": "void *" } },
					{ "kind": "ParmVarDecl", "name": "errmsg", "type": { "qualType": "char **" } }
				]
			}
		]
	}
	`;

	Object* root_obj = json::tparse(mock_json)!!;

	BindgenOptions opts = {
		.header_path = "test.h",
		.module_name = "sqlite3",
		.type_prefix = ""
	};

	CTranslationUnit tu;
	tu.init(tmem);

	bindgen::parse_clang_ast_json(tmem, &tu, root_obj, opts);

	String code = bindgen::emit_c3_bindings(tmem, &tu, opts);

	assert(code.contains("extern fn ZString errmsg("));
	assert(code.contains("extern fn int exec("));
	assert(code.contains("alias ExecCallbackFn = fn int(void*, int, char**, char**);"));
	assert(code.contains("ExecCallbackFn callback"));
}

fn void test_c3_types_not_emitted_as_aliases()
{
	String mock_json = `
	{
		"kind": "TranslationUnitDecl",
		"inner": [
			{
				"kind": "TypedefDecl",
				"name": "uint64_t",
				"loc": { "file": "/usr/include/stdint.h" },
				"type": {
					"qualType": "unsigned long",
					"desugaredQualType": "unsigned long"
				}
			},
			{
				"kind": "TypedefDecl",
				"name": "ulong",
				"loc": { "file": "/usr/include/sys/types.h" },
				"type": {
					"qualType": "unsigned long",
					"desugaredQualType": "unsigned long"
				}
			},
			{
				"kind": "TypedefDecl",
				"name": "off_t",
				"loc": { "file": "/usr/include/sys/types.h" },
				"type": {
					"qualType": "__off_t",
					"desugaredQualType": "long int"
				}
			},
			{
				"kind": "FunctionDecl",
				"name": "process_data",
				"loc": { "file": "test_types.h" },
				"type": { "qualType": "void (uint64_t, ulong, size_t, off_t)" },
				"inner": [
					{ "kind": "ParmVarDecl", "name": "id", "type": { "qualType": "uint64_t" } },
					{ "kind": "ParmVarDecl", "name": "flags", "type": { "qualType": "ulong" } },
					{ "kind": "ParmVarDecl", "name": "len", "type": { "qualType": "size_t" } },
					{ "kind": "ParmVarDecl", "name": "offset", "type": { "qualType": "off_t" } }
				]
			}
		]
	}
	`;

	Object* root_obj = json::tparse(mock_json)!!;

	BindgenOptions opts = {
		.header_path = "test_types.h",
		.module_name = "test_types",
		.type_prefix = ""
	};

	CTranslationUnit tu;
	tu.init(tmem);

	bindgen::parse_clang_ast_json(tmem, &tu, root_obj, opts);

	String code = bindgen::emit_c3_bindings(tmem, &tu, opts);

	assert(code.contains("alias OffT = CLong;"));
	assert(!code.contains("alias ulong"));
	assert(!code.contains("alias usz"));
	assert(code.contains("extern fn void process_data(ulong id, CULong flags, usz len, OffT offset) @cname(\"process_data\");"));
}

fn void test_function_prefix_stripping_with_versioned_module()
{
	String mock_json = `
	{
		"kind": "TranslationUnitDecl",
		"inner": [
			{
				"kind": "FunctionDecl",
				"name": "glfwInit",
				"loc": { "file": "glfw3.h" },
				"type": { "qualType": "int (void)" }
			},
			{
				"kind": "FunctionDecl",
				"name": "glfwCreateWindow",
				"loc": { "file": "glfw3.h" },
				"type": { "qualType": "void* (int, int)" },
				"inner": [
					{ "kind": "ParmVarDecl", "name": "width", "type": { "qualType": "int" } },
					{ "kind": "ParmVarDecl", "name": "height", "type": { "qualType": "int" } }
				]
			}
		]
	}
	`;

	Object* root_obj = json::tparse(mock_json)!!;

	BindgenOptions opts = {
		.header_path = "glfw3.h",
		.module_name = "glfw3",
		.type_prefix = ""
	};

	CTranslationUnit tu;
	tu.init(tmem);

	bindgen::parse_clang_ast_json(tmem, &tu, root_obj, opts);

	String code = bindgen::emit_c3_bindings(tmem, &tu, opts);

	assert(code.contains("extern fn int init() @cname(\"glfwInit\");"));
	assert(code.contains("extern fn void* create_window(int width, int height) @cname(\"glfwCreateWindow\");"));
}

fn void test_module_name_sanitization()
{
	test::eq(bindgen::sanitize_module_name(tmem, "skl-tplg-interface"), "skl_tplg_interface");
	test::eq(bindgen::sanitize_module_name(tmem, "cpu-set"), "cpu_set");
	test::eq(bindgen::sanitize_module_name(tmem, "FILE"), "file");
	test::eq(bindgen::sanitize_module_name(tmem, "__FILE"), "file");
	test::eq(bindgen::sanitize_module_name(tmem, "__fpos64_t"), "fpos64_t");
	test::eq(bindgen::sanitize_module_name(tmem, "1000_sg"), "c_1000_sg");
	test::eq(bindgen::sanitize_module_name(tmem, "long-double"), "long_double");
}

fn void test_type_name_sanitization_rules()
{
	test::eq(bindgen::sanitize_c3_type_name(tmem, "HEADER", ""), "Header");
	test::eq(bindgen::sanitize_c3_type_name(tmem, "IOFILE", ""), "Iofile");
	test::eq(bindgen::sanitize_c3_type_name(tmem, "SKLTKNS", ""), "Skltkns");
	test::eq(bindgen::sanitize_c3_type_name(tmem, "_ns_flagdata", ""), "NsFlagdata");
	test::eq(bindgen::sanitize_c3_type_name(tmem, "__pthread_mutex_s", ""), "PthreadMutexS");
	test::eq(bindgen::sanitize_c3_type_name(tmem, "_G_fpos_t", ""), "GFposT");
}

fn void test_restrict_parameter_emits_noalias()
{
	String mock_json = `
	{
		"kind": "TranslationUnitDecl",
		"inner": [
			{
				"kind": "FunctionDecl",
				"name": "inet_pton",
				"loc": { "file": "test_inet.h" },
				"type": { "qualType": "int (int, const char *restrict, void *restrict)" },
				"inner": [
					{ "kind": "ParmVarDecl", "name": "af", "type": { "qualType": "int" } },
					{ "kind": "ParmVarDecl", "name": "cp", "type": { "qualType": "const char *restrict" } },
					{ "kind": "ParmVarDecl", "name": "buf", "type": { "qualType": "void *restrict" } }
				]
			}
		]
	}
	`;

	Object* root_obj = json::tparse(mock_json)!!;

	BindgenOptions opts = {
		.header_path = "test_inet.h",
		.module_name = "test_inet",
		.strip_func_prefix = "inet_"
	};

	CTranslationUnit tu;
	tu.init(tmem);

	bindgen::parse_clang_ast_json(tmem, &tu, root_obj, opts);

	String code = bindgen::emit_c3_bindings(tmem, &tu, opts);

	assert(code.contains("extern fn int pton(int af, ZString cp, void* buf @noalias) @cname(\"inet_pton\");"));
}

fn void test_desugared_qual_type_and_bitfield_struct_emission()
{
	String mock_json = `
	{
		"kind": "TranslationUnitDecl",
		"inner": [
			{
				"kind": "RecordDecl",
				"name": "sg_header",
				"tagUsed": "struct",
				"completeDefinition": true,
				"loc": { "file": "test_sg.h" },
				"inner": [
					{
						"kind": "FieldDecl",
						"name": "reply_len",
						"type": { "qualType": "int" }
					},
					{
						"kind": "FieldDecl",
						"name": "twelve_byte",
						"isBitfield": true,
						"type": {
							"qualType": "__u32",
							"desugaredQualType": "unsigned int"
						}
					},
					{
						"kind": "FieldDecl",
						"name": "uptr",
						"type": { "qualType": "void *" }
					}
				]
			}
		]
	}
	`;

	Object* root_obj = json::tparse(mock_json)!!;

	BindgenOptions opts = {
		.header_path = "test_sg.h",
		.module_name = "test_sg"
	};

	CTranslationUnit tu;
	tu.init(tmem);

	bindgen::parse_clang_ast_json(tmem, &tu, root_obj, opts);

	String code = bindgen::emit_c3_bindings(tmem, &tu, opts);

	assert(code.contains("struct SgHeader\n{"));
	assert(code.contains("int reply_len;"));
	assert(code.contains("uint twelve_byte;"));
	assert(code.contains("void* uptr_;"));
	assert(!code.contains("bitstruct"));
	assert(!code.contains(": 1;"));
}

fn void test_type_name_lowercase_guarantee_and_length_limit()
{
	test::eq(bindgen::sanitize_c3_type_name(tmem, "u32", ""), "U32_t");
	test::eq(bindgen::sanitize_c3_type_name(tmem, "u8", ""), "U8_t");
	test::eq(bindgen::sanitize_c3_type_name(tmem, "u16", ""), "U16_t");

	String long_name = "LongTypeIdentifierWithMoreThanOneHundredAndTwentySevenCharactersThatMustBeTruncatedByTheSanitizerToRemainValidWithinC3GrammarLimits";
	String sanitized = bindgen::sanitize_c3_type_name(tmem, long_name, "");
	assert(sanitized.len <= 127);
}

fn void test_function_pointer_field_and_array_type_extraction()
{
	String mock_json = `
	{
		"kind": "TranslationUnitDecl",
		"inner": [
			{
				"kind": "RecordDecl",
				"name": "HandlerTable",
				"tagUsed": "struct",
				"completeDefinition": true,
				"loc": { "file": "test_handlers.h" },
				"inner": [
					{
						"kind": "FieldDecl",
						"name": "init_fn",
						"type": { "qualType": "int (*)(void)" }
					},
					{
						"kind": "FieldDecl",
						"name": "matrix",
						"type": { "qualType": "ExternalMatrix[3][3]" }
					}
				]
			},
			{
				"kind": "FunctionDecl",
				"name": "process_external",
				"loc": { "file": "test_handlers.h" },
				"type": { "qualType": "void (ExternalHandle)" },
				"inner": [
					{
						"kind": "ParmVarDecl",
						"name": "handle",
						"type": { "qualType": "ExternalHandle" }
					}
				]
			}
		]
	}
	`;

	Object* root_obj = json::tparse(mock_json)!!;

	BindgenOptions opts = {
		.header_path = "test_handlers.h",
		.module_name = "test_handlers"
	};

	CTranslationUnit tu;
	tu.init(tmem);

	bindgen::parse_clang_ast_json(tmem, &tu, root_obj, opts);

	String code = bindgen::emit_c3_bindings(tmem, &tu, opts);

	assert(code.contains("alias HandlerTableInitFnFn = fn int();"));
	assert(code.contains("HandlerTableInitFnFn init_fn;"));
	assert(!code.contains("Int (*)(void)"));
	assert(code.contains("typedef ExternalMatrix = void;"));
	assert(!code.contains("struct ExternalMatrix[3][3"));
	assert(code.contains("typedef ExternalHandle = void;"));
}

fn void test_module_name_length_limit_and_zero_length_array()
{
	String long_mod = "libvirt_gconfig_domain_graphics_spice";
	String sanitized_mod = bindgen::sanitize_module_name(tmem, long_mod);
	assert(sanitized_mod.len <= 31);
	test::eq(sanitized_mod, "libvirt_gconfig_domain_graphics");

	HashSet{String} tags;
	tags.tinit();
	String code_zero_arr = bindgen::map_c_type_to_c3(tmem, "char[0]", "", &tags, is_field: true);
	test::eq(code_zero_arr, "char[*]");
}

fn void test_alias_target_missing_type_and_duplicate_alias()
{
	String mock_json = `
	{
		"kind": "TranslationUnitDecl",
		"inner": [
			{
				"kind": "TypedefDecl",
				"name": "vki_u16",
				"loc": { "file": "test_alias.h" },
				"type": { "qualType": "unsigned short" }
			},
			{
				"kind": "TypedefDecl",
				"name": "VkiU16",
				"loc": { "file": "test_alias.h" },
				"type": { "qualType": "unsigned short" }
			},
			{
				"kind": "TypedefDecl",
				"name": "SessionHandle",
				"loc": { "file": "test_alias.h" },
				"type": { "qualType": "struct ne_session_s *" }
			},
			{
				"kind": "RecordDecl",
				"name": "SelfRef",
				"tagUsed": "struct",
				"completeDefinition": true,
				"loc": { "file": "test_alias.h" },
				"inner": [
					{
						"kind": "FieldDecl",
						"name": "cycle",
						"type": { "qualType": "struct SelfRef" }
					}
				]
			}
		]
	}
	`;

	Object* root_obj = json::tparse(mock_json)!!;

	BindgenOptions opts = {
		.header_path = "test_alias.h",
		.module_name = "test_alias"
	};

	CTranslationUnit tu;
	tu.init(tmem);

	bindgen::parse_clang_ast_json(tmem, &tu, root_obj, opts);

	String code = bindgen::emit_c3_bindings(tmem, &tu, opts);

	// Missing struct target in typedef synthesized as opaque struct
	assert(code.contains("typedef NeSessionS = void;"));
	assert(code.contains("alias SessionHandle = NeSessionS*;"));

	// Duplicate alias VkiU16 emitted only once
	sz first_idx = code.index_of("alias VkiU16 = ushort;") ?? 0;
	assert(first_idx > 0);
	sz second_idx = code[first_idx + 22..].index_of("alias VkiU16 = ushort;") ?? 0;
	assert(second_idx == 0);

	// Recursive self-containment converted to pointer
	assert(code.contains("void* cycle;"));
	assert(!code.contains("SelfRef cycle;"));
}

fn void test_large_enum_variant_uint_backing_and_recursive_typedef()
{
	String mock_json = `
	{
		"kind": "TranslationUnitDecl",
		"inner": [
			{
				"kind": "EnumDecl",
				"name": "SecretFlags",
				"loc": { "file": "test_flags.h" },
				"inner": [
					{
						"kind": "EnumConstantDecl",
						"name": "FLAG_LOW",
						"inner": [
							{ "kind": "ConstantExpr", "value": "1" }
						]
					},
					{
						"kind": "EnumConstantDecl",
						"name": "FLAG_HIGH",
						"inner": [
							{ "kind": "ConstantExpr", "value": "2147483648" }
						]
					}
				]
			},
			{ "kind": "RecordDecl", "name": "mfxSyncPoint", "tagUsed": "struct", "loc": { "file": "test_flags.h" } },
			{
				"kind": "TypedefDecl",
				"name": "mfxSyncPoint",
				"loc": { "file": "test_flags.h" },
				"type": { "qualType": "struct mfxSyncPoint *" },
				"inner": [ { "kind": "PointerType", "inner": [ { "kind": "RecordType", "decl": { "kind": "RecordDecl", "name": "mfxSyncPoint" } } ] } ]
			}
		]
	}
	`;

	Object* root_obj = json::tparse(mock_json)!!;

	BindgenOptions opts = {
		.header_path = "test_flags.h",
		.module_name = "test_flags"
	};

	CTranslationUnit tu;
	tu.init(tmem);

	bindgen::parse_clang_ast_json(tmem, &tu, root_obj, opts);

	String code = bindgen::emit_c3_bindings(tmem, &tu, opts);

	// Large enum backing type inferred as uint with 'u' suffix literal
	assert(code.contains("constdef SecretFlags : uint\n{"));
	assert(code.contains("\tHIGH = 2147483648u"));

	assert(code.contains("typedef _MfxSyncPoint = void;"));
	assert(code.contains("alias MfxSyncPoint = _MfxSyncPoint*;"));
}

fn void test_external_and_empty_enum_resolution()
{
	String mock_json = `
	{
		"kind": "TranslationUnitDecl",
		"inner": [
			{
				"kind": "EnumDecl",
				"name": "weston_renderer_type",
				"loc": { "file": "included.h" },
				"inner": [
					{
						"kind": "EnumConstantDecl",
						"name": "WESTON_RENDERER_AUTO",
						"inner": [
							{ "kind": "ConstantExpr", "value": "0" }
						]
					}
				]
			},
			{
				"kind": "RecordDecl",
				"name": "weston_x11_backend_config",
				"tagUsed": "struct",
				"completeDefinition": true,
				"loc": { "file": "target.h" },
				"inner": [
					{
						"kind": "FieldDecl",
						"name": "renderer",
						"type": { "qualType": "enum weston_renderer_type" }
					}
				]
			}
		]
	}
	`;

	Object* root_obj = json::tparse(mock_json)!!;

	BindgenOptions opts = {
		.header_path = "target.h",
		.module_name = "target"
	};

	CTranslationUnit tu;
	tu.init(tmem);

	bindgen::parse_clang_ast_json(tmem, &tu, root_obj, opts);

	String code = bindgen::emit_c3_bindings(tmem, &tu, opts);

	assert(code.contains("enum WestonRendererType\n{"));
	assert(code.contains("WESTON_RENDERER_AUTO"));
	assert(code.contains("WestonRendererType renderer;"));
}

fn void test_vector_attribute_ast_and_fallback_parsing()
{
	String mock_json = `
	{
		"kind": "TranslationUnitDecl",
		"inner": [
			{
				"kind": "TypedefDecl",
				"name": "v4sf",
				"loc": { "file": "test_vec.h" },
				"type": {
					"qualType": "float __attribute__((__vector_size__(16)))"
				},
				"inner": [
					{
						"kind": "VectorType",
						"numElements": 4,
						"type": { "qualType": "float __attribute__((__vector_size__(16)))" },
						"inner": [
							{ "kind": "BuiltinType", "type": { "qualType": "float" } }
						]
					}
				]
			}
		]
	}
	`;

	Object* root_obj = json::tparse(mock_json)!!;

	BindgenOptions opts = {
		.header_path = "test_vec.h",
		.module_name = "test_vec"
	};

	CTranslationUnit tu;
	tu.init(tmem);

	bindgen::parse_clang_ast_json(tmem, &tu, root_obj, opts);

	String code = bindgen::emit_c3_bindings(tmem, &tu, opts);

	assert(code.contains("alias V4sf = float[<4>];"));
	assert(!code.contains(")))"));
}

fn void test_c99_complex_types_mapping()
{
	String mock_json = `
	{
		"kind": "TranslationUnitDecl",
		"inner": [
			{
				"kind": "RecordDecl",
				"name": "cs_ci",
				"tagUsed": "struct",
				"completeDefinition": true,
				"loc": { "file": "test_cs.h" },
				"inner": [
					{ "kind": "FieldDecl", "name": "x", "type": { "qualType": "_Complex double *" } }
				]
			},
			{
				"kind": "FunctionDecl",
				"name": "ci_house",
				"loc": { "file": "test_cs.h" },
				"type": { "qualType": "_Complex double (_Complex double *, double *, int)" },
				"inner": [
					{ "kind": "ParmVarDecl", "name": "x", "type": { "qualType": "_Complex double *" } },
					{ "kind": "ParmVarDecl", "name": "beta", "type": { "qualType": "double *" } },
					{ "kind": "ParmVarDecl", "name": "n", "type": { "qualType": "int" } }
				]
			}
		]
	}
	`;

	Object* root_obj = json::tparse(mock_json)!!;

	BindgenOptions opts = {
		.header_path = "test_cs.h",
		.module_name = "test_cs"
	};

	CTranslationUnit tu;
	tu.init(tmem);

	bindgen::parse_clang_ast_json(tmem, &tu, root_obj, opts);

	String code = bindgen::emit_c3_bindings(tmem, &tu, opts);

	assert(code.contains("double[2]* x;"));
	assert(!code.contains("Complex double"));
	assert(code.contains("extern fn double[2] ci_house(double[2]* x, double* beta, int n) @cname(\"ci_house\");"));
}

fn void test_nested_function_pointer_ast_parsing()
{
	String mock_json = `
	{
		"kind": "TranslationUnitDecl",
		"inner": [
			{
				"kind": "TypedefDecl",
				"name": "vdestream_opent",
				"loc": { "file": "test_vde.h" },
				"type": {
					"qualType": "void * (*)(void *, int, ssize_t (*)(void *, void *, size_t), void (*)(void *, int, char *, ...))"
				},
				"inner": [
					{
						"kind": "PointerType",
						"type": { "qualType": "void * (*)(void *, int, ssize_t (*)(void *, void *, size_t), void (*)(void *, int, char *, ...))" },
						"inner": [
							{
								"kind": "ParenType",
								"type": { "qualType": "void * (void *, int, ssize_t (*)(void *, void *, size_t), void (*)(void *, int, char *, ...))" },
								"inner": [
									{
										"kind": "FunctionProtoType",
										"type": { "qualType": "void * (void *, int, ssize_t (*)(void *, void *, size_t), void (*)(void *, int, char *, ...))" },
										"inner": [
											{ "kind": "PointerType", "type": { "qualType": "void *" } },
											{ "kind": "PointerType", "type": { "qualType": "void *" } },
											{ "kind": "BuiltinType", "type": { "qualType": "int" } },
											{ "kind": "PointerType", "type": { "qualType": "ssize_t (*)(void *, void *, size_t)" } },
											{ "kind": "PointerType", "type": { "qualType": "void (*)(void *, int, char *, ...)" } }
										]
									}
								]
							}
						]
					}
				]
			}
		]
	}
	`;

	Object* root_obj = json::tparse(mock_json)!!;

	BindgenOptions opts = {
		.header_path = "test_vde.h",
		.module_name = "test_vde"
	};

	CTranslationUnit tu;
	tu.init(tmem);

	bindgen::parse_clang_ast_json(tmem, &tu, root_obj, opts);

	String code = bindgen::emit_c3_bindings(tmem, &tu, opts);

	assert(code.contains("alias VdestreamOpent = fn void*(void*, int, void*, void*);"));
	assert(!code.contains("SizeT),"));
}

fn void test_pointer_to_array_parameter_not_misidentified_as_callback()
{
	String mock_json = `
	{
		"kind": "TranslationUnitDecl",
		"inner": [
			{
				"kind": "FunctionDecl",
				"name": "XNVCTRLSetGvoColorConversion",
				"loc": { "file": "test_nv.h" },
				"type": { "qualType": "void (int, float (*)[3])" },
				"inner": [
					{ "kind": "ParmVarDecl", "name": "screen", "type": { "qualType": "int" } },
					{ "kind": "ParmVarDecl", "name": "colorMatrix", "type": { "qualType": "float (*)[3]" } }
				]
			}
		]
	}
	`;

	Object* root_obj = json::tparse(mock_json)!!;

	BindgenOptions opts = {
		.header_path = "test_nv.h",
		.module_name = "test_nv",
		.strip_func_prefix = "XNVCTRL"
	};

	CTranslationUnit tu;
	tu.init(tmem);

	bindgen::parse_clang_ast_json(tmem, &tu, root_obj, opts);

	String code = bindgen::emit_c3_bindings(tmem, &tu, opts);

	assert(!code.contains("Fn = fn float(void[3]);"));
	assert(code.contains("extern fn void set_gvo_color_conversion(int screen, float[3]* color_matrix) @cname(\"XNVCTRLSetGvoColorConversion\");"));
}

fn void test_function_pointer_typedef_tracks_parameter_types()
{
	String mock_json = `
	{
		"kind": "TranslationUnitDecl",
		"inner": [
			{
				"kind": "TypedefDecl",
				"name": "dns_rcode_t",
				"loc": { "file": "external_types.h" },
				"type": {
					"qualType": "uint16_t",
					"desugaredQualType": "unsigned short"
				}
			},
			{
				"kind": "TypedefDecl",
				"name": "dns_rcodestats_dumper_t",
				"loc": { "file": "test_stats.h" },
				"type": {
					"qualType": "void (*)(dns_rcode_t, uint64_t, void *)"
				},
				"inner": [
					{
						"kind": "PointerType",
						"type": { "qualType": "void (*)(dns_rcode_t, uint64_t, void *)" },
						"inner": [
							{
								"kind": "ParenType",
								"type": { "qualType": "void (dns_rcode_t, uint64_t, void *)" },
								"inner": [
									{
										"kind": "FunctionProtoType",
										"type": { "qualType": "void (dns_rcode_t, uint64_t, void *)" },
										"inner": [
											{ "kind": "BuiltinType", "type": { "qualType": "void" } },
											{ "kind": "TypedefType", "type": { "qualType": "dns_rcode_t" } },
											{ "kind": "BuiltinType", "type": { "qualType": "uint64_t" } },
											{ "kind": "PointerType", "type": { "qualType": "void *" } }
										]
									}
								]
							}
						]
					}
				]
			}
		]
	}
	`;

	Object* root_obj = json::tparse(mock_json)!!;

	BindgenOptions opts = {
		.header_path = "test_stats.h",
		.module_name = "test_stats"
	};

	CTranslationUnit tu;
	tu.init(tmem);

	bindgen::parse_clang_ast_json(tmem, &tu, root_obj, opts);

	String code = bindgen::emit_c3_bindings(tmem, &tu, opts);

	assert(code.contains("alias DnsRcodeT = ushort;"));
	assert(code.contains("alias DnsRcodestatsDumperT = fn void(DnsRcodeT, ulong, void*);"));
}

fn void test_member_wildcard_identifier_sanitization()
{
	String mock_json = `
	{
		"kind": "TranslationUnitDecl",
		"inner": [
			{
				"kind": "RecordDecl",
				"name": "GeneratedStruct",
				"tagUsed": "struct",
				"completeDefinition": true,
				"loc": { "file": "test_under.h" },
				"inner": [
					{ "kind": "FieldDecl", "name": "_", "type": { "qualType": "int" } },
					{ "kind": "FieldDecl", "name": "__", "type": { "qualType": "int" } }
				]
			}
		]
	}
	`;

	Object* root_obj = json::tparse(mock_json)!!;

	BindgenOptions opts = {
		.header_path = "test_under.h",
		.module_name = "test_under"
	};

	CTranslationUnit tu;
	tu.init(tmem);

	bindgen::parse_clang_ast_json(tmem, &tu, root_obj, opts);

	String code = bindgen::emit_c3_bindings(tmem, &tu, opts);

	assert(code.contains("int _unused;"));
	assert(!code.contains("int _;"));
	assert(!code.contains("int __;"));
}

fn void test_enum_c3_name_deduplication()
{
	String mock_json = `
	{
		"kind": "TranslationUnitDecl",
		"inner": [
			{
				"kind": "EnumDecl",
				"name": "_LqrRetVal",
				"loc": { "file": "test_enum.h" },
				"inner": [
					{ "kind": "EnumConstantDecl", "name": "LQR_OK" }
				]
			},
			{
				"kind": "EnumDecl",
				"name": "LqrRetVal",
				"loc": { "file": "test_enum.h" },
				"inner": [
					{ "kind": "EnumConstantDecl", "name": "LQR_OK" }
				]
			}
		]
	}
	`;

	Object* root_obj = json::tparse(mock_json)!!;

	BindgenOptions opts = {
		.header_path = "test_enum.h",
		.module_name = "test_enum"
	};

	CTranslationUnit tu;
	tu.init(tmem);

	bindgen::parse_clang_ast_json(tmem, &tu, root_obj, opts);

	test::eq(tu.enums.len(), 1);

	String code = bindgen::emit_c3_bindings(tmem, &tu, opts);

	sz first_idx = code.index_of("enum LqrRetVal") ?? 0;
	assert(first_idx > 0);
	sz second_idx = code[first_idx + 14..].index_of("enum LqrRetVal") ?? 0;
	test::eq(second_idx, 0);
}

fn void test_recursive_handle_typedef_emission()
{
	String mock_json = `
	{
		"kind": "TranslationUnitDecl",
		"inner": [
			{ "kind": "RecordDecl", "name": "HSTRING__", "tagUsed": "struct", "loc": { "file": "test_handle.h" } },
			{
				"kind": "TypedefDecl",
				"name": "HSTRING",
				"loc": { "file": "test_handle.h" },
				"type": { "qualType": "struct HSTRING__ *" },
				"inner": [ { "kind": "PointerType", "inner": [ { "kind": "RecordType", "decl": { "kind": "RecordDecl", "name": "HSTRING__" } } ] } ]
			}
		]
	}
	`;

	Object* root_obj = json::tparse(mock_json)!!;

	BindgenOptions opts = {
		.header_path = "test_handle.h",
		.module_name = "test_handle"
	};

	CTranslationUnit tu;
	tu.init(tmem);

	bindgen::parse_clang_ast_json(tmem, &tu, root_obj, opts);

	String code = bindgen::emit_c3_bindings(tmem, &tu, opts);

	assert(code.contains("typedef _Hstring = void;"));
	assert(code.contains("alias Hstring = _Hstring*;"));
}

fn void test_function_type_field_in_struct_maps_to_void_pointer()
{
	String mock_json = `
	{
		"kind": "TranslationUnitDecl",
		"inner": [
			{
				"kind": "RecordDecl",
				"name": "vki_xenctl_bitmap",
				"tagUsed": "struct",
				"completeDefinition": true,
				"loc": { "file": "test_xen.h" },
				"inner": [
					{
						"kind": "FieldDecl",
						"name": "vki_xen_guest_handle_64",
						"type": { "qualType": "int ()" }
					},
					{
						"kind": "FieldDecl",
						"name": "nr_bits",
						"type": { "qualType": "unsigned int" }
					}
				]
			}
		]
	}
	`;

	Object* root_obj = json::tparse(mock_json)!!;

	BindgenOptions opts = {
		.header_path = "test_xen.h",
		.module_name = "test_xen"
	};

	CTranslationUnit tu;
	tu.init(tmem);

	bindgen::parse_clang_ast_json(tmem, &tu, root_obj, opts);

	String code = bindgen::emit_c3_bindings(tmem, &tu, opts);

	assert(code.contains("struct VkiXenctlBitmap\n{"));
	assert(code.contains("void* vki_xen_guest_handle_64;"));
	assert(!code.contains("Int ()"));
	assert(code.contains("uint nr_bits;"));
}

fn void test_enum_typedef_does_not_emit_shadowing_alias()
{
	String mock_json = `
	{
		"kind": "TranslationUnitDecl",
		"inner": [
			{
				"kind": "EnumDecl",
				"name": "__ns_sect",
				"loc": { "file": "test_nameser.h" },
				"inner": [
					{ "kind": "EnumConstantDecl", "name": "ns_s_qd" },
					{ "kind": "EnumConstantDecl", "name": "ns_s_an" }
				]
			},
			{
				"kind": "TypedefDecl",
				"name": "ns_sect",
				"loc": { "file": "test_nameser.h" },
				"type": { "qualType": "enum __ns_sect" }
			}
		]
	}
	`;

	Object* root_obj = json::tparse(mock_json)!!;

	BindgenOptions opts = {
		.header_path = "test_nameser.h",
		.module_name = "test_nameser"
	};

	CTranslationUnit tu;
	tu.init(tmem);

	bindgen::parse_clang_ast_json(tmem, &tu, root_obj, opts);

	String code = bindgen::emit_c3_bindings(tmem, &tu, opts);

	assert(!code.contains("alias NsSect"));
	assert(code.contains("enum NsSect\n{"));
}

fn void test_macro_qualified_field_type_mapping()
{
	String mock_json = `
	{
		"kind": "TranslationUnitDecl",
		"inner": [
			{
				"kind": "RecordDecl",
				"name": "upb_Arena",
				"tagUsed": "struct",
				"completeDefinition": true,
				"loc": { "file": "test_arena.h" },
				"inner": [
					{
						"kind": "FieldDecl",
						"name": "ptr",
						"type": { "qualType": "char *" }
					},
					{
						"kind": "FieldDecl",
						"name": "end",
						"type": { "qualType": "UPB_NODEREF char const *" }
					}
				]
			}
		]
	}
	`;

	Object* root_obj = json::tparse(mock_json)!!;

	BindgenOptions opts = {
		.header_path = "test_arena.h",
		.module_name = "test_arena"
	};

	CTranslationUnit tu;
	tu.init(tmem);

	bindgen::parse_clang_ast_json(tmem, &tu, root_obj, opts);

	String code = bindgen::emit_c3_bindings(tmem, &tu, opts);

	assert(code.contains("struct UpbArena\n{"));
	assert(code.contains("char* ptr;"));
	assert(!code.contains("UPBNODEREF"));
	assert(code.contains("ZString end;"));
}

fn void test_array_of_structs_with_flexible_array_members()
{
	String mock_json = `
	{
		"kind": "TranslationUnitDecl",
		"inner": [
			{
				"kind": "RecordDecl",
				"name": "packet_body",
				"tagUsed": "struct",
				"completeDefinition": true,
				"loc": { "file": "test_fam.h" },
				"inner": [
					{
						"kind": "FieldDecl",
						"name": "len",
						"type": { "qualType": "int" }
					},
					{
						"kind": "FieldDecl",
						"name": "payload",
						"type": { "qualType": "char[]" }
					}
				]
			},
			{
				"kind": "RecordDecl",
				"name": "packet_header",
				"tagUsed": "struct",
				"completeDefinition": true,
				"loc": { "file": "test_fam.h" },
				"inner": [
					{
						"kind": "FieldDecl",
						"name": "id",
						"type": { "qualType": "int" }
					},
					{
						"kind": "FieldDecl",
						"name": "active_body",
						"type": { "qualType": "struct packet_body *" }
					},
					{
						"kind": "FieldDecl",
						"name": "bodies",
						"type": { "qualType": "struct packet_body[]" }
					}
				]
			},
			{
				"kind": "FunctionDecl",
				"name": "send_bodies",
				"loc": { "file": "test_fam.h" },
				"type": { "qualType": "void (struct packet_body[])" },
				"inner": [
					{ "kind": "ParmVarDecl", "name": "items", "type": { "qualType": "struct packet_body[]" } }
				]
			}
		]
	}
	`;

	Object* root_obj = json::tparse(mock_json)!!;

	BindgenOptions opts = {
		.header_path = "test_fam.h",
		.module_name = "test_fam"
	};

	CTranslationUnit tu;
	tu.init(tmem);

	bindgen::parse_clang_ast_json(tmem, &tu, root_obj, opts);

	String code = bindgen::emit_c3_bindings(tmem, &tu, opts);

	assert(code.contains("struct PacketBody\n{\n\tint len;\n\tchar[*] payload;\n}"));
	assert(code.contains("PacketBody* active_body;"));
	assert(!code.contains("PacketBody[*] bodies;"));
	assert(code.contains("char[*] bodies;"));
	assert(code.contains("extern fn void send_bodies(PacketBody* items) @cname(\"send_bodies\");"));
}

fn void test_pointer_array_field_mapping()
{
	String mock_json = `
	{
		"kind": "TranslationUnitDecl",
		"inner": [
			{
				"kind": "RecordDecl",
				"name": "util_struct",
				"tagUsed": "struct",
				"completeDefinition": true,
				"loc": { "file": "test_util.h" },
				"inner": [
					{
						"kind": "FieldDecl",
						"name": "reserved0",
						"type": { "qualType": "int[2]" }
					},
					{
						"kind": "FieldDecl",
						"name": "reserved1",
						"type": { "qualType": "void *[2]" }
					},
					{
						"kind": "FieldDecl",
						"name": "ptrs",
						"type": { "qualType": "int *[4]" }
					}
				]
			}
		]
	}
	`;

	Object* root_obj = json::tparse(mock_json)!!;

	BindgenOptions opts = {
		.header_path = "test_util.h",
		.module_name = "test_util"
	};

	CTranslationUnit tu;
	tu.init(tmem);

	bindgen::parse_clang_ast_json(tmem, &tu, root_obj, opts);

	String code = bindgen::emit_c3_bindings(tmem, &tu, opts);

	assert(code.contains("int[2] reserved0;"));
	assert(code.contains("void*[2] reserved1;"));
	assert(!code.contains("void[2]*"));
	assert(code.contains("int*[4] ptrs;"));
	assert(!code.contains("int[4]* ptrs;"));
}

fn void test_function_name_collision_deduplication()
{
	String mock_json = `
	{
		"kind": "TranslationUnitDecl",
		"inner": [
			{
				"kind": "FunctionDecl",
				"name": "LZ4_compress_HC",
				"loc": { "file": "lz4hc.h" },
				"type": { "qualType": "int (const char *, char *, int, int, int)" },
				"inner": [
					{ "kind": "ParmVarDecl", "name": "src", "type": { "qualType": "const char *" } },
					{ "kind": "ParmVarDecl", "name": "dst", "type": { "qualType": "char *" } },
					{ "kind": "ParmVarDecl", "name": "src_size", "type": { "qualType": "int" } },
					{ "kind": "ParmVarDecl", "name": "dst_capacity", "type": { "qualType": "int" } },
					{ "kind": "ParmVarDecl", "name": "level", "type": { "qualType": "int" } }
				]
			},
			{
				"kind": "FunctionDecl",
				"name": "LZ4_compressHC",
				"loc": { "file": "lz4hc.h" },
				"type": { "qualType": "int (const char *, char *, int)" },
				"inner": [
					{ "kind": "ParmVarDecl", "name": "src", "type": { "qualType": "const char *" } },
					{ "kind": "ParmVarDecl", "name": "dst", "type": { "qualType": "char *" } },
					{ "kind": "ParmVarDecl", "name": "src_size", "type": { "qualType": "int" } }
				]
			}
		]
	}
	`;

	Object* root_obj = json::tparse(mock_json)!!;

	BindgenOptions opts = {
		.header_path = "lz4hc.h",
		.module_name = "lz4hc"
	};

	CTranslationUnit tu;
	tu.init(tmem);

	bindgen::parse_clang_ast_json(tmem, &tu, root_obj, opts);

	test::eq(tu.functions.len(), 2);

	String code = bindgen::emit_c3_bindings(tmem, &tu, opts);

	assert(code.contains("extern fn int lz4_compress_hc("));
	assert(code.contains("@cname(\"LZ4_compress_HC\");"));
	assert(code.contains("extern fn int lz4_compress_hc_2("));
	assert(code.contains("@cname(\"LZ4_compressHC\");"));
}

fn void test_duplicate_parameter_names_deduplication()
{
	String mock_json = `
	{
		"kind": "TranslationUnitDecl",
		"inner": [
			{
				"kind": "FunctionDecl",
				"name": "calc",
				"loc": { "file": "test_dup_params.h" },
				"type": { "qualType": "void (double *, int *)" },
				"inner": [
					{ "kind": "ParmVarDecl", "name": "work", "type": { "qualType": "double *" } },
					{ "kind": "ParmVarDecl", "name": "Work", "type": { "qualType": "int *" } }
				]
			}
		]
	}
	`;

	Object* root_obj = json::tparse(mock_json)!!;

	BindgenOptions opts = {
		.header_path = "test_dup_params.h",
		.module_name = "test_dup_params"
	};

	CTranslationUnit tu;
	tu.init(tmem);

	bindgen::parse_clang_ast_json(tmem, &tu, root_obj, opts);

	String code = bindgen::emit_c3_bindings(tmem, &tu, opts);

	assert(code.contains("double* work, int* work_2"));
	assert(!code.contains("int* work)"));
}

fn void test_main_function_sanitization()
{
	String mock_json = `
	{
		"kind": "TranslationUnitDecl",
		"inner": [
			{
				"kind": "FunctionDecl",
				"name": "cuse_lowlevel_main",
				"loc": { "file": "cuse_lowlevel.h" },
				"type": { "qualType": "int (int, char **, void *)" },
				"inner": [
					{ "kind": "ParmVarDecl", "name": "argc", "type": { "qualType": "int" } },
					{ "kind": "ParmVarDecl", "name": "argv", "type": { "qualType": "char **" } },
					{ "kind": "ParmVarDecl", "name": "userdata", "type": { "qualType": "void *" } }
				]
			},
			{
				"kind": "FunctionDecl",
				"name": "main",
				"loc": { "file": "cuse_lowlevel.h" },
				"type": { "qualType": "int (int, char **)" },
				"inner": [
					{ "kind": "ParmVarDecl", "name": "argc", "type": { "qualType": "int" } },
					{ "kind": "ParmVarDecl", "name": "argv", "type": { "qualType": "char **" } }
				]
			}
		]
	}
	`;

	Object* root_obj = json::tparse(mock_json)!!;

	BindgenOptions opts = {
		.header_path = "cuse_lowlevel.h",
		.module_name = "cuse_lowlevel"
	};

	CTranslationUnit tu;
	tu.init(tmem);

	bindgen::parse_clang_ast_json(tmem, &tu, root_obj, opts);

	String code = bindgen::emit_c3_bindings(tmem, &tu, opts);

	assert(code.contains("extern fn int main_(int argc, char** argv, void* userdata) @cname(\"cuse_lowlevel_main\");"));
	assert(code.contains("extern fn int main__2(int argc, char** argv) @cname(\"main\");"));
	assert(!code.contains("fn int main("));
}

fn void test_invalid_void_field_degrades_struct_to_opaque()
{
	String mock_json = `
	{
		"kind": "TranslationUnitDecl",
		"inner": [
			{
				"kind": "RecordDecl",
				"name": "scalar_group",
				"tagUsed": "struct",
				"completeDefinition": true,
				"loc": { "file": "scalar_group.h" },
				"inner": [
					{
						"kind": "FieldDecl",
						"name": "lbound",
						"isInvalid": true,
						"type": { "qualType": "void" }
					},
					{
						"kind": "FieldDecl",
						"name": "ubound",
						"isInvalid": true,
						"type": { "qualType": "void" }
					}
				]
			}
		]
	}
	`;

	Object* root_obj = json::tparse(mock_json)!!;

	BindgenOptions opts = {
		.header_path = "scalar_group.h",
		.module_name = "scalar_group"
	};

	CTranslationUnit tu;
	tu.init(tmem);

	bindgen::parse_clang_ast_json(tmem, &tu, root_obj, opts);

	String code = bindgen::emit_c3_bindings(tmem, &tu, opts);

	assert(code.contains("typedef ScalarGroup = void;"));
	assert(!code.contains("void lbound;"));
	assert(!code.contains("void* lbound;"));
}

fn void test_non_last_flexible_array_member_removal()
{
	String mock_json = `
	{
		"kind": "TranslationUnitDecl",
		"inner": [
			{
				"kind": "RecordDecl",
				"name": "aiocb",
				"tagUsed": "struct",
				"completeDefinition": true,
				"loc": { "file": "aio.h" },
				"inner": [
					{
						"kind": "FieldDecl",
						"name": "aio_offset",
						"type": { "qualType": "long" }
					},
					{
						"kind": "FieldDecl",
						"name": "__pad",
						"type": { "qualType": "char[0]" }
					},
					{
						"kind": "FieldDecl",
						"name": "aio_reqprio",
						"type": { "qualType": "int" }
					}
				]
			}
		]
	}
	`;

	Object* root_obj = json::tparse(mock_json)!!;

	BindgenOptions opts = {
		.header_path = "aio.h",
		.module_name = "aio"
	};

	CTranslationUnit tu;
	tu.init(tmem);

	bindgen::parse_clang_ast_json(tmem, &tu, root_obj, opts);

	String code = bindgen::emit_c3_bindings(tmem, &tu, opts);

	assert(code.contains("struct Aiocb\n{"));
	assert(code.contains("CLong aio_offset;"));
	assert(!code.contains("__pad"));
	assert(code.contains("int aio_reqprio;"));
}

fn void test_single_flexible_array_member_struct_degrades_to_opaque()
{
	String mock_json = `
	{
		"kind": "TranslationUnitDecl",
		"inner": [
			{
				"kind": "RecordDecl",
				"name": "VSCMsgReaderAdd",
				"tagUsed": "struct",
				"completeDefinition": true,
				"loc": { "file": "vscard_common.h" },
				"inner": [
					{
						"kind": "FieldDecl",
						"name": "name",
						"type": { "qualType": "uint8_t[0]" }
					}
				]
			}
		]
	}
	`;

	Object* root_obj = json::tparse(mock_json)!!;

	BindgenOptions opts = {
		.header_path = "vscard_common.h",
		.module_name = "vscard_common"
	};

	CTranslationUnit tu;
	tu.init(tmem);

	bindgen::parse_clang_ast_json(tmem, &tu, root_obj, opts);

	String code = bindgen::emit_c3_bindings(tmem, &tu, opts);

	assert(code.contains("typedef VSCMsgReaderAdd = void;"));
	assert(!code.contains("char[*] name;"));
}

fn void test_enum_variant_case_collision_deduplication()
{
	String mock_json = `
	{
		"kind": "TranslationUnitDecl",
		"inner": [
			{
				"kind": "EnumDecl",
				"name": "imaging_mode",
				"loc": { "file": "Mode.h" },
				"inner": [
					{ "kind": "EnumConstantDecl", "name": "IMAGING_MODE_L" },
					{ "kind": "EnumConstantDecl", "name": "IMAGING_MODE_LA" },
					{ "kind": "EnumConstantDecl", "name": "IMAGING_MODE_LAB" },
					{ "kind": "EnumConstantDecl", "name": "IMAGING_MODE_La" }
				]
			}
		]
	}
	`;

	Object* root_obj = json::tparse(mock_json)!!;

	BindgenOptions opts = {
		.header_path = "Mode.h",
		.module_name = "mode"
	};

	CTranslationUnit tu;
	tu.init(tmem);

	bindgen::parse_clang_ast_json(tmem, &tu, root_obj, opts);

	test::eq(tu.enums.len(), 1);

	String code = bindgen::emit_c3_bindings(tmem, &tu, opts);

	assert(code.contains("\tLA,\n"));
	assert(code.contains("\tLAB,\n"));
	assert(code.contains("\tLA_2"));
}

fn void test_struct_name_matching_primitive_c3_type()
{
	String mock_json = `
	{
		"kind": "TranslationUnitDecl",
		"inner": [
			{
				"kind": "RecordDecl",
				"name": "float3",
				"tagUsed": "struct",
				"completeDefinition": true,
				"loc": { "file": "raymath.h" },
				"inner": [
					{
						"kind": "FieldDecl",
						"name": "v",
						"type": { "qualType": "float[3]" }
					}
				]
			},
			{
				"kind": "RecordDecl",
				"name": "float16",
				"tagUsed": "struct",
				"completeDefinition": true,
				"loc": { "file": "raymath.h" },
				"inner": [
					{
						"kind": "FieldDecl",
						"name": "v",
						"type": { "qualType": "float[16]" }
					}
				]
			}
		]
	}
	`;

	Object* root_obj = json::tparse(mock_json)!!;

	BindgenOptions opts = {
		.header_path = "raymath.h",
		.module_name = "raymath"
	};

	CTranslationUnit tu;
	tu.init(tmem);

	bindgen::parse_clang_ast_json(tmem, &tu, root_obj, opts);

	String code = bindgen::emit_c3_bindings(tmem, &tu, opts);

	assert(code.contains("struct Float3\n{"));
	assert(code.contains("struct Float16\n{"));
	assert(!code.contains("struct float16"));
}

fn void test_unsized_array_in_typedef_emits_slice_not_inferred_array()
{
	String mock_json = `
	{
		"kind": "TranslationUnitDecl",
		"inner": [
			{
				"kind": "TypedefDecl",
				"name": "Buffer",
				"loc": { "file": "test_buf.h" },
				"type": { "qualType": "char[0]" }
			},
			{
				"kind": "TypedefDecl",
				"name": "UnsizedBuffer",
				"loc": { "file": "test_buf.h" },
				"type": { "qualType": "char[]" }
			}
		]
	}
	`;

	Object* root_obj = json::tparse(mock_json)!!;

	BindgenOptions opts = {
		.header_path = "test_buf.h",
		.module_name = "test_buf"
	};

	CTranslationUnit tu;
	tu.init(tmem);

	bindgen::parse_clang_ast_json(tmem, &tu, root_obj, opts);

	String code = bindgen::emit_c3_bindings(tmem, &tu, opts);

	assert(code.contains("alias Buffer = char[];"));
	assert(code.contains("alias UnsizedBuffer = char[];"));
	assert(!code.contains("char[*]"));
}

fn void test_struct_with_fam_embedded_as_non_last_member()
{
	String mock_json = `
	{
		"kind": "TranslationUnitDecl",
		"inner": [
			{
				"kind": "RecordDecl",
				"name": "xt_entry_target",
				"tagUsed": "struct",
				"completeDefinition": true,
				"loc": { "file": "x_tables.h" },
				"inner": [
					{
						"kind": "FieldDecl",
						"name": "target_size",
						"type": { "qualType": "unsigned short" }
					},
					{
						"kind": "FieldDecl",
						"name": "data",
						"type": { "qualType": "unsigned char[]" }
					}
				]
			},
			{
				"kind": "RecordDecl",
				"name": "xt_standard_target",
				"tagUsed": "struct",
				"completeDefinition": true,
				"loc": { "file": "x_tables.h" },
				"inner": [
					{
						"kind": "FieldDecl",
						"name": "target",
						"type": { "qualType": "struct xt_entry_target" }
					},
					{
						"kind": "FieldDecl",
						"name": "verdict",
						"type": { "qualType": "int" }
					}
				]
			}
		]
	}
	`;

	Object* root_obj = json::tparse(mock_json)!!;

	BindgenOptions opts = {
		.header_path = "x_tables.h",
		.module_name = "x_tables"
	};

	CTranslationUnit tu;
	tu.init(tmem);

	bindgen::parse_clang_ast_json(tmem, &tu, root_obj, opts);

	String code = bindgen::emit_c3_bindings(tmem, &tu, opts);

	assert(code.contains("struct XtEntryTarget\n{\n\tushort target_size;\n}"));
	assert(!code.contains("char[*] data;"));
	assert(code.contains("struct XtStandardTarget\n{\n\tXtEntryTarget target;\n\tint verdict;\n}"));
}

fn void test_enum_and_struct_name_collision_deduplication()
{
	String mock_json = `
	{
		"kind": "TranslationUnitDecl",
		"inner": [
			{
				"kind": "EnumDecl",
				"name": "stemmer_encoding",
				"loc": { "file": "modules.h" },
				"inner": [
					{ "kind": "EnumConstantDecl", "name": "ENC_UNKNOWN" },
					{ "kind": "EnumConstantDecl", "name": "ENC_UTF_8" }
				]
			},
			{
				"kind": "RecordDecl",
				"name": "stemmer_encoding",
				"tagUsed": "struct",
				"completeDefinition": true,
				"loc": { "file": "modules.h" },
				"inner": [
					{
						"kind": "FieldDecl",
						"name": "name",
						"type": { "qualType": "const char *" }
					}
				]
			}
		]
	}
	`;

	Object* root_obj = json::tparse(mock_json)!!;

	BindgenOptions opts = {
		.header_path = "modules.h",
		.module_name = "modules"
	};

	CTranslationUnit tu;
	tu.init(tmem);

	bindgen::parse_clang_ast_json(tmem, &tu, root_obj, opts);

	test::eq(tu.enums.len(), 1);
	test::eq(tu.structs.len(), 1);

	String code = bindgen::emit_c3_bindings(tmem, &tu, opts);

	assert(code.contains("enum StemmerEncoding\n{"));
	assert(code.contains("struct StemmerEncoding_2\n{"));
	assert(!code.contains("struct StemmerEncoding\n{"));
}

fn void test_extern_variables_emission()
{
	String mock_json = `
	{
		"kind": "TranslationUnitDecl",
		"inner": [
			{
				"kind": "RecordDecl",
				"name": "_ffi_type",
				"tagUsed": "struct",
				"completeDefinition": true,
				"loc": { "file": "test_ffi.h" },
				"inner": [
					{ "kind": "FieldDecl", "name": "size", "type": { "qualType": "size_t" } }
				]
			},
			{
				"kind": "TypedefDecl",
				"name": "ffi_type",
				"loc": { "file": "test_ffi.h" },
				"type": { "qualType": "struct _ffi_type" }
			},
			{
				"kind": "VarDecl",
				"name": "ffi_type_void",
				"loc": { "file": "test_ffi.h" },
				"type": { "qualType": "ffi_type" }
			}
		]
	}
	`;

	Object* root_obj = json::tparse(mock_json)!!;

	BindgenOptions opts = {
		.header_path = "test_ffi.h",
		.module_name = "test_ffi"
	};

	CTranslationUnit tu;
	tu.init(tmem);

	bindgen::parse_clang_ast_json(tmem, &tu, root_obj, opts);

	test::eq(tu.variables.len(), 1);
	test::eq(tu.variables.get(0).c3_name, "ffi_type_void");
	test::eq(tu.variables.get(0).c3_type, "FfiType");

	String code = bindgen::emit_c3_bindings(tmem, &tu, opts);
	assert(code.contains("extern FfiType ffi_type_void @cname(\"ffi_type_void\");"));
}

fn void test_elaborated_type_anonymous_struct_and_enum()
{
	String mock_json = `
	{
		"kind": "TranslationUnitDecl",
		"inner": [
			{
				"kind": "RecordDecl",
				"id": "0xrec01",
				"tagUsed": "struct",
				"completeDefinition": true,
				"loc": { "file": "test_elab.h" },
				"inner": [
					{ "kind": "FieldDecl", "name": "val", "type": { "qualType": "int" } }
				]
			},
			{
				"kind": "TypedefDecl",
				"name": "anon_cif",
				"loc": { "file": "test_elab.h" },
				"type": { "qualType": "struct anon_cif" },
				"inner": [
					{
						"kind": "ElaboratedType",
						"ownedTagDecl": { "id": "0xrec01", "kind": "RecordDecl", "name": "" },
						"inner": [
							{ "kind": "RecordType", "decl": { "id": "0xrec01", "kind": "RecordDecl", "name": "" } }
						]
					}
				]
			},
			{
				"kind": "EnumDecl",
				"id": "0xenum01",
				"loc": { "file": "test_elab.h" },
				"inner": [
					{ "kind": "EnumConstantDecl", "name": "STATUS_OK" }
				]
			},
			{
				"kind": "TypedefDecl",
				"name": "anon_status",
				"loc": { "file": "test_elab.h" },
				"type": { "qualType": "enum anon_status" },
				"inner": [
					{
						"kind": "ElaboratedType",
						"ownedTagDecl": { "id": "0xenum01", "kind": "EnumDecl", "name": "" },
						"inner": [
							{ "kind": "EnumType", "decl": { "id": "0xenum01", "kind": "EnumDecl", "name": "" } }
						]
					}
				]
			},
			{
				"kind": "TypedefDecl",
				"name": "alias_to_cif",
				"loc": { "file": "test_elab.h" },
				"type": { "qualType": "anon_cif" },
				"inner": [
					{
						"kind": "ElaboratedType",
						"inner": [
							{
								"kind": "TypedefType",
								"decl": { "id": "0xtd01", "kind": "TypedefDecl", "name": "anon_cif" }
							}
						]
					}
				]
			}
		]
	}
	`;

	Object* root_obj = json::tparse(mock_json)!!;

	BindgenOptions opts = {
		.header_path = "test_elab.h",
		.module_name = "test_elab"
	};

	CTranslationUnit tu;
	tu.init(tmem);

	bindgen::parse_clang_ast_json(tmem, &tu, root_obj, opts);

	test::eq(tu.structs.len(), 1);
	test::eq(tu.structs.get(0).c3_name, "AnonCif");
	test::eq(tu.structs.get(0).fields.len(), 1);

	test::eq(tu.enums.len(), 1);
	test::eq(tu.enums.get(0).c3_name, "AnonStatus");

	test::eq(tu.typedefs.len(), 1);
	test::eq(tu.typedefs.get(0).c3_name, "AliasToCif");

	String code = bindgen::emit_c3_bindings(tmem, &tu, opts);
	assert(code.contains("struct AnonCif\n{\n\tint val;\n}"));
	assert(code.contains("enum AnonStatus\n{\n\tSTATUS_OK\n}"));
	assert(code.contains("alias AliasToCif = AnonCif;"));
}

fn void test_invalid_typedef_and_struct_name_collision()
{
	String mock_json = `
	{
		"kind": "TranslationUnitDecl",
		"inner": [
			{
				"kind": "RecordDecl",
				"name": "_AgAccount",
				"tagUsed": "struct",
				"loc": { "file": "ag-types.h" }
			},
			{
				"kind": "TypedefDecl",
				"name": "AgAccount",
				"isInvalid": true,
				"loc": { "file": "ag-types.h" },
				"type": { "qualType": "int" }
			},
			{
				"kind": "FunctionDecl",
				"name": "ag_account_get_manager",
				"loc": { "file": "ag-account.h" },
				"type": { "qualType": "AgManager *(AgAccount *)" },
				"inner": [
					{ "kind": "ParmVarDecl", "name": "account", "type": { "qualType": "AgAccount *" } }
				]
			}
		]
	}
	`;

	Object* root_obj = json::tparse(mock_json)!!;

	BindgenOptions opts = {
		.header_path = "ag-account.h",
		.module_name = "ag_account"
	};

	CTranslationUnit tu;
	tu.init(tmem);

	bindgen::parse_clang_ast_json(tmem, &tu, root_obj, opts);

	String code = bindgen::emit_c3_bindings(tmem, &tu, opts);

	assert(code.contains("typedef AgAccount = void;"));
	assert(!code.contains("struct AgAccount_2"));
	assert(!code.contains("alias AgAccount = int;"));
	assert(code.contains("extern fn AgManager* get_manager(AgAccount* account) @cname(\"ag_account_get_manager\");"));
}

fn void test_function_with_trailing_calling_convention_attribute()
{
	String mock_json = `
	{
		"kind": "TranslationUnitDecl",
		"inner": [
			{
				"kind": "FunctionDecl",
				"name": "D3D10CreateDevice1",
				"loc": { "file": "d3d10_1.h" },
				"type": {
					"qualType": "HRESULT (void *, int, void *, unsigned int, int, unsigned int, void **) __attribute__((ms_abi))"
				},
				"inner": [
					{ "kind": "ParmVarDecl", "name": "adapter", "type": { "qualType": "void *" } }
				]
			}
		]
	}
	`;

	Object* root_obj = json::tparse(mock_json)!!;

	BindgenOptions opts = {
		.header_path = "d3d10_1.h",
		.module_name = "d3d10_1"
	};

	CTranslationUnit tu;
	tu.init(tmem);

	bindgen::parse_clang_ast_json(tmem, &tu, root_obj, opts);

	String code = bindgen::emit_c3_bindings(tmem, &tu, opts);

	assert(code.contains("extern fn Hresult d3d10_create_device1(void* adapter) @cname(\"D3D10CreateDevice1\");"));
	assert(!code.contains("Attribute"));
	assert(!code.contains("D3D10DRIVERTYPE"));
}

fn void test_function_and_variable_name_collision()
{
	String mock_json = `
	{
		"kind": "TranslationUnitDecl",
		"inner": [
			{
				"kind": "VarDecl",
				"name": "MPD_MINALLOC",
				"loc": { "file": "test_mpd.h" },
				"type": { "qualType": "long" }
			},
			{
				"kind": "FunctionDecl",
				"name": "mpd_minalloc",
				"loc": { "file": "test_mpd.h" },
				"type": { "qualType": "void (void *)" },
				"inner": [
					{ "kind": "ParmVarDecl", "name": "result", "type": { "qualType": "void *" } }
				]
			}
		]
	}
	`;

	Object* root_obj = json::tparse(mock_json)!!;

	BindgenOptions opts = {
		.header_path = "test_mpd.h",
		.module_name = "test_mpd"
	};

	CTranslationUnit tu;
	tu.init(tmem);

	bindgen::parse_clang_ast_json(tmem, &tu, root_obj, opts);

	String code = bindgen::emit_c3_bindings(tmem, &tu, opts);

	assert(code.contains("extern fn void mpd_minalloc(void* result) @cname(\"mpd_minalloc\");"));
	assert(code.contains("extern CLong mpd_minalloc_2 @cname(\"MPD_MINALLOC\");"));
}

fn void test_struct_named_uint128_capitalization()
{
	String mock_json = `
	{
		"kind": "TranslationUnitDecl",
		"inner": [
			{
				"kind": "RecordDecl",
				"name": "uint128",
				"tagUsed": "struct",
				"completeDefinition": true,
				"loc": { "file": "bluetooth.h" },
				"inner": [
					{
						"kind": "FieldDecl",
						"name": "data",
						"type": { "qualType": "unsigned char[16]" }
					}
				]
			}
		]
	}
	`;

	Object* root_obj = json::tparse(mock_json)!!;

	BindgenOptions opts = {
		.header_path = "bluetooth.h",
		.module_name = "bluetooth"
	};

	CTranslationUnit tu;
	tu.init(tmem);

	bindgen::parse_clang_ast_json(tmem, &tu, root_obj, opts);

	String code = bindgen::emit_c3_bindings(tmem, &tu, opts);

	assert(code.contains("struct Uint128\n{"));
	assert(!code.contains("struct uint128\n{"));
}

fn void test_anonymous_struct_typedef_named_uint128_t_capitalization()
{
	String mock_json = `
	{
		"kind": "TranslationUnitDecl",
		"inner": [
			{
				"kind": "RecordDecl",
				"id": "0xrec_u128",
				"tagUsed": "struct",
				"completeDefinition": true,
				"loc": { "file": "bluetooth.h" },
				"inner": [
					{
						"kind": "FieldDecl",
						"name": "data",
						"type": { "qualType": "uint8_t[16]" }
					}
				]
			},
			{
				"kind": "TypedefDecl",
				"name": "uint128_t",
				"loc": { "file": "bluetooth.h" },
				"type": { "qualType": "struct uint128_t" },
				"inner": [
					{
						"kind": "ElaboratedType",
						"ownedTagDecl": { "id": "0xrec_u128", "kind": "RecordDecl", "name": "" },
						"inner": [
							{ "kind": "RecordType", "decl": { "id": "0xrec_u128", "kind": "RecordDecl", "name": "" } }
						]
					}
				]
			}
		]
	}
	`;

	Object* root_obj = json::tparse(mock_json)!!;

	BindgenOptions opts = {
		.header_path = "bluetooth.h",
		.module_name = "bluetooth"
	};

	CTranslationUnit tu;
	tu.init(tmem);

	bindgen::parse_clang_ast_json(tmem, &tu, root_obj, opts);

	String code = bindgen::emit_c3_bindings(tmem, &tu, opts);

	assert(code.contains("struct Uint128\n{"));
	assert(!code.contains("struct uint128\n{"));
}

fn void test_auto_discover_peer_includes() @test
{
	Path? tmp_dir = path::temp_directory(tmem);
	if (catch tmp_dir) return;

	Path mock_sdk = tmp_dir.tappend("mock_sdk_root")!!;
	Path um_dir = mock_sdk.tappend("um")!!;
	Path shared_dir = mock_sdk.tappend("shared")!!;
	Path km_dir = mock_sdk.tappend("km")!!;

	(void)path::mkdir(um_dir, recursive: true);
	(void)path::mkdir(shared_dir, recursive: true);
	(void)path::mkdir(km_dir, recursive: true);
	defer (void)path::rmtree(mock_sdk);

	file::save(um_dir.tappend("target.h")!!, "#pragma once\n")!!;
	file::save(shared_dir.tappend("shared_header.h")!!, "#pragma once\n")!!;
	file::save(km_dir.tappend("km_header.h")!!, "#pragma once\n")!!;

	BindgenOptions opts = {
		.header_path = (String)um_dir.tappend("target.h")!!
	};

	bindgen::auto_discover_peer_includes(&opts);

	bool found_shared = false;
	bool found_km = false;
	foreach (inc : opts.include_dirs)
	{
		if (inc.contains("shared")) found_shared = true;
		if (inc.contains("km")) found_km = true;
	}

	assert(found_shared);
	assert(found_km);
}

fn void test_self_healing_missing_header_discovery() @test
{
	Path? tmp_dir = path::temp_directory(tmem);
	if (catch tmp_dir) return;

	Path mock_root = tmp_dir.tappend("mock_heal_root")!!;
	Path inc_dir = mock_root.tappend("nested_inc")!!;
	(void)path::mkdir(inc_dir, recursive: true);
	defer (void)path::rmtree(mock_root);

	// Create a header in the nested directory
	file::save(inc_dir.tappend("custom_dependency.h")!!, "typedef int CustomHandle;\n")!!;

	BindgenOptions opts = {
		.header_path = (String)mock_root
	};

	String? found = bindgen::find_missing_header_directory(opts, "custom_dependency.h");
	assert(@ok(found));
	assert(found!!.contains("nested_inc"));
}

fn void test_deduce_package_dir_rules() @test
{
	BindgenOptions sys_opts = {
		.header_path = "/usr/include/sqlite3.h"
	};
	test::eq(bindgen::deduce_package_dir(sys_opts), "");

	BindgenOptions pkg_opts = {
		.header_path = "/usr/include/libportal/portal.h"
	};
	test::eq(bindgen::deduce_package_dir(pkg_opts), "/usr/include/libportal/");

	BindgenOptions local_opts = {
		.header_path = "/home/user/project/include/mylib/entry.h"
	};
	test::eq(bindgen::deduce_package_dir(local_opts), "/home/user/project/include/mylib/");

	BindgenOptions win_opts = {
		.header_path = `C:\project\include\mylib\entry.h`
	};
	test::eq(bindgen::deduce_package_dir(win_opts), `C:\project\include\mylib\`);
}

fn void test_umbrella_header_package_symbol_extraction() @test
{
	String mock_json = `
	{
		"kind": "TranslationUnitDecl",
		"inner": [
			{
				"kind": "FunctionDecl",
				"name": "libportal_init",
				"loc": { "file": "/usr/include/libportal/init.h" },
				"type": { "qualType": "void (void)" }
			},
			{
				"kind": "FunctionDecl",
				"name": "g_object_ref",
				"loc": { "file": "/usr/include/glib-2.0/gobject.h" },
				"type": { "qualType": "void (void *)" }
			}
		]
	}
	`;

	Object* root_obj = json::tparse(mock_json)!!;

	BindgenOptions opts = {
		.header_path = "/usr/include/libportal/portal.h",
		.target_dir = "/usr/include/libportal/",
		.module_name = "libportal"
	};

	CTranslationUnit tu;
	tu.init(tmem);

	bindgen::parse_clang_ast_json(tmem, &tu, root_obj, opts);

	test::eq(tu.functions.len(), 1);
	test::eq(tu.functions.get(0).c_name, "libportal_init");

	String code = bindgen::emit_c3_bindings(tmem, &tu, opts);
	assert(code.contains("extern fn void init() @cname(\"libportal_init\");"));
	assert(!code.contains("g_object_ref"));
}

fn void test_nested_anonymous_struct_and_union_fields() @test
{
	String mock_json = `
	{
		"kind": "TranslationUnitDecl",
		"inner": [
			{
				"kind": "RecordDecl",
				"name": "Device",
				"tagUsed": "struct",
				"completeDefinition": true,
				"loc": { "file": "test.h" },
				"inner": [
					{
						"kind": "RecordDecl",
						"id": "0xrec_playback",
						"tagUsed": "struct",
						"completeDefinition": true,
						"loc": { "file": "test.h" },
						"inner": [
							{ "kind": "FieldDecl", "name": "channels", "type": { "qualType": "int" } }
						]
					},
					{
						"kind": "FieldDecl",
						"name": "playback",
						"loc": { "file": "test.h" },
						"type": { "qualType": "struct (unnamed at test.h:3:5)" }
					},
					{
						"kind": "RecordDecl",
						"id": "0xrec_buffer",
						"tagUsed": "union",
						"completeDefinition": true,
						"loc": { "file": "test.h" },
						"inner": [
							{ "kind": "FieldDecl", "name": "f32", "type": { "qualType": "float *" } }
						]
					},
					{
						"kind": "FieldDecl",
						"name": "buffer",
						"loc": { "file": "test.h" },
						"type": { "qualType": "union (unnamed at test.h:6:5)" }
					}
				]
			},
			{
				"kind": "RecordDecl",
				"name": "OpParams",
				"tagUsed": "union",
				"completeDefinition": true,
				"loc": { "file": "test.h" },
				"inner": [
					{
						"kind": "RecordDecl",
						"id": "0xrec_init",
						"tagUsed": "struct",
						"completeDefinition": true,
						"loc": { "file": "test.h" },
						"inner": [
							{ "kind": "FieldDecl", "name": "code", "type": { "qualType": "int" } }
						]
					},
					{
						"kind": "FieldDecl",
						"name": "init",
						"loc": { "file": "test.h" },
						"type": { "qualType": "struct (unnamed at test.h:12:5)" }
					}
				]
			}
		]
	}
	`;

	Object* root_obj = json::tparse(mock_json)!!;

	BindgenOptions opts = {
		.header_path = "test.h",
		.module_name = "test"
	};

	CTranslationUnit tu;
	tu.init(tmem);

	bindgen::parse_clang_ast_json(tmem, &tu, root_obj, opts);

	String code = bindgen::emit_c3_bindings(tmem, &tu, opts);

	// The nested anonymous struct and union should generate synthesized record types, not void*
	assert(code.contains("struct DevicePlayback\n{\n\tint channels;\n}"));
	assert(code.contains("DevicePlayback playback;"));
	assert(!code.contains("void* playback;"));

	assert(code.contains("union DeviceBuffer\n{\n\tfloat* f32;\n}"));
	assert(code.contains("DeviceBuffer buffer;"));
	assert(!code.contains("void* buffer;"));

	assert(code.contains("struct OpParamsInit\n{\n\tint code;\n}"));
	assert(code.contains("OpParamsInit init;"));
	assert(!code.contains("void* init;"));
}

fn void test_external_system_record_embedded_by_value_size() @test
{
	String mock_json = `
	{
		"kind": "TranslationUnitDecl",
		"inner": [
			{
				"kind": "TypedefDecl",
				"name": "pthread_mutex_t",
				"loc": { "file": "/usr/include/pthread.h" },
				"type": {
					"qualType": "union pthread_mutex_t"
				},
				"inner": [
					{
						"kind": "RecordType",
						"decl": {
							"id": "0xrec_mutex",
							"kind": "RecordDecl",
							"name": "",
							"tagUsed": "union",
							"completeDefinition": true,
							"inner": [
								{
									"kind": "FieldDecl",
									"name": "__size",
									"type": { "qualType": "char[40]" }
								}
							]
						}
					}
				]
			},
			{
				"kind": "TypedefDecl",
				"name": "ma_pthread_mutex_t",
				"loc": { "file": "miniaudio.h" },
				"type": {
					"qualType": "pthread_mutex_t"
				}
			},
			{
				"kind": "RecordDecl",
				"name": "ma_event",
				"tagUsed": "struct",
				"completeDefinition": true,
				"loc": { "file": "miniaudio.h" },
				"inner": [
					{
						"kind": "FieldDecl",
						"name": "lock",
						"type": { "qualType": "ma_pthread_mutex_t" }
					}
				]
			}
		]
	}
	`;

	Object* root_obj = json::tparse(mock_json)!!;

	BindgenOptions opts = {
		.header_path = "miniaudio.h",
		.module_name = "miniaudio"
	};

	CTranslationUnit tu;
	tu.init(tmem);

	bindgen::parse_clang_ast_json(tmem, &tu, root_obj, opts);

	String code = bindgen::emit_c3_bindings(tmem, &tu, opts);

	// External types embedded by value in structs must not degrade to an 8-byte dummy stub
	assert(!code.contains("typedef PthreadMutexT = void;"));
	assert(code.contains("char[40]"));
}

fn void test_packed_struct_attribute() @test
{
	String mock_json = `
	{
		"kind": "TranslationUnitDecl",
		"inner": [
			{
				"kind": "RecordDecl",
				"name": "PackedRecord",
				"tagUsed": "struct",
				"completeDefinition": true,
				"loc": { "file": "packed.h" },
				"inner": [
					{ "kind": "PackedAttr" },
					{ "kind": "FieldDecl", "name": "a", "type": { "qualType": "char" } },
					{ "kind": "FieldDecl", "name": "b", "type": { "qualType": "int" } }
				]
			}
		]
	}
	`;

	Object* root_obj = json::tparse(mock_json)!!;
	BindgenOptions opts = { .header_path = "packed.h", .module_name = "packed" };
	CTranslationUnit tu;
	tu.init(tmem);
	bindgen::parse_clang_ast_json(tmem, &tu, root_obj, opts);
	String code = bindgen::emit_c3_bindings(tmem, &tu, opts);
	assert(code.contains("@packed"));
}

fn void test_aligned_struct_attribute() @test
{
	String mock_json = `
	{
		"kind": "TranslationUnitDecl",
		"inner": [
			{
				"kind": "RecordDecl",
				"name": "AlignedRecord",
				"tagUsed": "struct",
				"completeDefinition": true,
				"loc": { "file": "aligned.h" },
				"inner": [
					{
						"kind": "AlignedAttr",
						"inner": [
							{ "kind": "ConstantExpr", "value": "16" }
						]
					},
					{ "kind": "FieldDecl", "name": "x", "type": { "qualType": "long" } },
					{ "kind": "FieldDecl", "name": "y", "type": { "qualType": "long" } }
				]
			}
		]
	}
	`;

	Object* root_obj = json::tparse(mock_json)!!;
	BindgenOptions opts = { .header_path = "aligned.h", .module_name = "aligned" };
	CTranslationUnit tu;
	tu.init(tmem);
	bindgen::parse_clang_ast_json(tmem, &tu, root_obj, opts);
	String code = bindgen::emit_c3_bindings(tmem, &tu, opts);
	assert(code.contains("@align(16)"));
}

fn void test_bitfield_struct_emission() @test
{
	String mock_json = `
	{
		"kind": "TranslationUnitDecl",
		"inner": [
			{
				"kind": "RecordDecl",
				"name": "BitfieldRecord",
				"tagUsed": "struct",
				"completeDefinition": true,
				"loc": { "file": "bitfield.h" },
				"inner": [
					{
						"kind": "FieldDecl",
						"name": "flag1",
						"isBitfield": true,
						"type": { "qualType": "unsigned int" },
						"inner": [
							{ "kind": "ConstantExpr", "value": "1" }
						]
					},
					{
						"kind": "FieldDecl",
						"name": "flag2",
						"isBitfield": true,
						"type": { "qualType": "unsigned int" },
						"inner": [
							{ "kind": "ConstantExpr", "value": "3" }
						]
					}
				]
			}
		]
	}
	`;

	Object* root_obj = json::tparse(mock_json)!!;
	BindgenOptions opts = { .header_path = "bitfield.h", .module_name = "bitfield" };
	CTranslationUnit tu;
	tu.init(tmem);
	bindgen::parse_clang_ast_json(tmem, &tu, root_obj, opts);
	String code = bindgen::emit_c3_bindings(tmem, &tu, opts);
	assert(code.contains("bitstruct"));
}

fn void test_completing_opaque_struct_survives_struct_list_growth()
{
	DString json;
	json.tinit();
	json.append(`{ "kind": "TranslationUnitDecl", "inner": [
		{ "kind": "RecordDecl", "name": "Ctx", "tagUsed": "struct", "completeDefinition": false, "loc": { "file": "test.h" } },`);
	for (int i = 0; i < 15; i++)
	{
		json.appendf(`
		{ "kind": "RecordDecl", "name": "Filler%d", "tagUsed": "struct", "completeDefinition": true, "loc": { "file": "test.h" },
			"inner": [ { "kind": "FieldDecl", "name": "x", "type": { "qualType": "int" } } ] },`, i);
	}
	json.append(`
		{ "kind": "RecordDecl", "name": "Ctx", "tagUsed": "struct", "completeDefinition": true, "loc": { "file": "test.h" },
			"inner": [
				{ "kind": "RecordDecl", "id": "0x1", "tagUsed": "struct", "completeDefinition": true, "loc": { "file": "test.h" },
					"inner": [ { "kind": "FieldDecl", "name": "y", "type": { "qualType": "int" } } ] },
				{ "kind": "FieldDecl", "name": "inner", "type": { "qualType": "struct (unnamed struct at test.h:1:1)" } }
			] }
	] }`);

	Object* root_obj = json::tparse(json.str_view())!!;

	BindgenOptions opts = {
		.header_path = "test.h",
		.module_name = "test",
		.type_prefix = ""
	};

	CTranslationUnit tu;
	tu.init(tmem);

	bindgen::parse_clang_ast_json(tmem, &tu, root_obj, opts);

	test::eq(tu.structs.len(), 17);
	test::eq(tu.structs.get(0).c3_name, "Ctx");
	test::eq(tu.structs.get(0).is_opaque, false);
	test::eq(tu.structs.get(0).fields.len(), 1);
	test::eq(tu.structs.get(16).c3_name, "CtxInner");
}

fn void test_anonymous_enums_emit_inline_constdefs()
{
	String mock_json = `
	{
		"kind": "TranslationUnitDecl",
		"inner": [
			{
				"id": "0x1", "kind": "EnumDecl", "loc": { "file": "test.h" },
				"inner": [
					{ "kind": "EnumConstantDecl", "name": "MU_CLIP_PART", "inner": [ { "kind": "ConstantExpr", "value": "1" } ] },
					{ "kind": "EnumConstantDecl", "name": "MU_CLIP_ALL" }
				]
			},
			{
				"id": "0x2", "kind": "EnumDecl", "loc": { "file": "test.h" },
				"inner": [
					{ "kind": "EnumConstantDecl", "name": "MU_COMMAND_JUMP", "inner": [ { "kind": "ConstantExpr", "value": "1" } ] },
					{ "kind": "EnumConstantDecl", "name": "MU_COMMAND_CLIP" }
				]
			},
			{
				"id": "0x3", "kind": "EnumDecl", "loc": { "file": "test.h" },
				"inner": [
					{ "kind": "EnumConstantDecl", "name": "FOO", "inner": [ { "kind": "ConstantExpr", "value": "4" } ] },
					{ "kind": "EnumConstantDecl", "name": "BAR" }
				]
			},
			{
				"id": "0x4", "kind": "EnumDecl", "loc": { "file": "test.h" },
				"inner": [
					{ "kind": "EnumConstantDecl", "name": "K_A" },
					{ "kind": "EnumConstantDecl", "name": "K_B" }
				]
			},
			{
				"kind": "TypedefDecl", "name": "kind_t", "loc": { "file": "test.h" },
				"type": { "qualType": "enum kind_t" },
				"inner": [ { "kind": "EnumType", "decl": { "id": "0x4", "kind": "EnumDecl", "name": "" } } ]
			},
			{
				"kind": "RecordDecl", "name": "mu_Command", "tagUsed": "union", "completeDefinition": true, "loc": { "file": "test.h" },
				"inner": [ { "kind": "FieldDecl", "name": "type", "type": { "qualType": "int" } } ]
			}
		]
	}
	`;

	Object* root_obj = json::tparse(mock_json)!!;

	BindgenOptions opts = {
		.header_path = "test.h",
		.module_name = "test"
	};

	CTranslationUnit tu;
	tu.init(tmem);

	bindgen::parse_clang_ast_json(tmem, &tu, root_obj, opts);

	String code = bindgen::emit_c3_bindings(tmem, &tu, opts);

	assert(code.contains("constdef MuClip : inline int\n{\n\tPART = 1,\n\tALL = 2\n}"));
	assert(code.contains("constdef MuCommandKind : inline int\n{\n\tJUMP = 1,\n\tCLIP = 2\n}"));
	assert(code.contains("union MuCommand\n{"));
	assert(code.contains("const int FOO = 4;\nconst int BAR = 5;"));
	assert(code.contains("enum KindT\n{\n\tA,\n\tB\n}"));
	assert(!code.contains("constdef K"));
}

fn void test_type_name_keeps_camel_case_segments()
{
	test::eq(bindgen::sanitize_c3_type_name(tmem, "mu_PoolItem", ""), "MuPoolItem");
	test::eq(bindgen::sanitize_c3_type_name(tmem, "mu_BaseCommand", ""), "MuBaseCommand");
	test::eq(bindgen::sanitize_c3_type_name(tmem, "mu_Context", ""), "MuContext");
	test::eq(bindgen::sanitize_c3_type_name(tmem, "SDL_Window", ""), "SdlWindow");
	test::eq(bindgen::sanitize_c3_type_name(tmem, "sqlite3_stmt", ""), "Sqlite3Stmt");
}

fn void test_target_typedef_names_kept_for_values()
{
	String mock_json = `
	{
		"kind": "TranslationUnitDecl",
		"inner": [
			{ "kind": "TypedefDecl", "name": "mu_Id", "loc": { "file": "test.h" }, "type": { "qualType": "unsigned int" } },
			{ "kind": "TypedefDecl", "name": "mu_Font", "loc": { "file": "test.h" }, "type": { "qualType": "void *" } },
			{ "kind": "TypedefDecl", "name": "mu_Real", "loc": { "file": "test.h" }, "type": { "qualType": "float" } },
			{
				"kind": "RecordDecl", "name": "mu_Style", "tagUsed": "struct", "completeDefinition": true, "loc": { "file": "test.h" },
				"inner": [
					{ "kind": "FieldDecl", "name": "hover", "type": { "qualType": "mu_Id", "desugaredQualType": "unsigned int" } },
					{ "kind": "FieldDecl", "name": "font", "type": { "qualType": "mu_Font", "desugaredQualType": "void *" } },
					{ "kind": "FieldDecl", "name": "ext", "type": { "qualType": "__u32", "desugaredQualType": "unsigned int" } }
				]
			},
			{
				"kind": "FunctionDecl", "name": "mu_set", "loc": { "file": "test.h" },
				"type": { "qualType": "void (mu_Id, mu_Real)", "desugaredQualType": "void (unsigned int, float)" },
				"inner": [
					{ "kind": "ParmVarDecl", "name": "id", "type": { "qualType": "mu_Id", "desugaredQualType": "unsigned int" } },
					{ "kind": "ParmVarDecl", "name": "low", "type": { "qualType": "mu_Real", "desugaredQualType": "float" } }
				]
			}
		]
	}
	`;

	Object* root_obj = json::tparse(mock_json)!!;

	BindgenOptions opts = {
		.header_path = "test.h",
		.module_name = "test",
		.strip_func_prefix = "mu_"
	};

	CTranslationUnit tu;
	tu.init(tmem);

	bindgen::parse_clang_ast_json(tmem, &tu, root_obj, opts);

	String code = bindgen::emit_c3_bindings(tmem, &tu, opts);

	assert(code.contains("\tMuId hover;\n"));
	assert(code.contains("\tMuFont font;\n"));
	assert(code.contains("\tuint ext;\n"));
	assert(code.contains("extern fn void set(MuId id, MuReal low)"));
}

fn void test_function_pointer_fields_emit_typed_aliases()
{
	String mock_json = `
	{
		"kind": "TranslationUnitDecl",
		"inner": [
			{ "kind": "TypedefDecl", "name": "mu_Font", "loc": { "file": "test.h" }, "type": { "qualType": "void *" } },
			{
				"kind": "RecordDecl", "name": "mu_Context", "tagUsed": "struct", "completeDefinition": true, "loc": { "file": "test.h" },
				"inner": [
					{ "kind": "FieldDecl", "name": "text_width", "type": { "qualType": "int (*)(mu_Font, const char *, int)" } },
					{ "kind": "FieldDecl", "name": "draw_frame", "type": { "qualType": "void (*)(mu_Context *, int)" } },
					{ "kind": "FieldDecl", "name": "chain", "type": { "qualType": "void (**)(void)" } }
				]
			}
		]
	}
	`;

	Object* root_obj = json::tparse(mock_json)!!;

	BindgenOptions opts = {
		.header_path = "test.h",
		.module_name = "test"
	};

	CTranslationUnit tu;
	tu.init(tmem);

	bindgen::parse_clang_ast_json(tmem, &tu, root_obj, opts);

	String code = bindgen::emit_c3_bindings(tmem, &tu, opts);

	assert(code.contains("alias MuContextTextWidthFn = fn int(MuFont, ZString, int);"));
	assert(code.contains("alias MuContextDrawFrameFn = fn void(MuContext*, int);"));
	assert(code.contains("\tMuContextTextWidthFn text_width;\n"));
	assert(code.contains("\tMuContextDrawFrameFn draw_frame;\n"));
	assert(code.contains("\tvoid* chain;\n"));
}

fn void test_object_like_macros_are_collected_for_probing()
{
	String preprocessed = `# 1 "<built-in>" 1
#define __STDC__ 1
# 1 "/inc/test.h" 1
#define TEST_H
#define MU_COMMANDLIST_SIZE (256 * 1024)
#define MU_MAX_WIDTHS 16
#define MU_REAL float
#define mu_min(a, b) ((a) < (b) ? (a) : (b))
#define MU_OPEN {
#define MU_TEXT "(unbalanced"
#define _MU_PRIVATE 1
#define MU_ANON 3
#define MU_MAX_WIDTHS 32
# 1 "/usr/include/other.h" 1
#define OTHER_SIZE 8
`;

	BindgenOptions opts = {
		.header_path = "/inc/test.h",
		.module_name = "test"
	};

	CTranslationUnit tu;
	tu.init(tmem);
	tu.constants.push({ .name = "MU_ANON", .value = "3", .c3_type = "int" });

	MacroDefinition[] macros = bindgen::collect_macro_definitions(tmem, &tu, preprocessed, opts);

	test::eq(macros.len, 4);
	test::eq(macros[0].name, "MU_COMMANDLIST_SIZE");
	test::eq(macros[0].body, "(256 * 1024)");
	test::eq(macros[1].name, "MU_MAX_WIDTHS");
	test::eq(macros[1].body, "32");
	test::eq(macros[2].name, "MU_REAL");
	test::eq(macros[3].name, "MU_TEXT");

	String probe = bindgen::build_macro_probe("/inc/test.h", macros);
	assert(probe.starts_with("#include \"/inc/test.h\"\n"));
	assert(probe.contains("static const __auto_type __c3_probe_a_MU_MAX_WIDTHS = (MU_MAX_WIDTHS);\n"));
	assert(probe.contains("\n#line 1 \"c3_probe_b.c\"\n"));
	assert(probe.contains("static const __auto_type __c3_probe_b_MU_MAX_WIDTHS = (MU_MAX_WIDTHS);\n"));
}

fn void test_macro_probe_emits_typed_constants()
{
	String probe_json = `
	{
		"kind": "TranslationUnitDecl",
		"inner": [
			{ "kind": "VarDecl", "name": "__c3_probe_a_EMPTY", "type": { "qualType": "const int" },
				"inner": [ { "kind": "ParenExpr", "type": { "qualType": "int" }, "inner": [] } ] },
			{ "kind": "VarDecl", "name": "__c3_probe_a_FLAG_A", "type": { "qualType": "const int" },
				"inner": [ { "kind": "ParenExpr", "type": { "qualType": "int" }, "inner": [ { "kind": "IntegerLiteral", "type": { "qualType": "int" }, "value": "16384" } ] } ] },
			{ "kind": "VarDecl", "name": "__c3_probe_a_PERMS", "type": { "qualType": "const int" },
				"inner": [ { "kind": "IntegerLiteral", "type": { "qualType": "int" }, "value": "493" } ] },
			{ "kind": "VarDecl", "name": "__c3_probe_a_MASK", "type": { "qualType": "const unsigned int" },
				"inner": [ { "kind": "IntegerLiteral", "type": { "qualType": "unsigned int" }, "value": "255" } ] },
			{ "kind": "VarDecl", "name": "__c3_probe_a_PI", "type": { "qualType": "const float" },
				"inner": [ { "kind": "FloatingLiteral", "type": { "qualType": "float" }, "value": "3.14159274" } ] },
			{ "kind": "VarDecl", "name": "__c3_probe_a_DEG2RAD", "type": { "qualType": "const float" },
				"inner": [ { "kind": "ParenExpr", "type": { "qualType": "float" }, "inner": [ { "kind": "BinaryOperator", "type": { "qualType": "float" }, "opcode": "/",
					"inner": [ { "kind": "FloatingLiteral", "type": { "qualType": "float" }, "value": "3.14159274" }, { "kind": "FloatingLiteral", "type": { "qualType": "float" }, "value": "180" } ] } ] } ] },
			{ "kind": "VarDecl", "name": "__c3_probe_a_BIG", "type": { "qualType": "const unsigned long long" },
				"inner": [ { "kind": "BinaryOperator", "type": { "qualType": "unsigned long long" }, "opcode": "<<",
					"inner": [ { "kind": "IntegerLiteral", "type": { "qualType": "unsigned long long" }, "value": "1" }, { "kind": "IntegerLiteral", "type": { "qualType": "int" }, "value": "40" } ] } ] },
			{ "kind": "VarDecl", "name": "__c3_probe_a_NEG", "type": { "qualType": "const int" },
				"inner": [ { "kind": "ParenExpr", "type": { "qualType": "int" }, "inner": [ { "kind": "UnaryOperator", "type": { "qualType": "int" }, "opcode": "-",
					"inner": [ { "kind": "IntegerLiteral", "type": { "qualType": "int" }, "value": "30799" } ] } ] } ] },
			{ "kind": "VarDecl", "name": "__c3_probe_a_MIX", "type": { "qualType": "const int" },
				"inner": [ { "kind": "BinaryOperator", "type": { "qualType": "int" }, "opcode": "|",
					"inner": [ { "kind": "IntegerLiteral", "type": { "qualType": "int" }, "value": "16384" },
						{ "kind": "BinaryOperator", "type": { "qualType": "int" }, "opcode": "<<",
							"inner": [ { "kind": "IntegerLiteral", "type": { "qualType": "int" }, "value": "3" }, { "kind": "IntegerLiteral", "type": { "qualType": "int" }, "value": "2" } ] } ] } ] },
			{ "kind": "VarDecl", "name": "__c3_probe_a_NAME", "type": { "qualType": "char *const" },
				"inner": [ { "kind": "ImplicitCastExpr", "type": { "qualType": "char *" }, "castKind": "ArrayToPointerDecay",
					"inner": [ { "kind": "StringLiteral", "type": { "qualType": "char[4]" }, "value": "\"a\\tb\"" } ] } ] },
			{ "kind": "VarDecl", "name": "__c3_probe_a_SIGNATURE", "type": { "qualType": "char *const" },
				"inner": [ { "kind": "StringLiteral", "type": { "qualType": "char[5]" }, "value": "\"\\033Lua\\0\"" } ] },
			{ "kind": "VarDecl", "name": "__c3_probe_a_CH", "type": { "qualType": "const int" },
				"inner": [ { "kind": "CharacterLiteral", "type": { "qualType": "int" }, "value": 120 } ] },
			{ "kind": "VarDecl", "name": "__c3_probe_a_RED", "type": { "qualType": "const Color", "desugaredQualType": "const struct Color" },
				"inner": [ { "kind": "ImplicitCastExpr", "type": { "qualType": "Color" }, "castKind": "LValueToRValue",
					"inner": [ { "kind": "CompoundLiteralExpr", "type": { "qualType": "Color" },
						"inner": [ { "kind": "InitListExpr", "type": { "qualType": "Color" }, "inner": [
							{ "kind": "ImplicitCastExpr", "type": { "qualType": "unsigned char" }, "castKind": "IntegralCast", "inner": [ { "kind": "IntegerLiteral", "type": { "qualType": "int" }, "value": "230" } ] },
							{ "kind": "ImplicitCastExpr", "type": { "qualType": "unsigned char" }, "castKind": "IntegralCast", "inner": [ { "kind": "IntegerLiteral", "type": { "qualType": "int" }, "value": "41" } ] }
						] } ] } ] } ] },
			{ "kind": "VarDecl", "name": "__c3_probe_a_BROKEN", "isInvalid": true, "type": { "qualType": "const __auto_type" } },
			{ "kind": "VarDecl", "name": "__c3_probe_a_LESS", "type": { "qualType": "const int" },
				"inner": [ { "kind": "BinaryOperator", "type": { "qualType": "int" }, "opcode": "<",
					"inner": [ { "kind": "IntegerLiteral", "type": { "qualType": "int" }, "value": "1" }, { "kind": "IntegerLiteral", "type": { "qualType": "int" }, "value": "2" } ] } ] },
			{ "kind": "VarDecl", "name": "__c3_probe_a_TRANSIENT", "type": { "qualType": "const sqlite3_destructor_type", "desugaredQualType": "void (*const)(void *)" },
				"inner": [ { "kind": "CStyleCastExpr", "type": { "qualType": "sqlite3_destructor_type", "desugaredQualType": "void (*)(void *)" },
					"inner": [ { "kind": "IntegerLiteral", "type": { "qualType": "int" }, "value": "1" } ] } ] },
			{ "kind": "VarDecl", "name": "__c3_probe_a_NIL", "type": { "qualType": "void *const" },
				"inner": [ { "kind": "CStyleCastExpr", "type": { "qualType": "void *" }, "inner": [ { "kind": "IntegerLiteral", "type": { "qualType": "int" }, "value": "0" } ] } ] },
			{ "kind": "VarDecl", "name": "__c3_probe_b_EMPTY", "type": { "qualType": "const int" },
				"inner": [ { "kind": "ParenExpr", "type": { "qualType": "int" }, "inner": [] } ] },
			{ "kind": "VarDecl", "name": "__c3_probe_b_FLAG_A", "type": { "qualType": "const int" },
				"inner": [ { "kind": "ParenExpr", "type": { "qualType": "int" }, "inner": [ { "kind": "IntegerLiteral", "type": { "qualType": "int" }, "value": "16384" } ] } ] },
			{ "kind": "VarDecl", "name": "__c3_probe_b_PERMS", "type": { "qualType": "const int" },
				"inner": [ { "kind": "IntegerLiteral", "type": { "qualType": "int" }, "value": "493" } ] },
			{ "kind": "VarDecl", "name": "__c3_probe_b_MASK", "type": { "qualType": "const unsigned int" },
				"inner": [ { "kind": "IntegerLiteral", "type": { "qualType": "unsigned int" }, "value": "255" } ] },
			{ "kind": "VarDecl", "name": "__c3_probe_b_PI", "type": { "qualType": "const float" },
				"inner": [ { "kind": "FloatingLiteral", "type": { "qualType": "float" }, "value": "3.14159274" } ] },
			{ "kind": "VarDecl", "name": "__c3_probe_b_DEG2RAD", "type": { "qualType": "const float" },
				"inner": [ { "kind": "ParenExpr", "type": { "qualType": "float" }, "inner": [ { "kind": "BinaryOperator", "type": { "qualType": "float" }, "opcode": "/",
					"inner": [ { "kind": "FloatingLiteral", "type": { "qualType": "float" }, "value": "3.14159274" }, { "kind": "FloatingLiteral", "type": { "qualType": "float" }, "value": "180" } ] } ] } ] },
			{ "kind": "VarDecl", "name": "__c3_probe_b_BIG", "type": { "qualType": "const unsigned long long" },
				"inner": [ { "kind": "BinaryOperator", "type": { "qualType": "unsigned long long" }, "opcode": "<<",
					"inner": [ { "kind": "IntegerLiteral", "type": { "qualType": "unsigned long long" }, "value": "1" }, { "kind": "IntegerLiteral", "type": { "qualType": "int" }, "value": "40" } ] } ] },
			{ "kind": "VarDecl", "name": "__c3_probe_b_NEG", "type": { "qualType": "const int" },
				"inner": [ { "kind": "ParenExpr", "type": { "qualType": "int" }, "inner": [ { "kind": "UnaryOperator", "type": { "qualType": "int" }, "opcode": "-",
					"inner": [ { "kind": "IntegerLiteral", "type": { "qualType": "int" }, "value": "30799" } ] } ] } ] },
			{ "kind": "VarDecl", "name": "__c3_probe_b_MIX", "type": { "qualType": "const int" },
				"inner": [ { "kind": "BinaryOperator", "type": { "qualType": "int" }, "opcode": "|",
					"inner": [ { "kind": "IntegerLiteral", "type": { "qualType": "int" }, "value": "16384" },
						{ "kind": "BinaryOperator", "type": { "qualType": "int" }, "opcode": "<<",
							"inner": [ { "kind": "IntegerLiteral", "type": { "qualType": "int" }, "value": "3" }, { "kind": "IntegerLiteral", "type": { "qualType": "int" }, "value": "2" } ] } ] } ] },
			{ "kind": "VarDecl", "name": "__c3_probe_b_NAME", "type": { "qualType": "char *const" },
				"inner": [ { "kind": "ImplicitCastExpr", "type": { "qualType": "char *" }, "castKind": "ArrayToPointerDecay",
					"inner": [ { "kind": "StringLiteral", "type": { "qualType": "char[4]" }, "value": "\"a\\tb\"" } ] } ] },
			{ "kind": "VarDecl", "name": "__c3_probe_b_SIGNATURE", "type": { "qualType": "char *const" },
				"inner": [ { "kind": "StringLiteral", "type": { "qualType": "char[5]" }, "value": "\"\\033Lua\\0\"" } ] },
			{ "kind": "VarDecl", "name": "__c3_probe_b_CH", "type": { "qualType": "const int" },
				"inner": [ { "kind": "CharacterLiteral", "type": { "qualType": "int" }, "value": 120 } ] },
			{ "kind": "VarDecl", "name": "__c3_probe_b_RED", "type": { "qualType": "const Color", "desugaredQualType": "const struct Color" },
				"inner": [ { "kind": "ImplicitCastExpr", "type": { "qualType": "Color" }, "castKind": "LValueToRValue",
					"inner": [ { "kind": "CompoundLiteralExpr", "type": { "qualType": "Color" },
						"inner": [ { "kind": "InitListExpr", "type": { "qualType": "Color" }, "inner": [
							{ "kind": "ImplicitCastExpr", "type": { "qualType": "unsigned char" }, "castKind": "IntegralCast", "inner": [ { "kind": "IntegerLiteral", "type": { "qualType": "int" }, "value": "230" } ] },
							{ "kind": "ImplicitCastExpr", "type": { "qualType": "unsigned char" }, "castKind": "IntegralCast", "inner": [ { "kind": "IntegerLiteral", "type": { "qualType": "int" }, "value": "41" } ] }
						] } ] } ] } ] },
			{ "kind": "VarDecl", "name": "__c3_probe_b_BROKEN", "isInvalid": true, "type": { "qualType": "const __auto_type" } },
			{ "kind": "VarDecl", "name": "__c3_probe_b_LESS", "type": { "qualType": "const int" },
				"inner": [ { "kind": "BinaryOperator", "type": { "qualType": "int" }, "opcode": "<",
					"inner": [ { "kind": "IntegerLiteral", "type": { "qualType": "int" }, "value": "1" }, { "kind": "IntegerLiteral", "type": { "qualType": "int" }, "value": "2" } ] } ] },
			{ "kind": "VarDecl", "name": "__c3_probe_b_TRANSIENT", "type": { "qualType": "const sqlite3_destructor_type", "desugaredQualType": "void (*const)(void *)" },
				"inner": [ { "kind": "CStyleCastExpr", "type": { "qualType": "sqlite3_destructor_type", "desugaredQualType": "void (*)(void *)" },
					"inner": [ { "kind": "IntegerLiteral", "type": { "qualType": "int" }, "value": "1" } ] } ] },
			{ "kind": "VarDecl", "name": "__c3_probe_b_NIL", "type": { "qualType": "void *const" },
				"inner": [ { "kind": "CStyleCastExpr", "type": { "qualType": "void *" }, "inner": [ { "kind": "IntegerLiteral", "type": { "qualType": "int" }, "value": "0" } ] } ] },
			{ "kind": "VarDecl", "name": "__c3_probe_a_HERE", "type": { "qualType": "char *const" },
				"inner": [ { "kind": "StringLiteral", "type": { "qualType": "char[9]" }, "value": "\"/tmp/p.c\"" } ] },
			{ "kind": "VarDecl", "name": "__c3_probe_b_HERE", "type": { "qualType": "char *const" },
				"inner": [ { "kind": "StringLiteral", "type": { "qualType": "char[13]" }, "value": "\"c3_probe_b.c\"" } ] }
		]
	}
	`;

	MacroDefinition[] macros = {
		{ "FLAG_A", "0x4000" },
		{ "PERMS", "0755" },
		{ "MASK", "0xFFu" },
		{ "PI", "3.14159265358979323846f" },
		{ "DEG2RAD", "(PI/180.0f)" },
		{ "BIG", "(1ULL << 40)" },
		{ "NEG", "(-30799)" },
		{ "MIX", "(FLAG_A | 3 << 2)" },
		{ "NAME", "\"a\\tb\"" },
		{ "SIGNATURE", "\"\\x1bLua\\0\"" },
		{ "CH", "'x'" },
		{ "RED", "CLITERAL(Color){ 230, 41 }" },
		{ "BROKEN", "int int" },
		{ "LESS", "(1 < 2)" },
		{ "NIL", "((void*)0)" },
		{ "TRANSIENT", "((sqlite3_destructor_type)1)" },
		{ "MU_REAL", "float" },
		{ "HERE", "__FILE__" },
		{ "EMPTY", "(EMPTY_EXPR)" }
	};

	BindgenOptions opts = {
		.header_path = "test.h",
		.module_name = "test"
	};

	CTranslationUnit tu;
	tu.init(tmem);

	bindgen::parse_macro_probe(tmem, &tu, macros, json::tparse(probe_json)!!, opts);

	String code = bindgen::emit_c3_bindings(tmem, &tu, opts);

	assert(code.contains("const int FLAG_A = 0x4000;\n"));
	assert(code.contains("const int PERMS = 0o755;\n"));
	assert(code.contains("const uint MASK = 0xFF;\n"));
	assert(code.contains("const float PI = 3.14159265358979323846;\n"));
	assert(code.contains("const float DEG2RAD = (3.14159274f / 180.0f);\n"));
	assert(code.contains("const ulong BIG = ((ulong)1 << 40);\n"));
	assert(code.contains("const int NEG = -30799;\n"));
	assert(code.contains("const int MIX = (16384 | (3 << 2));\n"));
	assert(code.contains("const ZString NAME = \"a\\tb\";\n"));
	assert(code.contains("const ZString SIGNATURE = \"\\x1bLua\\0\";\n"));
	assert(code.contains("const int CH = 120;\n"));
	assert(code.contains("const Color RED = { 230, 41 };\n"));
	assert(!code.contains("BROKEN"));
	assert(!code.contains("LESS"));
	assert(!code.contains("NIL"));
	assert(!code.contains("TRANSIENT"));
	assert(!code.contains("MU_REAL"));
	assert(!code.contains("HERE"));
	assert(!code.contains("EMPTY"));
}
fn void test_function_pointer_returning_function_pointer()
{
	String mock_json = `
	{
		"kind": "TranslationUnitDecl",
		"inner": [
			{
				"kind": "RecordDecl", "name": "sqlite3_vfs", "tagUsed": "struct", "completeDefinition": true, "loc": { "file": "test.h" },
				"inner": [
					{ "kind": "FieldDecl", "name": "xDlSym", "type": { "qualType": "void (*(*)(sqlite3_vfs *, void *, const char *))(void)" } },
					{ "kind": "FieldDecl", "name": "xPlain", "type": { "qualType": "int (*)(int, const char *)" } }
				]
			}
		]
	}
	`;

	Object* root_obj = json::tparse(mock_json)!!;

	BindgenOptions opts = {
		.header_path = "test.h",
		.module_name = "test"
	};

	CTranslationUnit tu;
	tu.init(tmem);

	bindgen::parse_clang_ast_json(tmem, &tu, root_obj, opts);

	String code = bindgen::emit_c3_bindings(tmem, &tu, opts);

	assert(code.contains("alias Sqlite3VfsXDlSymFn = fn void*(Sqlite3Vfs*, void*, ZString);"));
	assert(code.contains("alias Sqlite3VfsXPlainFn = fn int(int, ZString);"));
}

fn void test_typedef_references_resolve_to_emitted_aliases()
{
	String mock_json = `
	{
		"kind": "TranslationUnitDecl",
		"inner": [
			{ "kind": "TypedefDecl", "name": "mode_t", "loc": { "file": "/usr/include/sys/types.h" }, "type": { "qualType": "__mode_t", "desugaredQualType": "unsigned int" } },
			{ "kind": "TypedefDecl", "name": "Sint64", "loc": { "file": "test.h" }, "type": { "qualType": "int64_t", "desugaredQualType": "long" } },
			{ "kind": "TypedefDecl", "name": "SDL_Time", "loc": { "file": "test.h" }, "type": { "qualType": "Sint64", "desugaredQualType": "long" } },
			{ "kind": "TypedefDecl", "name": "my_mode_t", "loc": { "file": "test.h" }, "type": { "qualType": "mode_t", "desugaredQualType": "unsigned int" } },
			{ "kind": "TypedefDecl", "name": "assert_func", "loc": { "file": "test.h" }, "type": { "qualType": "void (int, const char *)" } },
			{
				"kind": "FunctionDecl", "name": "set_assert", "loc": { "file": "test.h" }, "type": { "qualType": "int (assert_func *)" },
				"inner": [
					{ "kind": "ParmVarDecl", "name": "func", "type": { "qualType": "assert_func *", "desugaredQualType": "void (*)(int, const char *)" } }
				]
			},
			{
				"kind": "RecordDecl", "name": "SDL_IOStreamInterface", "tagUsed": "struct", "completeDefinition": true, "loc": { "file": "test.h" },
				"inner": [
					{ "kind": "FieldDecl", "name": "size", "type": { "qualType": "int (*)(void *)" } },
					{ "kind": "FieldDecl", "name": "on_assert", "type": { "qualType": "assert_func *", "desugaredQualType": "void (*)(int, const char *)" } }
				]
			},
			{
				"kind": "FunctionDecl", "name": "vlog", "loc": { "file": "test.h" }, "type": { "qualType": "void (const char *, struct __va_list_tag *)" },
				"inner": [
					{ "kind": "ParmVarDecl", "name": "fmt", "type": { "qualType": "const char *" } },
					{ "kind": "ParmVarDecl", "name": "args", "type": { "qualType": "struct __va_list_tag *" } }
				]
			}
		]
	}
	`;

	Object* root_obj = json::tparse(mock_json)!!;

	BindgenOptions opts = {
		.header_path = "test.h",
		.module_name = "test"
	};

	CTranslationUnit tu;
	tu.init(tmem);

	bindgen::parse_clang_ast_json(tmem, &tu, root_obj, opts);

	String code = bindgen::emit_c3_bindings(tmem, &tu, opts);

	assert(code.contains("alias SdlTime = Sint64;\n"));
	assert(code.contains("alias MyModeT = uint;\n"));
	assert(!code.contains("alias ModeT"));
	assert(code.contains("extern fn int set_assert(AssertFunc func)"));
	assert(code.contains("alias SdlIOStreamInterfaceSizeFn = fn int(void*);\n"));
	assert(code.contains("\tSdlIOStreamInterfaceSizeFn size;\n"));
	assert(code.contains("\tAssertFunc on_assert;\n"));
	assert(code.contains("extern fn void vlog(ZString fmt, CVaList args)"));
}

fn void test_named_enum_values_drop_common_prefix()
{
	String mock_json = `
	{
		"kind": "TranslationUnitDecl",
		"inner": [
			{
				"kind": "EnumDecl", "name": "MDB_cursor_op", "loc": { "file": "test.h" },
				"inner": [
					{ "kind": "EnumConstantDecl", "name": "MDB_FIRST" },
					{ "kind": "EnumConstantDecl", "name": "MDB_FIRST_DUP" }
				]
			},
			{
				"kind": "EnumDecl", "name": "SDL_Scancode", "loc": { "file": "test.h" },
				"inner": [
					{ "kind": "EnumConstantDecl", "name": "SDL_SCANCODE_A" },
					{ "kind": "EnumConstantDecl", "name": "SDL_SCANCODE_1" }
				]
			},
			{
				"kind": "EnumDecl", "name": "Key", "loc": { "file": "test.h" },
				"inner": [
					{ "kind": "EnumConstantDecl", "name": "KEY_A" },
					{ "kind": "EnumConstantDecl", "name": "KEY_1" }
				]
			}
		]
	}
	`;

	Object* root_obj = json::tparse(mock_json)!!;

	BindgenOptions opts = {
		.header_path = "test.h",
		.module_name = "test"
	};

	CTranslationUnit tu;
	tu.init(tmem);

	bindgen::parse_clang_ast_json(tmem, &tu, root_obj, opts);

	String code = bindgen::emit_c3_bindings(tmem, &tu, opts);

	assert(code.contains("enum MdbCursorOp\n{\n\tFIRST,\n\tFIRST_DUP\n}"));
	assert(code.contains("enum SdlScancode\n{\n\tSCANCODE_A,\n\tSCANCODE_1\n}"));
	assert(code.contains("enum Key\n{\n\tKEY_A,\n\tKEY_1\n}"));
}

fn void test_pointer_typedef_sharing_tag_name_keeps_both_types()
{
	String mock_json = `
	{
		"kind": "TranslationUnitDecl",
		"inner": [
			{ "kind": "RecordDecl", "name": "_Handle", "tagUsed": "struct", "loc": { "file": "test.h" } },
			{
				"kind": "TypedefDecl", "name": "Handle", "loc": { "file": "test.h" },
				"type": { "qualType": "struct _Handle *" },
				"inner": [ { "kind": "PointerType", "inner": [ { "kind": "RecordType", "decl": { "kind": "RecordDecl", "name": "_Handle" } } ] } ]
			},
			{ "kind": "FunctionDecl", "name": "handle_open", "loc": { "file": "test.h" }, "type": { "qualType": "Handle (void)" } },
			{
				"kind": "FunctionDecl", "name": "handle_use", "loc": { "file": "test.h" }, "type": { "qualType": "void (struct _Handle *)" },
				"inner": [ { "kind": "ParmVarDecl", "name": "h", "type": { "qualType": "struct _Handle *" } } ]
			},
			{ "kind": "RecordDecl", "name": "Thing", "tagUsed": "struct", "loc": { "file": "test.h" } },
			{
				"kind": "TypedefDecl", "name": "Thing", "loc": { "file": "test.h" },
				"type": { "qualType": "struct Thing" },
				"inner": [ { "kind": "RecordType", "decl": { "kind": "RecordDecl", "name": "Thing" } } ]
			},
			{
				"kind": "FunctionDecl", "name": "thing_make", "loc": { "file": "test.h" }, "type": { "qualType": "Thing *(void)" }
			}
		]
	}
	`;

	Object* root_obj = json::tparse(mock_json)!!;

	BindgenOptions opts = {
		.header_path = "test.h",
		.module_name = "test"
	};

	CTranslationUnit tu;
	tu.init(tmem);

	bindgen::parse_clang_ast_json(tmem, &tu, root_obj, opts);

	String code = bindgen::emit_c3_bindings(tmem, &tu, opts);

	assert(code.contains("typedef _Handle = void;\n"));
	assert(code.contains("alias Handle = _Handle*;\n"));
	assert(code.contains("extern fn Handle handle_open()"));
	assert(code.contains("extern fn void handle_use(_Handle* h)"));
	assert(code.contains("typedef Thing = void;\n"));
	assert(code.contains("extern fn Thing* thing_make()"));
}

fn void test_clang_output_with_large_stderr_does_not_block() @feat(POSIX)
{
	posix_signal::alarm(30);
	defer posix_signal::alarm(0);
	DString source;
	source.tinit();
	for (int i = 0; i < 3000; i++)
	{
		source.appendf("#define BAD_%d int int\nstatic const __auto_type probe_%d = (BAD_%d);\nstatic const int good_%d = %d;\n", i, i, i, i, i);
	}
	Path dir = path::temp_directory(tmem)!!;
	String header = (String)dir.tappend("c3_ls_large_stderr_probe.c")!!;
	file::save(header, source.str_view())!!;
	defer (void)file::delete(header);

	BindgenOptions opts = { .header_path = header };
	ClangOutput? out = bindgen::run_clang_raw(tmem, opts, { "-Xclang", "-ast-dump=json", "-fsyntax-only", "-ferror-limit=0" });
	if (catch out) return;

	assert(out.stderr_str.len > 65536);
	assert(out.stdout_str.starts_with("{"));
	assert(out.stdout_str.contains("good_2999"));
	json::tparse(out.stdout_str)!!;
}

fn void test_external_typedef_to_underscored_tag()
{
	String mock_json = `
	{
		"kind": "TranslationUnitDecl",
		"inner": [
			{ "kind": "RecordDecl", "name": "_ExtHandle", "tagUsed": "struct", "loc": { "file": "/usr/include/ext.h" } },
			{
				"kind": "TypedefDecl", "name": "ExtHandle", "loc": { "file": "/usr/include/ext.h" },
				"type": { "qualType": "struct _ExtHandle *" },
				"inner": [ { "kind": "PointerType", "inner": [ { "kind": "RecordType", "decl": { "kind": "RecordDecl", "name": "_ExtHandle" } } ] } ]
			},
			{
				"kind": "TypedefDecl", "name": "ext_alias_t", "loc": { "file": "/usr/include/ext.h" },
				"type": { "qualType": "struct _ExtHandle *" },
				"inner": [ { "kind": "PointerType", "inner": [ { "kind": "RecordType", "decl": { "kind": "RecordDecl", "name": "_ExtHandle" } } ] } ]
			},
			{
				"kind": "FunctionDecl", "name": "use_handle", "loc": { "file": "test.h" }, "type": { "qualType": "void (ext_alias_t)" },
				"inner": [ { "kind": "ParmVarDecl", "name": "h", "type": { "qualType": "ext_alias_t", "desugaredQualType": "struct _ExtHandle *" } } ]
			}
		]
	}
	`;

	Object* root_obj = json::tparse(mock_json)!!;

	BindgenOptions opts = {
		.header_path = "test.h",
		.module_name = "test"
	};

	CTranslationUnit tu;
	tu.init(tmem);

	bindgen::parse_clang_ast_json(tmem, &tu, root_obj, opts);

	String code = bindgen::emit_c3_bindings(tmem, &tu, opts);

	assert(code.contains("alias ExtAliasT = _ExtHandle*;\n"));
	assert(code.contains("typedef _ExtHandle = void;\n"));
	assert(code.contains("extern fn void use_handle(ExtAliasT h)"));
}

fn void test_pointer_typedef_to_unnamed_struct_names_the_struct()
{
	String mock_json = `
	{
		"kind": "TranslationUnitDecl",
		"inner": [
			{
				"id": "0x1", "kind": "RecordDecl", "tagUsed": "struct", "completeDefinition": true, "loc": { "file": "test.h" },
				"inner": [
					{ "kind": "FieldDecl", "name": "fd", "type": { "qualType": "int" } },
					{ "kind": "FieldDecl", "name": "name", "type": { "qualType": "char *" } }
				]
			},
			{
				"kind": "TypedefDecl", "name": "PrivPtr", "loc": { "file": "test.h" },
				"type": { "qualType": "struct (unnamed at test.h:1:9) *" },
				"inner": [ { "kind": "PointerType", "inner": [ { "kind": "RecordType", "decl": { "id": "0x1", "kind": "RecordDecl", "name": "" } } ] } ]
			},
			{
				"kind": "TypedefDecl", "name": "OtherPtr", "loc": { "file": "test.h" },
				"type": { "qualType": "struct (unnamed at test.h:1:9) *" },
				"inner": [ { "kind": "PointerType", "inner": [ { "kind": "RecordType", "decl": { "id": "0x1", "kind": "RecordDecl", "name": "" } } ] } ]
			},
			{
				"kind": "FunctionDecl", "name": "priv_fd", "loc": { "file": "test.h" }, "type": { "qualType": "int (PrivPtr)" },
				"inner": [ { "kind": "ParmVarDecl", "name": "p", "type": { "qualType": "PrivPtr", "desugaredQualType": "struct (unnamed at test.h:1:9) *" } } ]
			}
		]
	}
	`;

	Object* root_obj = json::tparse(mock_json)!!;

	BindgenOptions opts = {
		.header_path = "test.h",
		.module_name = "test"
	};

	CTranslationUnit tu;
	tu.init(tmem);

	bindgen::parse_clang_ast_json(tmem, &tu, root_obj, opts);

	String code = bindgen::emit_c3_bindings(tmem, &tu, opts);

	assert(code.contains("struct _PrivPtr\n{\n\tint fd;\n\tchar* name;\n}"));
	assert(code.contains("alias PrivPtr = _PrivPtr*;\n"));
	assert(code.contains("alias OtherPtr = _PrivPtr*;\n"));
	assert(code.contains("extern fn int priv_fd(PrivPtr p)"));
	assert(!code.contains("Void"));
}

module lsp::bindgen_test::posix_signal;

extern fn uint alarm(uint seconds) @cname("alarm");
