# Platform baselines

One file per platform, holding what that platform's own C headers say about the structures, flags and numbers this library binds. `pixi run baseline` compiles a small C program, asks it for `sizeof` and `offsetof` and the value of every constant, and compares the answers to the file for the platform it is running on. CI runs it on macOS arm64, Linux x86-64 and Linux arm64.

These are here because they cannot be checked from Mojo. Checking them means asking the host what the right answer is, and a wrong offset does not fail, it reads a plausible wrong number out of the middle of a structure. Everything that can be checked from Mojo is an ordinary test instead, so that it runs everywhere on every run rather than only where a C compiler happens to exist.

The numbers are not a formality. `pthread_mutex_t` is 40 bytes on Linux x86-64, 48 on Linux arm64 and 64 on macOS. `sin_family` is at offset 0 on Linux and at offset 1 on macOS, because macOS puts a length byte first. `O_CREAT` is 64 on Linux and 512 on macOS. `struct stat` has a different field order on the two Linux architectures, not just a different size. Every one of those is a bug that compiles cleanly and returns something believable.

## Recording

`pixi run baseline --record` writes the file for the platform it is run on. It is a deliberate act on a machine somebody trusts, and the diff is the review, the same as every other generated thing here.

Recording is not the way to make a red check go green. If these numbers move, either the platform genuinely changed, which is worth a conversation, or the recording was done somewhere it should not have been.

A platform in the supported list with no file here is a failure rather than a skip. Otherwise the check passes by having nothing to compare, on exactly the platforms where the numbers matter.
