"""Errors, and the record that carries what Go would have put in a struct.

Go's `errors` package, in the shape design.md section 4 forces: one error type
carrying a string, with the fields, the count and the wrap chain kept in a
thread local record and looked up at the catch site.

Start with `Report` to raise, `field` and `matches` to inspect. `record.mojo`
explains the mechanism and its limits, `chain.mojo` explains wrapping.
"""

from .chain import causes, join, matches, new, unwrap, wrap
from .codes import ErrUnsupported
from .record import NO_CODE, Code, Report, code, field, has_record, partial
