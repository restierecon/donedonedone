import pytest

from shop.discount import discount


def test_discount_takes_ten_percent_over_a_hundred():
    assert discount(200) == 180


def test_discount_leaves_a_hundred_alone():
    assert discount(100) == 100


def test_discount_starts_just_over_a_hundred():
    assert discount(101) == pytest.approx(90.9)
