

from mutmut.mutation.trampoline import wrap_in_trampoline as _mutmut_mutated, MutantDict
mutants_x_add__mutmut: MutantDict = {}  # type: ignore
@_mutmut_mutated(mutants_x_add__mutmut)
def add(a, b):
    return a + b
def x_add__mutmut_orig(a, b):
    return a + b
def x_add__mutmut_1(a, b):
    return a - b

mutants_x_add__mutmut['_mutmut_orig'] = x_add__mutmut_orig # type: ignore # mutmut generated
mutants_x_add__mutmut['x_add__mutmut_1'] = x_add__mutmut_1 # type: ignore # mutmut generated
mutants_x_clamp__mutmut: MutantDict = {}  # type: ignore


@_mutmut_mutated(mutants_x_clamp__mutmut)
def clamp(x, lo, hi):
    if x < lo:
        return lo
    if x > hi:
        return hi
    return x


def x_clamp__mutmut_orig(x, lo, hi):
    if x < lo:
        return lo
    if x > hi:
        return hi
    return x


def x_clamp__mutmut_1(x, lo, hi):
    if x <= lo:
        return lo
    if x > hi:
        return hi
    return x


def x_clamp__mutmut_2(x, lo, hi):
    if x < lo:
        return lo
    if x >= hi:
        return hi
    return x

mutants_x_clamp__mutmut['_mutmut_orig'] = x_clamp__mutmut_orig # type: ignore # mutmut generated
mutants_x_clamp__mutmut['x_clamp__mutmut_1'] = x_clamp__mutmut_1 # type: ignore # mutmut generated
mutants_x_clamp__mutmut['x_clamp__mutmut_2'] = x_clamp__mutmut_2 # type: ignore # mutmut generated
mutants_xǁMeterǁover__mutmut: MutantDict = {}  # type: ignore


class Meter:
    @_mutmut_mutated(mutants_xǁMeterǁover__mutmut)
    def over(self, value, limit):
        return value > limit
    def xǁMeterǁover__mutmut_orig(self, value, limit):
        return value > limit
    def xǁMeterǁover__mutmut_1(self, value, limit):
        return value >= limit

mutants_xǁMeterǁover__mutmut['_mutmut_orig'] = Meter.xǁMeterǁover__mutmut_orig # type: ignore # mutmut generated
mutants_xǁMeterǁover__mutmut['xǁMeterǁover__mutmut_1'] = Meter.xǁMeterǁover__mutmut_1 # type: ignore # mutmut generated
