"""Paths the way the host operating system spells them. Go's `path/filepath`.

```mojo
from core.path.filepath import join

print(join(["/usr", "bin", "ls"]))  # => /usr/bin/ls
```

`core.path` answers these questions about text with slashes in it. This package
answers them about the names the host underneath actually uses, where the
separator can be a backslash and a name can begin with a drive letter. On the
two platforms this library supports the separator is `/` and the answers agree
almost everywhere, and both packages exist anyway, because a program that says
which of the two it means is a program that still means the right one on a host
where they differ.

## What is here

The lexical half. `clean`, `split`, `join`, `base`, `dir`, `ext`, `is_abs` and
`is_match` are the same questions `core.path` takes, asked about a host path.
`split_list` cuts a `PATH` shaped string. `volume_name` is the leading drive or
share, which here is always empty. `rel` works out the route from one path to
another. `from_slash` and `to_slash` convert between the two spellings, and
`localize` is the strict version of `from_slash` for a name that arrived from
outside the program.

The other half asks a disk. `abs` puts the working directory in front of a
relative path, `eval_symlinks` follows every link in one, `glob` finds the names
that match a pattern, and `walk` and `walk_dir` visit everything under a
directory. `SkipDir` and `SkipAll` are the two answers a walk callback raises to
steer it, `skip_dir` and `skip_all` build those two raises, and `WalkFunc` and
`WalkDirFunc` are what the two walks call.

## Lexical means lexical

Most of this package opens nothing. `clean("a/../b")` is `"b"` whether or not
`a` exists, and if `a` is a symbolic link then `"b"` names a different file than
the input did. `rel` and `is_local` inherit that, so a local path can still lead
out of its tree through a link. `eval_symlinks` is the one that asks, and it is
the one that can fail.

## A walk does not follow links

Neither `walk` nor `walk_dir` goes through a symbolic link. A link is reported
as a link and left there, which is what keeps a tree with a link back to its own
parent from being a walk that never ends. It also means a walk of a directory
somebody else can write to cannot be made to visit a file outside it.

## Names from outside

`join` cleans, which means `join(["/srv", "../etc/passwd"])` is `/etc/passwd`
and not a path under `/srv`. When an element came from an archive entry, a form
field or a request, `localize` is what turns it into a path and refuses the ones
that would escape, and `is_local` is what answers the question about a path that
is already in hand.
"""

from core.errors.codes import ErrBadPattern, SkipAll, SkipDir
from core.io.fs import WalkDirFunc, skip_all, skip_dir

from .disk import abs, eval_symlinks
from .filepath import (
    LIST_SEPARATOR,
    SEPARATOR,
    base,
    clean,
    dir,
    ext,
    from_slash,
    is_abs,
    is_local,
    is_match,
    join,
    localize,
    rel,
    split,
    split_list,
    to_slash,
    volume_name,
)
from .glob import glob
from .walk import WalkFunc, walk, walk_dir
