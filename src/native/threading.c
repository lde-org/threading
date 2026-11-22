/* The part of threading that has to be C: a thread's entry point. A thread starts in a function
 * of the platform's own calling convention, and a LuaJIT callback cannot be one -- it runs in the
 * Lua state that made it, which is the state the new thread exists to stay out of. So a thread
 * starts here, makes a Lua state of its own, and runs the job in it.
 *
 * Nothing is linked against Lua: the program hands over the Lua C API it runs on, as function
 * pointers, so this works whatever executable or library the Lua runtime lives in. */
#include <stddef.h>
#include <stdlib.h>

#ifdef _WIN32
#include <windows.h>
#define THREADING_EXPORT __declspec(dllexport)
#else
#include <pthread.h>
#include <time.h>
#include <errno.h>
#define THREADING_EXPORT __attribute__((visibility("default")))
#endif

typedef struct lua_State lua_State;

/* The Lua C API a thread needs, from the runtime the program runs on. `preload` is the host's
 * lde_preload, where it has one: what puts a compiled program's modules into a new state.
 * `alloc` and `free` are this library's allocator, which a thread's runner uses for what it hands
 * back and frees what it was handed with. */
typedef struct threading_api {
	lua_State* (*newstate)(void);
	void (*openlibs)(lua_State*);
	int (*loadbufferx)(lua_State*, const char*, size_t, const char*, const char*);
	void (*pushlightuserdata)(lua_State*, void*);
	int (*pcall)(lua_State*, int, int, int);
	const char* (*tolstring)(lua_State*, int, size_t*);
	void (*close)(lua_State*);
	void (*preload)(lua_State*);
	void* (*alloc)(size_t);
	void (*free)(void*);
} threading_api;

/* One thread: what it runs, what it answered, and whether it has finished. The runner is a
 * chunk of Lua that takes the job and does the rest -- decodes the payload, runs it, writes the
 * result -- so the C side knows nothing about what a job is. */
typedef struct threading_job {
	const threading_api* api;
	const char* runner;
	size_t runner_len;
	char* payload;
	size_t payload_len;
	char* result;
	size_t result_len;
	char* error; /* What went wrong outside the job itself: no state, a runner that did not load */
	int done;
#ifdef _WIN32
	HANDLE thread;
#else
	pthread_t thread;
#endif
} threading_job;

static char* copy_text(const char* text, size_t len)
{
	char* out = (char*)malloc(len + 1);
	if (out == NULL) return NULL;
	for (size_t i = 0; i < len; i++) out[i] = text[i];
	out[len] = '\0';
	return out;
}

static void set_done(threading_job* job)
{
#ifdef _WIN32
	InterlockedExchange((volatile LONG*)&job->done, 1);
#else
	__atomic_store_n(&job->done, 1, __ATOMIC_RELEASE);
#endif
}

static void run(threading_job* job)
{
	const threading_api* api = job->api;
	lua_State* L = api->newstate();
	if (L == NULL) {
		job->error = copy_text("could not create a Lua state", 28);
		return;
	}

	api->openlibs(L);
	if (api->preload != NULL) api->preload(L);

	int failed = api->loadbufferx(L, job->runner, job->runner_len, "=threading", NULL) != 0;
	if (!failed) {
		api->pushlightuserdata(L, job);
		failed = api->pcall(L, 1, 0, 0) != 0;
	}
	if (failed) {
		size_t len = 0;
		const char* message = api->tolstring(L, -1, &len);
		job->error = message != NULL ? copy_text(message, len) : copy_text("unknown error", 13);
	}

	api->close(L);
}

#ifdef _WIN32
static DWORD WINAPI entry(LPVOID arg)
{
	run((threading_job*)arg);
	set_done((threading_job*)arg);
	return 0;
}
#else
static void* entry(void* arg)
{
	run((threading_job*)arg);
	set_done((threading_job*)arg);
	return NULL;
}
#endif

/* Starts the job's thread. Nonzero is the platform's error. */
THREADING_EXPORT int threading_start(threading_job* job)
{
	job->done = 0;
#ifdef _WIN32
	job->thread = CreateThread(NULL, 0, entry, job, 0, NULL);
	return job->thread == NULL ? (int)GetLastError() : 0;
#else
	return pthread_create(&job->thread, NULL, entry, job);
#endif
}

/* Whether the job's thread has finished: what a program that cannot wait asks. */
THREADING_EXPORT int threading_done(threading_job* job)
{
#ifdef _WIN32
	return InterlockedCompareExchange((volatile LONG*)&job->done, 0, 0) != 0;
#else
	return __atomic_load_n(&job->done, __ATOMIC_ACQUIRE) != 0;
#endif
}

/* Waits for the job's thread and lets go of it. Called once per started job. */
THREADING_EXPORT void threading_join(threading_job* job)
{
#ifdef _WIN32
	WaitForSingleObject(job->thread, INFINITE);
	CloseHandle(job->thread);
#else
	pthread_join(job->thread, NULL);
#endif
}

/* Memory the threads hand back, freed by the allocator that made it. */
THREADING_EXPORT void* threading_alloc(size_t size)
{
	return malloc(size);
}

THREADING_EXPORT void threading_free(void* pointer)
{
	free(pointer);
}

THREADING_EXPORT void threading_sleep(unsigned int milliseconds)
{
#ifdef _WIN32
	Sleep(milliseconds);
#else
	struct timespec wait = { (time_t)(milliseconds / 1000), (long)(milliseconds % 1000) * 1000000L };
	while (nanosleep(&wait, &wait) != 0 && errno == EINTR) {}
#endif
}
