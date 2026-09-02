/*
 * One pointer, per thread. The only C in this library, and the reason it is
 * here is worth reading before touching it.
 *
 * Mojo has no global mutable state. A module level `var` is refused outright,
 * with the compiler telling you to move it into a function body or make it a
 * `comptime` constant, and `tools/probe/probes/no_globals.mojo` pins that. The
 * error mechanism in docs/design.md section 4 needs somewhere to put a record
 * that is per thread and outlives the call that wrote it, and there is nowhere
 * in the language to put one. So it lives here.
 *
 * This is deliberately the smallest thing that solves that. It holds a pointer
 * and nothing else. It does not know what a record is, when one is valid, or
 * how to read a field. All of that is Mojo, in record.mojo, where it can be
 * read and changed by somebody who does not write C.
 *
 * The cost is real and is stated in design.md rather than left to be found in
 * a link line: every binary that uses core.errors links a platform specific
 * object file, and core.errors is tier zero, so that is every binary built on
 * this library. The alternative was threading an explicit error context
 * through every fallible call in the library, which puts the mechanism in the
 * signature of every function in it.
 */

#include <pthread.h>
#include <stdatomic.h>

typedef void (*disposer)(void *);

static pthread_key_t key;
static pthread_once_t once = PTHREAD_ONCE_INIT;

/*
 * Whether the key exists. pthread_key_create fails only when the process has
 * exhausted its keys, and we take one, once, so in practice this is always
 * true. If it is ever false the mechanism degrades to reporting no record at
 * all, which the Mojo side already treats as "this error is not one of ours".
 * Errors still carry their message and still match. That is the right way for
 * this to fail: less information, never wrong information.
 */
static int ready;

/*
 * How to free a record. Written in Mojo, passed in on every set, and the same
 * value every time, since there is one record type. Atomic because "the same
 * value every time" is a fact about the caller rather than something the
 * compiler knows, and two threads raising at once would otherwise be a data
 * race on a plain pointer.
 *
 * Passed in rather than declared `extern` and defined in Mojo with @export.
 * That version links on Linux and not on macOS, where an undefined weak symbol
 * needs different spelling, and it leaves the Mojo side with a function that
 * nothing calls, which is exactly what a dead code pass removes.
 */
static _Atomic(disposer) release;

/*
 * The pthread key's destructor, so a thread that exits still holding a record
 * frees it rather than leaking it. The main thread is the exception and that is
 * pthread's rule rather than ours: key destructors do not run for the thread
 * that calls exit, so one record outlives the process by a few microseconds.
 */
static void dispose(void *record) {
    disposer found = atomic_load_explicit(&release, memory_order_acquire);
    if (found) {
        found(record);
    }
}

static void setup(void) {
    ready = pthread_key_create(&key, dispose) == 0;
}

void *core_errors_slot_get(void) {
    pthread_once(&once, setup);
    return ready ? pthread_getspecific(key) : 0;
}

void core_errors_slot_set(void *record, disposer free_record) {
    atomic_store_explicit(&release, free_record, memory_order_release);
    pthread_once(&once, setup);
    if (ready) {
        pthread_setspecific(key, record);
    }
}
