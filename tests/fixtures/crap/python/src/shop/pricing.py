def price(amount, member):
    if amount <= 0:
        return 0
    if member:
        return amount * 0.9
    return amount
