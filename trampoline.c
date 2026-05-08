#include <stddef.h>
#include <stdint.h>

#include "trampoline.h"

__attribute__((used))
void* thread_entry(thread_data_t* data) {
	if (!data->fn_newstate) return (void*)0;

	lua_State* L = data->fn_newstate();
	if (!L) return (void*)0;

	data->fn_openlibs(L);
	data->fn_loadbufferx(L, data->wrapper_bc, data->wrapper_len, data->name, (void*)0);
	data->fn_pushlud(L, data);
	data->fn_pcall(L, 1, 0, 0);
	data->fn_close(L);

	return (void*)0;
}
