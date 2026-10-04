def shipping(region, weight, express):
    if region == "eu":
        base = 5
    elif region == "us":
        base = 7
    elif region == "ca":
        base = 9
    else:
        base = 12
    if weight > 10:
        base += 3
    if express:
        base *= 2
    return base
