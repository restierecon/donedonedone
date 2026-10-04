from shop.pricing import price


def test_free_when_nothing_bought():
    assert price(0, False) == 0


def test_members_get_ten_percent_off():
    assert price(100, True) == 90


def test_others_pay_full_price():
    assert price(100, False) == 100
