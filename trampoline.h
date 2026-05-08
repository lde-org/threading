typedef struct lua_State lua_State;

/* Function pointer types matching the Lua C API signatures used. */
typedef lua_State* (*fn_newstate_t)(void);
typedef void       (*fn_openlibs_t)(lua_State*);
typedef int        (*fn_loadbufferx_t)(lua_State*, const char*, size_t, const char*, const char*);
typedef void       (*fn_pushlud_t)(lua_State*, void*);
typedef int        (*fn_pcall_t)(lua_State*, int, int, int);
typedef void       (*fn_close_t)(lua_State*);

/* Shared between trampoline code and LuaJIT ffi.cdef usage */
typedef struct {
	char*  bc;
	size_t bc_len;
	char*  wrapper_bc;
	size_t wrapper_len;
	char*  result;
	size_t result_len;
	fn_newstate_t   fn_newstate;
	fn_openlibs_t   fn_openlibs;
	fn_loadbufferx_t fn_loadbufferx;
	fn_pushlud_t    fn_pushlud;
	fn_pcall_t      fn_pcall;
	fn_close_t      fn_close;
	char   name[8];
	size_t nups;
	char*  ups;
	size_t ups_len;
} thread_data_t;
