/*
 * Two pointers, per thread. One of the two C files in this library, and the
 * reason it is here is worth reading before touching it. The other is
 * core/syscall/shim/varargs.c, which is here for an unrelated reason and is
 * not somewhere to put anything that belongs in this one.
 *
 * Mojo has no global mutable state. A module level `var` is refused outright,
 * with the compiler telling you to move it into a function body or make it a
 * `comptime` constant, and `tools/probe/probes/no_globals.mojo` pins that.
 * Two places in this library need somewhere to put a value that is per thread
 * and outlives the call that wrote it, and there is nowhere in the language to
 * put one. So they live here.
 *
 * The first is the error mechanism in docs/design.md section 4, which needs a
 * record holding what Go would have kept in a struct. The second is the
 * generator behind the top level functions of core.math.rand, which Go keeps
 * per operating system thread for the same reason: those functions are safe to
 * call from anywhere and a shared generator would need a lock.
 *
 * This is deliberately the smallest thing that solves that. A slot holds a
 * pointer and nothing else. It does not know what is in it, when the contents
 * are valid, or how to read a field. All of that is Mojo, in record.mojo and
 * in globals.mojo, where it can be read and changed by somebody who does not
 * write C.
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

/*
 * One slot. Two of these exist and no more are expected; a third would be a
 * conversation about whether the thing wanting it really has no owner to live
 * in, which is the conversation the first two already had.
 */
struct slot {
    pthread_key_t key;
    pthread_once_t once;

    /*
     * Whether the key exists. pthread_key_create fails only when the process
     * has exhausted its keys, and we take two, once each, so in practice this
     * is always true. If it is ever false the slot degrades to holding
     * nothing, and both callers already have an answer for that: the error
     * mechanism reports no record, which it treats as "this error is not one
     * of ours", and the generator makes a new one per call, which costs time
     * and is still random. Less information, never wrong information.
     */
    int ready;

    /*
     * How to free the contents. Written in Mojo, passed in on every set, and
     * the same value every time, since a slot holds one type. Atomic because
     * "the same value every time" is a fact about the caller rather than
     * something the compiler knows, and two threads writing at once would
     * otherwise be a data race on a plain pointer.
     *
     * Passed in rather than declared `extern` and defined in Mojo with
     * @export. That version links on Linux and not on macOS, where an
     * undefined weak symbol needs different spelling, and it leaves the Mojo
     * side with a function that nothing calls, which is exactly what a dead
     * code pass removes.
     */
    _Atomic(disposer) release;
};

/*
 * The body of a pthread key destructor, so a thread that exits still holding
 * something frees it rather than leaking it. The main thread is the exception
 * and that is pthread's rule rather than ours: key destructors do not run for
 * the thread that calls exit, so one value per slot outlives the process by a
 * few microseconds.
 *
 * pthread passes the value and nothing else, so which slot it came from cannot
 * be an argument and each slot needs a destructor of its own. That is the two
 * one line functions below.
 */
static void dispose(struct slot *s, void *held) {
    disposer found = atomic_load_explicit(&s->release, memory_order_acquire);
    if (found) {
        found(held);
    }
}

static void *slot_get(struct slot *s, void (*setup)(void)) {
    pthread_once(&s->once, setup);
    return s->ready ? pthread_getspecific(s->key) : 0;
}

static void slot_set(struct slot *s, void (*setup)(void), void *held,
                     disposer free_held) {
    atomic_store_explicit(&s->release, free_held, memory_order_release);
    pthread_once(&s->once, setup);
    if (s->ready) {
        pthread_setspecific(s->key, held);
    }
}

/* The error record, for core.errors. */

static struct slot errors = {.once = PTHREAD_ONCE_INIT};

static void errors_dispose(void *held) { dispose(&errors, held); }

static void errors_setup(void) {
    errors.ready = pthread_key_create(&errors.key, errors_dispose) == 0;
}

void *core_errors_slot_get(void) { return slot_get(&errors, errors_setup); }

void core_errors_slot_set(void *record, disposer free_record) {
    slot_set(&errors, errors_setup, record, free_record);
}

/* The default generator, for core.math.rand. */

static struct slot rand_source = {.once = PTHREAD_ONCE_INIT};

static void rand_dispose(void *held) { dispose(&rand_source, held); }

static void rand_setup(void) {
    rand_source.ready = pthread_key_create(&rand_source.key, rand_dispose) == 0;
}

void *core_rand_slot_get(void) { return slot_get(&rand_source, rand_setup); }

void core_rand_slot_set(void *state, disposer free_state) {
    slot_set(&rand_source, rand_setup, state, free_state);
}
