"""The file system as a value, and the names that go into one. Go's `io/fs`.

```mojo
from core.io.fs import valid_path

print(valid_path("a/b/c"))  # => True
print(valid_path("/a"))  # => False
```

Go's `fs.FS` is the interface a tree of files is reached through, so that a
zip archive, a directory and a map in a test all answer the same questions.
That is the bulk of this package and it is not written yet. What is here is the
rule about names, which is lexical, needs nothing from the trait, and is what
`core.path.filepath.localize` is defined in terms of.

## The name rule

A path in this package is always slash separated, always relative, and always
already clean, whatever the host underneath spells its own paths like. That is
not a convention, it is the contract: an `fs.FS` is handed names in this one
form so that an implementation over a zip file and an implementation over a
directory cannot disagree about what `a/../b` means, and so that a name from
outside cannot walk out of the tree by being spelled a different way. Go says
the same and `valid_path` is where it says it.
"""

from .name import valid_path
