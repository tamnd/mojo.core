"""What the process can say about itself. Go's `os`.

The ids first, and there are eight of them because Unix has eight. `getpid` and
`getppid` say which process this is and which one started it, the four user and
group calls come in real and effective pairs, `getgroups` is the supplementary
list, and `getpagesize` is the one that is not an id at all and is here because
Go keeps it here.

None of the ids can fail, so none of them raises. That is worth stating rather
than leaving a reader to notice: a call that cannot fail and raises anyway
makes every caller write a `try` that can never be taken, and a reader who sees
one starts wondering what the failure would mean.

The other four are `hostname`, `executable`, `args` and `exit`, and each of
them is different somewhere. `hostname` asks the platform for a name it was
configured with. `executable` is a different call on each platform and the
answer is not promised to still name a file. `args` is a function here and a
package level variable in Go. `exit` ends the process without running a single
destructor, which is the one thing in this file worth reading twice.
"""

from std.sys import CompilationTarget
from std.sys import argv as _argv

from core.syscall import exit as _sys_exit
from core.syscall import getcwd as _sys_getcwd
from core.syscall import getegid as _sys_getegid
from core.syscall import geteuid as _sys_geteuid
from core.syscall import getgid as _sys_getgid
from core.syscall import getgroups as _sys_getgroups
from core.syscall import gethostname as _sys_gethostname
from core.syscall import getpagesize as _sys_getpagesize
from core.syscall import getpid as _sys_getpid
from core.syscall import getppid as _sys_getppid
from core.syscall import getuid as _sys_getuid
from core.syscall import pipe as _sys_pipe
from core.syscall import readlink as _sys_readlink
from core.syscall.calls import _ns_get_executable_path

from .errors import _wrapped
from .file import File
from .path import is_path_separator


def getpid() -> Int:
    """This process. Go's `Getpid`.

    ```mojo
    from core.os import getpid

    def main():
        print(getpid() > 0)  # => True
    ```

    Reasonable in a name that has to be unique on one machine for as long as
    this program runs, which is what the scratch directories in this library's
    own tests use it for. Not reasonable as a name that outlives the process,
    since the number is handed to somebody else afterwards.
    """
    return _sys_getpid()


def getppid() -> Int:
    """The process that started this one. Go's `Getppid`.

    The answer changes underneath a program. When the parent exits first the
    child is handed to init and this starts saying 1, so it is a fact about now
    rather than about how the program was started, and anything that wants to
    know who started it has to ask before the parent can go away.
    """
    return _sys_getppid()


def getuid() -> Int:
    """The real user id, which is who started the program. Go's `Getuid`."""
    return _sys_getuid()


def geteuid() -> Int:
    """The effective user id, whose permissions apply. Go's `Geteuid`.

    The two differ on a set-user-id program, where the real id is the person
    who ran it and the effective id is the owner of the file. Neither is a way
    to work out whether a file can be opened: the only honest answer to that
    question is to open it and read the failure, because the permission bits
    are not the whole rule and the file can change between the question and the
    answer.
    """
    return _sys_geteuid()


def getgid() -> Int:
    """The real group id. Go's `Getgid`. See `getuid`."""
    return _sys_getgid()


def getegid() -> Int:
    """The effective group id. Go's `Getegid`. See `geteuid`."""
    return _sys_getegid()


def getgroups() raises -> List[Int]:
    """Every group this process belongs to. Go's `Getgroups`.

    Whether the effective group id is in the list is the platform's own
    business and is not the same answer on both of them, so a caller that cares
    about it asks `getegid` rather than searching this.
    """
    try:
        return _sys_getgroups()
    except e:
        raise _wrapped("getgroups", e)


def getpagesize() -> Int:
    """How many bytes the kernel maps at a time. Go's `Getpagesize`.

    4,096 on Linux x86-64 and 16,384 on Apple silicon, which is why it is a
    call and not a constant: the same binary runs on machines that disagree.
    """
    return _sys_getpagesize()


def hostname() raises -> String:
    """The name this machine calls itself. Go's `Hostname`.

    A name an administrator set, not one the network agrees on. It is not a way
    to find an address, it is not promised to be unique anywhere, and on a
    laptop moving between networks it can change while the program runs.
    """
    try:
        return _sys_gethostname()
    except e:
        raise _wrapped("gethostname", e)


