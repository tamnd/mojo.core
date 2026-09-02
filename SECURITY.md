# Security policy

## Reporting

Report privately through [GitHub security advisories](https://github.com/tamnd/mojo.core/security/advisories/new). Do not open a public issue for a security problem.

You should get a first response within three days and an assessment within a week. If a report turns out to be valid you will be credited in the advisory unless you would rather not be.

## What counts

This library parses input that somebody else produced, in a lot of places. Anything in the following list is a security issue and not a bug report, even if it only causes a crash:

A parser that aborts, loops forever, or allocates without bound on malformed input. That covers JSON, XML, ASN.1, CSV, PEM, all five compression decoders, tar, zip, the image decoders, the regexp pattern parser, URL, textproto, mail, multipart and DNS messages.

Anything in `core.crypto` that produces a wrong answer, leaks a key through timing, or accepts something it should reject. Certificate verification accepting a chain it should not is the most serious class of bug this repository can have.

Path traversal through `core.archive.tar` or `core.archive.zip`, including any way to get a path outside the destination past `safe_name`.

An escaping failure in `core.html.template`. The contextual auto escaper producing output that executes in any context is a security issue by definition.

Any injection through `core.net.url`, `core.net.textproto` or `core.net.smtp` normalisation, in particular where two components of this library disagree about what a string means.

## What does not count

Resource use that is proportional to the input and documented. A 500MB archive decompressing to 500MB of memory is the caller's decision to make, and the limits exist so the caller can make it.

A `must_*` function aborting on bad input. That is what the name means, and every one has a fallible sibling. The full list is in docs/deviations.md.

Anything in `tools/`, which is build tooling and not shipped.

## Versions

Pre-1.0, only the tip of `main` is supported. After 1.0 the current minor version gets fixes, and the one before it gets fixes for anything rated high or critical.

## Our side of it

Security fixes land with a regression test and the input that found the problem goes into `testdata/crashers/`. Advisories say what the bug was and what it let an attacker do, in plain terms, because an advisory that only says "improper input validation" does not help anybody decide whether they were affected.
