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

/* A thread kept for more than one job. Its Lua state is made once and the runner loops over the
 * jobs handed to it, so the modules a job requires and the JIT traces it compiles stay warm. The
 * jobs themselves are still one allocation each: a program can join what it submitted without
 * waiting for the worker to finish whatever it starts next.
 *
 * `input` is the runner's own payload -- what it needs to set its state up -- and belongs to the
 * worker from here on: the runner frees it once it has read it. */
typedef struct threading_worker {
	const threading_api* api;
	char* runner;
	size_t runner_len;
	char* input;
	size_t input_len;
	threading_job* job; /* The job the worker is running, or one waiting for it */
	int stopping;
	int started;
	char* error; /* What went wrong outside a job: no state, a runner that did not load */
#ifdef _WIN32
	HANDLE thread;
	CRITICAL_SECTION lock;
	CONDITION_VARIABLE wake;
	CONDITION_VARIABLE finished;
#else
	pthread_t thread;
	pthread_mutex_t lock;
	pthread_cond_t wake;
	pthread_cond_t finished;
#endif
} threading_worker;

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

static char* copy_bytes(const char* bytes, size_t len)
{
	char* out = (char*)malloc(len);
	if (out == NULL) return NULL;
	for (size_t i = 0; i < len; i++) out[i] = bytes[i];
	return out;
}

/* ── workers ───────────────────────────────────────────────────────────────────────────────── */

#ifdef _WIN32
#define WORKER_LOCK(worker) EnterCriticalSection(&(worker)->lock)
#define WORKER_UNLOCK(worker) LeaveCriticalSection(&(worker)->lock)
#define WORKER_WAKE(worker) WakeAllConditionVariable(&(worker)->wake)
#define WORKER_WAKE_FINISHED(worker) WakeAllConditionVariable(&(worker)->finished)
#define WORKER_WAIT(worker, cond) SleepConditionVariableCS(&(worker)->cond, &(worker)->lock, INFINITE)
#else
#define WORKER_LOCK(worker) pthread_mutex_lock(&(worker)->lock)
#define WORKER_UNLOCK(worker) pthread_mutex_unlock(&(worker)->lock)
#define WORKER_WAKE(worker) pthread_cond_broadcast(&(worker)->wake)
#define WORKER_WAKE_FINISHED(worker) pthread_cond_broadcast(&(worker)->finished)
#define WORKER_WAIT(worker, cond) pthread_cond_wait(&(worker)->cond, &(worker)->lock)
#endif

static void run_worker(threading_worker* worker)
{
	const threading_api* api = worker->api;
	lua_State* L = api->newstate();
	if (L == NULL) {
		worker->error = copy_text("could not create a Lua state", 28);
		return;
	}

	api->openlibs(L);
	if (api->preload != NULL) api->preload(L);

	int failed = api->loadbufferx(L, worker->runner, worker->runner_len, "=threading.worker", NULL) != 0;
	if (!failed) {
		api->pushlightuserdata(L, worker);
		failed = api->pcall(L, 1, 0, 0) != 0;
	}
	if (failed) {
		size_t len = 0;
		const char* message = api->tolstring(L, -1, &len);
		worker->error = message != NULL ? copy_text(message, len) : copy_text("unknown error", 13);
	}

	api->close(L);
}

#ifdef _WIN32
static DWORD WINAPI worker_entry(LPVOID arg)
{
	run_worker((threading_worker*)arg);
	return 0;
}
#else
static void* worker_entry(void* arg)
{
	run_worker((threading_worker*)arg);
	return NULL;
}
#endif

/* A worker with its runner and startup payload copied in. The runner owns the payload once it has
 * started and frees it; a worker that never starts frees it here. */