def args() -> List[String]:
    """The command line, program name first. Go's `Args`.

    ```mojo
    from core.os import args

    def main():
        print(len(args()) > 0)  # => True
    ```

    Go's is a package level variable and this is a function, the same choice
    `stdin` and the other two descriptors made, because this library keeps no
    package level state. The practical difference is that Go's can be assigned
    to, which some programs do to hide a flag from a library they call, and
    this cannot: a caller that wants a modified list makes one.

    The first entry is whatever started this program and is not promised to be
    a path. It is `argv[0]`, which a parent using `execve` can set to anything
    at all, and `executable` is the call for the question it looks like it
    answers.
    """
    var out = List[String]()
    for entry in _argv():
        out.append(String(entry))
    return out^


def executable() raises -> String:
    """The path of the running program. Go's `Executable`.

    ```mojo
    from core.os import executable

    def main():
        print(executable().startswith("/"))  # => True
    ```

    A different question on each platform and not a single call on either. Linux
    reads the link at `/proc/self/exe`, so a container with no `/proc` mounted
    fails here. macOS asks `_NSGetExecutablePath`, which answers with whatever
    the loader was handed, and that can be relative, in which case it is joined
    to the working directory, exactly as Go does it.

    The path is absolute and it is not promised to still name the running
    program. A file can be renamed, replaced or removed while it runs, and on
    Linux the link then reads with ` (deleted)` on the end of it, which is the
    platform being honest rather than this library being careless. Go makes the
    same non promise about the same call. There is no symbolic link resolution
    either, so a program started through a link in `/usr/local/bin` names the
    link on macOS and names the target on Linux, which is a difference in the
    two platforms and not one worth papering over with an extra call.
    """
    comptime if CompilationTarget.is_macos():
        var named = _ns_get_executable_path()
        if named.byte_length() > 0 and is_path_separator(named.as_bytes()[0]):
            return named
        try:
            return String(_sys_getcwd(), "/", named)
        except e:
            raise _wrapped("getwd", e)
    try:
        return _sys_readlink("/proc/self/exe")
    except e:
        raise _wrapped("readlink", e)


def pipe() raises -> Tuple[File, File]:
    """A pipe, as two files. The read end first. Go's `Pipe`.

    Each end owns its descriptor and closes it when the value is destroyed, so
    the pair cleans itself up. The thing that catches everybody is that a
    reader sees the end of the pipe only when every copy of the write end has
    been closed, including the one the writer forgot it still held, so a
    program that reads until the end and never closes its own write end waits
    forever.

    Neither end is opened for appending, so neither refuses `write_at`, though
    seeking on either of them fails at the platform, which is what a pipe is.

    The two ends come back in a tuple and have to be used where they sit, as
    `ends[0]` and `ends[1]`, because Mojo cannot move a value out of a tuple
    and a `File` cannot be copied. Reading, writing and closing all work
    through the tuple, and so does handing an end to anything that takes a
    `Reader` or a `Writer`. What does not work yet is giving one end away to
    something that wants to own it, and that is the language rather than this
    call: the day a value can be moved out of a tuple, this signature is
    already the right one.
    """
    var ends: Tuple[Int, Int]
    try:
        ends = _sys_pipe()
    except e:
        raise _wrapped("pipe", e)
    var reader = File(ends[0], String("|0"), False, True)
    var writer = File(ends[1], String("|1"), False, True)
    return (reader^, writer^)


def exit(code: Int):
    """End the process now, with this status. Go's `Exit`. Does not return.

    Nothing is cleaned up. No destructor runs, so a `File` holding a buffer
    that has not reached the disk loses it, and no `atexit` handler registered
    by a C library in the same process runs either. Go says the same about its
    own `Exit` and deferred functions, and the reason is the same: a program
    ending itself deliberately should not be running teardown that some other
    piece of code arranged for a different reason.

    A program that has written something closes it and returns from `main`. A
    status other than zero is the only good reason to reach for this, and even
    then the writes come first.
    """
    _sys_exit(code)
