# PINS: 2. `raises` survives a function pointer
# EXPECT: runs
# OUTPUT: through the pointer 1 then negative
# WHY: This is what makes the tables in section 1 possible. Without it every
# WHY: erased call would have to smuggle failure out in the return value and
# WHY: the error design in section 4 would look completely different.


def might_fail(x: Int) raises -> Int:
    if x < 0:
        raise Error("negative")
    return x


def main():
    # The concrete storable type is spelled with thin. A def without it is a
    # trait, and a trait is not a value.
    var f: def(Int) raises thin -> Int = might_fail
    var ok = 0
    var message = String("no error came through")
    try:
        ok = f(1)
        _ = f(-1)
    except e:
        message = String(e)
    print("through the pointer", ok, "then", message)