THREADING_EXPORT threading_worker* threading_worker_new(
	const threading_api* api,
	const char* runner,
	size_t runner_len,
	const char* input,
	size_t input_len
)
{
	threading_worker* worker = (threading_worker*)calloc(1, sizeof(threading_worker));
	if (worker == NULL) return NULL;

	worker->api = api;
	worker->runner = copy_bytes(runner, runner_len);
	worker->runner_len = runner_len;
	if (input_len > 0) {
		worker->input = copy_bytes(input, input_len);
		worker->input_len = input_len;
	}
	if (worker->runner == NULL || (input_len > 0 && worker->input == NULL)) {
		free(worker->runner);
		free(worker->input);
		free(worker);
		return NULL;
	}

#ifdef _WIN32
	InitializeCriticalSection(&worker->lock);
	InitializeConditionVariable(&worker->wake);
	InitializeConditionVariable(&worker->finished);
#else
	pthread_mutex_init(&worker->lock, NULL);
	pthread_cond_init(&worker->wake, NULL);
	pthread_cond_init(&worker->finished, NULL);
#endif
	return worker;
}

/* Starts the worker's thread. Nonzero is the platform's error. */
THREADING_EXPORT int threading_worker_start(threading_worker* worker)
{
#ifdef _WIN32
	worker->thread = CreateThread(NULL, 0, worker_entry, worker, 0, NULL);
	if (worker->thread == NULL) return (int)GetLastError();
#else
	int failed = pthread_create(&worker->thread, NULL, worker_entry, worker);
	if (failed != 0) return failed;
#endif
	worker->started = 1;
	return 0;
}

/* Hands one job to a worker. A worker runs one job at a time, so one already busy, or stopping,
 * refuses it rather than queueing it: a program with a pool asks for a free worker first. */
THREADING_EXPORT int threading_worker_push(threading_worker* worker, threading_job* job)
{
	WORKER_LOCK(worker);
	int refused = worker->job != NULL || worker->stopping;
	if (!refused) {
		job->done = 0;
		worker->job = job;
		WORKER_WAKE(worker);
	}
	WORKER_UNLOCK(worker);
	return refused;
}

/* What the worker runs: waits for a job, or answers NULL once it has been asked to stop. */
THREADING_EXPORT threading_job* threading_worker_wait(threading_worker* worker)
{
	WORKER_LOCK(worker);
	while (worker->job == NULL && !worker->stopping) WORKER_WAIT(worker, wake);
	threading_job* job = worker->job;
	worker->job = NULL;
	WORKER_UNLOCK(worker);
	return job;
}

/* Says a job is finished, so a program polling it can join it and the pool can hand the worker
 * another. */
THREADING_EXPORT void threading_worker_finish(threading_worker* worker, threading_job* job)
{
	WORKER_LOCK(worker);
	set_done(job);
	WORKER_WAKE_FINISHED(worker);
	WORKER_UNLOCK(worker);
}

/* Waits for one job of a worker, without stopping the worker. A join that comes after a poll
 * finds it already done and returns at once. */
THREADING_EXPORT void threading_job_wait(threading_worker* worker, threading_job* job)
{
	WORKER_LOCK(worker);
	while (!job->done) WORKER_WAIT(worker, finished);
	WORKER_UNLOCK(worker);
}

/* Frees the startup payload once the runner has decoded it. */
THREADING_EXPORT void threading_worker_free_input(threading_worker* worker)
{
	free(worker->input);
	worker->input = NULL;
	worker->input_len = 0;
}

/* Asks the worker to stop after the job it is running, and waits for its thread. */
THREADING_EXPORT void threading_worker_stop(threading_worker* worker)
{
	if (!worker->started) return;

	WORKER_LOCK(worker);
	worker->stopping = 1;
	WORKER_WAKE(worker);
	WORKER_UNLOCK(worker);

#ifdef _WIN32
	WaitForSingleObject(worker->thread, INFINITE);
	CloseHandle(worker->thread);
#else
	pthread_join(worker->thread, NULL);
#endif
	worker->started = 0;
}

/* A stopped worker's memory: its runner, its payload if the runner never took it, and its sync. */
THREADING_EXPORT void threading_worker_free(threading_worker* worker)
{
#ifdef _WIN32
	DeleteCriticalSection(&worker->lock);
#else
	pthread_mutex_destroy(&worker->lock);
	pthread_cond_destroy(&worker->wake);
	pthread_cond_destroy(&worker->finished);
#endif
	free(worker->runner);
	free(worker->input);
	free(worker->error);
	free(worker);
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
