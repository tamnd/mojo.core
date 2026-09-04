"""Plain structs, a nested one, a generic one and a trait."""


trait Named:
    """Something with a name. Declared here so that the reader is asked about a
    trait it can find rather than only about the prelude's."""

    def label(self) -> String:
        """What to call it."""
        ...


@fieldwise_init
struct Point(Copyable, Named):
    """A position on a plane."""

    var x: Int
    """The distance right of the origin. `json:"x"`"""

    var y: Int
    """The distance up from the origin.

    The tag on this one is in the second paragraph rather than the first, which
    puts it in the `description` half of the docstring instead of the
    `summary` half. A reader that only looks at one of them misses it.
    `json:"y,omitempty" xml:"Y"`
    """

    def label(self) -> String:
        """Go's `Point.String`, near enough."""
        return "point"


@fieldwise_init
struct Line(Copyable):
    """Two points, which makes this the nested case."""

    var start: Point
    """Where the line begins. `json:"from"`"""

    var end: Point
    """Where it ends.

    Both fields have a type this package declares itself, so a reader that
    resolved nothing at all would still print something that looks right. The
    test asserts the resolution rather than the name. `json:"to"`
    """


@fieldwise_init
struct Boxed[T: Copyable & Deinitable](Copyable):
    """A value carried along with a label, which makes this the generic case."""

    var label: String
    """What the value is called.

    The word `label` in backticks here is prose about a field and not a tag,
    and neither is the `json` on its own further down this sentence. A reader
    that treats every backticked span as a tag finds two tags in this
    docstring and both are wrong.
    """

    var value: Self.T
    """The value itself, whose type is the struct's own parameter and so is not
    a type this package or any other declares. `json:"value"`"""

    var counts: Dict[String, List[Int]]
    """Something counted per name.

    Parameterised twice over, so the reader has to split the arguments on the
    comma that separates them without splitting on the one inside
    `List[Int]`. `json:"counts"`
    """
