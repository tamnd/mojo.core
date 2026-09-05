/* The environment, which is a variable rather than a call.
 *
 * `environ` is a `char **` that libc exports as data. Mojo can call a C
 * function and cannot name a C variable, so the array is reachable only
 * through something that returns it, and this is that something.
 *
 * macOS does not export `environ` to anything but the main executable, which
 * is why `crt_externs.h` exists and why the two halves below are different.
 * `_NSGetEnviron` is already a function and could be called from Mojo on its
 * own, but then Linux would still need this file and there would be a platform
 * test in `calls.mojo` for a difference that is entirely about C.
 *
 * Nothing is copied here. The caller gets the live array and has to read it
 * before anything else in the process changes the environment, which is the
 * same rule `getenv` comes with.
 */

#if defined(__APPLE__)
#include <crt_externs.h>
#else
extern char **environ;
#endif

char **core_syscall_environ(void) {
#if defined(__APPLE__)
    return *_NSGetEnviron();
#else
    return environ;
#endif
}
