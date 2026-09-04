"""The one call to the builtin `print` in this package.

This package exports a `print` of its own, because Go's `fmt.Print` is called
`Print` and calling it anything else would be a rename a reader has to learn
for no reason. The cost is that any file which imports that name can no longer
reach the builtin under its own name, and every entry point here that writes to
standard output needs the builtin.

So the builtin is called here, in a file that imports nothing from this package
and so still has it, and everything else goes through `to_stdout`.
"""


def to_stdout(s: String):
    """`s` on standard output, with nothing added to it.

    No newline, because the caller has already put in whatever Go puts in.
    `println` adds its own and `printf` adds none.
    """
    print(s, end="")
