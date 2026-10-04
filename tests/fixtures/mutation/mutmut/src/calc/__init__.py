def add(a, b):
    return a + b


def clamp(x, lo, hi):
    if x < lo:
        return lo
    if x > hi:
        return hi
    return x


class Meter:
    def over(self, value, limit):
        return value > limit
