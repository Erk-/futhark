// start of multicore_defs.h

#ifndef MULTICORE_DEFS
#define MULTICORE_DEFS


#include <pthread.h>
#include <stdlib.h>
#include <assert.h>

#define MULTICORE
/* #define MCDEBUG */
/* #define MCPROFILE */

#ifdef _WIN32
#include <windows.h>
#elif __APPLE__
#include <sys/sysctl.h>
// For getting cpu usage of threads
#include <mach/mach.h>
#include <sys/resource.h>
#else // Linux
#include <sys/sysinfo.h>
#include <sys/resource.h>
#include <signal.h>
#endif

#ifdef MCDEBUG
static long int ran_iter, start_iter = 0;
#endif

static volatile int scheduler_error = 0;

/* static double kappa = 4.2f; */
static double kappa = 0.35f; // 4.2f / 12.0;

typedef int (*sub_task_fn)(void* args, int start, int end, int subtask_id, int tid);

enum scheduling {
  DYNAMIC,
  STATIC
};

/* A subtask that can be executed by a thread */
struct subtask {
  sub_task_fn fn;
  void* args;
  int start, end;
  const char *name;
  // How much of a task to take a the time
  // If it's zero , then the subtasks is not stealable
  int chunkable;
  long int iterations;
  int stolen_from;
  int id;

  // Shared variables across subtasks
  volatile int *counter; // Counter for ongoing subtasks
  int64_t *total_time;
  int64_t *total_iter;
};


struct scheduler {
  struct worker *workers;
  int num_threads;
};

struct scheduler_info {
  int iter_pr_subtask;
  int remainder;
  int nsubtasks;
  enum scheduling sched;

  int64_t *total_time;
  int64_t *total_iter;
};


/* Parallel task  */
struct scheduler_subtask {
  const char* name;
  sub_task_fn fn;
  void* args;
  long int iterations;
  struct scheduler_info info;
};

struct deque {
  int64_t size;
  struct subtask **buffer;
  int64_t top, bottom;
  int dead;
};

typedef int (*task_fn)(void* args, int iterations, int tid, struct scheduler_info info);



/* A task for the scheduler to execute */
struct scheduler_task {
  void *args;
  task_fn par_fn;
  task_fn seq_fn;
  const char* name;
  long int iterations;
  enum scheduling sched;

  int64_t *total_time;
  int64_t *total_iter;
};

struct worker {
  pthread_t thread;
  struct deque q;
  struct scheduler *scheduler;
  int cur_working;
  int dead;

  int tid;                     /* Just a thread id */
  uint64_t time_spent_working; /* Time spent in tasks functions */
};

/* A wrapper for getting rusage on Linux and MacOS */
/* TODO maybe figure out this for windows */
static inline int getrusage_thread(struct rusage *rusage)
{
  int err = -1;
#ifdef __APPLE__
    thread_basic_info_data_t info = { 0 };
    mach_msg_type_number_t info_count = THREAD_BASIC_INFO_COUNT;
    kern_return_t kern_err;

    kern_err = thread_info(mach_thread_self(),
                           THREAD_BASIC_INFO,
                           (thread_info_t)&info,
                           &info_count);
    if (kern_err == KERN_SUCCESS) {
        memset(rusage, 0, sizeof(struct rusage));
        rusage->ru_utime.tv_sec = info.user_time.seconds;
        rusage->ru_utime.tv_usec = info.user_time.microseconds;
        rusage->ru_stime.tv_sec = info.system_time.seconds;
        rusage->ru_stime.tv_usec = info.system_time.microseconds;
        err = 0;
    } else {
        errno = EINVAL;
    }
#else // Linux
    err = getrusage(RUSAGE_THREAD, rusage);
#endif
    return err;
}

/* returns the number of logical cores */
static const int num_processors()
{
#ifdef _WIN32
/* https://docs.microsoft.com/en-us/windows/win32/api/sysinfoapi/ns-sysinfoapi-system_info */
    SYSTEM_INFO sysinfo;
    GetSystemInfo(&sysinfo);
    int ncores = sysinfo.dwNumberOfProcessors;
    fprintf(stderr, "Found %d cores on your Windows machine\n Is that correct?\n", ncores);
    return ncores;
#elif __APPLE__
    int ncores;
    size_t ncores_size = sizeof(ncores);
    CHECK_ERRNO(sysctlbyname("hw.logicalcpu", &ncores, &ncores_size, NULL, 0),
                "sysctlbyname (hw.logicalcpu)");
    return ncores;
#else // If Linux
  return get_nprocs();
#endif
}




static inline void output_thread_usage(struct worker *worker)
{
  struct rusage usage;
  CHECK_ERRNO(getrusage_thread(&usage), "getrusage_thread");
  struct timeval user_cpu_time = usage.ru_utime;
  struct timeval sys_cpu_time = usage.ru_stime;
  fprintf(stderr, "tid: %2d - work time %10llu - user time: %10llu us - sys: %10llu us\n",
          worker->tid,
          worker->time_spent_working,
          (uint64_t)(user_cpu_time.tv_sec * 1000000 + user_cpu_time.tv_usec),
          (uint64_t)(sys_cpu_time.tv_sec * 1000000 + sys_cpu_time.tv_usec));

}


static unsigned int g_seed;

// Used to seed the generator.
static inline void fast_srand(int seed) {
    g_seed = seed;
}

// Compute a pseudorandom integer.
// Output value in range [0, 32767]
static inline int fast_rand(void) {
    g_seed = (214013*g_seed+2531011);
    return (g_seed>>16)&0x7FFF;
}

int64_t pick_bits(int lsb, int sz, int64_t value) {
    uint64_t v = value;
    v >>= lsb;
    if (sz < 64) {
        uint64_t mask = 1;
        mask <<= sz;
        mask -= 1;
        v &= mask;
    }
    return v;
}

int64_t put_bits(int lsb, int size, int64_t val) {
  int32_t masked = pick_bits(0, size, val);
  return masked << lsb;
}

int64_t pack_vals (float C, int32_t nmax)
{
  int64_t nmax_64_shifted = (int64_t) nmax << 32;
  return nmax_64_shifted | (int32_t)C;
}

float get_C (int64_t val) {
  return (float)pick_bits(0, 32, val);
}
int32_t get_nmax (int64_t val) {
  return (int32_t)pick_bits(32, 32, val);
}

#endif

// end of multicore_defs.h