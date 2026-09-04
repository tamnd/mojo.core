"""Structs that must not get a codec.

One package rather than one per case, because each of these has to be refused
for its own reason and reading them next to each other is the fastest way to
see what the generator will and will not write.

The selftest plans this package and checks the message each struct produces.
A generator that stopped refusing something would otherwise emit code that
compiles and is wrong, which is the failure this whole design exists to avoid.
"""
