/*
 * The variadic calls, given real prototypes. The second C file in this
 * library, and unrelated to the first.
 *
 * `external_call` emits a call of fixed arity. C decides how to pass an
 * argument from the prototype, and a variadic prototype does not pass its
 * anonymous arguments the way a fixed one does, so naming them individually
 * uses the wrong convention for every argument past the last named parameter.
 * On x86-64 and on standard AArch64 the two conventions agree for integers and
 * nothing goes wrong. Apple's AArch64 variant puts an anonymous argument on the
 * stack, so `open(path, O_CREAT | O_WRONLY, 0644)` written the obvious way
 * creates a file with mode zero there and mode 0644 on both Linux machines,
 * and nothing anywhere reports a problem.
 *
 * docs/design.md section 11 has the reasoning and
 * tools/probe/probes/variadic_call.mojo pins the fact. The day that probe says
 * the anonymous arguments arrive on macOS, this file can go and the two calls
 * below become ordinary `external_call`s.
 *
 * Each function here does one thing: name the arguments in a fixed prototype
 * and pass them on. No flag is checked, no errno is touched, no default is
 * supplied. Everything that could be a decision is in Mojo, in
 * core/syscall/calls.mojo, for the same reason it is in the other shim: a
 * decision that changes should not live in the file that has to be recompiled
 * for each platform and cannot be reached by the test suite.
 */

#include <fcntl.h>

/*
 * `mode` is `unsigned int` rather than `mode_t` so that the Mojo side has one
 * width to pass on every platform. `mode_t` is two bytes on macOS and four on
 * Linux, and a parameter whose size depends on the host is exactly the kind of
 * thing core.syscall exists to keep out of hand written code. The conversion
 * to the real type happens here, where the header is in scope.
 */
int core_syscall_open3(const char *path, int flags, unsigned int mode) {
    return open(path, flags, (mode_t)mode);
}

/*
 * One function for the whole of fcntl, including the commands that take no
 * argument. `fcntl(fd, F_GETFD, 0)` is what C code writes for those anyway:
 * the extra argument is read by nothing and the kernel never sees it.
 *
 * The argument is an `int` because every command core.syscall binds takes one.
 * File locking takes a `struct flock *` and would need a second entry point
 * with a pointer parameter, which is a line to add on the day something wants
 * it rather than now.
 */
int core_syscall_fcntl(int fd, int cmd, int arg) { return fcntl(fd, cmd, arg); }
