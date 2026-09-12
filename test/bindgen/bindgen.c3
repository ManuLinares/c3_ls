module lsp::bindgen_test @test;

import lsp::bindgen;
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
	test::eq(bindgen::map_c_type_to_c3(tmem, "const char *", "", true), "ZString");
	test::eq(bindgen::map_c_type_to_c3(tmem, "const char *", "", false), "ZString");
	test::eq(bindgen::map_c_type_to_c3(tmem, "char *", "", false), "char*");
	test::eq(bindgen::map_c_type_to_c3(tmem, "long", "", false), "CLong");
	test::eq(bindgen::map_c_type_to_c3(tmem, "unsigned long", "", false), "CULong");
	test::eq(bindgen::map_c_type_to_c3(tmem, "int *", "", false), "int*");
	test::eq(bindgen::map_c_type_to_c3(tmem, "void **", "", false), "void**");
	test::eq(bindgen::map_c_type_to_c3(tmem, "void *[2]", "", false), "void*[2]");
	test::eq(bindgen::map_c_type_to_c3(tmem, "int *[10]", "", false), "int*[10]");
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
		.strip_func_prefix = "",
		.strip_enum_prefix = "MOUSE_BUTTON_"
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
	assert(code.contains("LEFT,"));
	assert(code.contains("RIGHT"));
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
	assert(!code.contains("struct Fts5Tokenizer { void* _unused; }"));
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

	assert(code.contains("void* init_fn;"));
	assert(!code.contains("Int (*)(void)"));
	assert(code.contains("struct ExternalMatrix { void* _unused; }"));
	assert(!code.contains("struct ExternalMatrix[3][3"));
	assert(code.contains("struct ExternalHandle { void* _unused; }"));
}

fn void test_module_name_length_limit_and_zero_length_array()
{
	String long_mod = "libvirt_gconfig_domain_graphics_spice";
	String sanitized_mod = bindgen::sanitize_module_name(tmem, long_mod);
	assert(sanitized_mod.len <= 31);
	test::eq(sanitized_mod, "libvirt_gconfig_domain_graphics");

	String code_zero_arr = bindgen::map_c_type_to_c3(tmem, "char[0]", "", is_field: true);
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
	assert(code.contains("struct NeSessionS { void* _unused; }"));
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
			{
				"kind": "TypedefDecl",
				"name": "mfxSyncPoint",
				"loc": { "file": "test_flags.h" },
				"type": { "qualType": "struct mfxSyncPoint *" }
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
	assert(code.contains("FLAG_HIGH = 2147483648u"));

	// Self-referential pointer typedef converted to void*
	assert(code.contains("alias MfxSyncPoint = void*;"));
	assert(!code.contains("alias MfxSyncPoint = MfxSyncPoint*;"));
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
			{
				"kind": "TypedefDecl",
				"name": "HSTRING",
				"loc": { "file": "test_handle.h" },
				"type": { "qualType": "HSTRING *" }
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

	assert(code.contains("alias Hstring = void*;"));
	assert(!code.contains("alias Hstring = Hstring*;"));
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

	assert(code.contains("struct ScalarGroup { void* _unused; }"));
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

	assert(code.contains("struct VSCMsgReaderAdd { void* _unused; }"));
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

	assert(code.contains("IMAGING_MODE_LA,"));
	assert(code.contains("IMAGING_MODE_LAB,"));
	assert(code.contains("IMAGING_MODE_LA_2"));
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