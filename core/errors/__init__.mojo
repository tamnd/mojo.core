"""Errors, adapted rather than ported.

Go's errors are values with a type. Mojo's `Error` carries a string and nothing
else, so the parts of Go's package that depend on a concrete error type are
rebuilt on a record written into thread local storage at raise time. See
record.mojo for the mechanism and docs/design.md section 4 for why.
"""

from .record import (
    Report,
    code,
    field,
    has_record,
    partial,
)
