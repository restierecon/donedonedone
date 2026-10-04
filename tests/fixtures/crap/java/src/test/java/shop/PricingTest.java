package shop;

import static org.junit.jupiter.api.Assertions.assertEquals;

import org.junit.jupiter.api.Test;

class PricingTest {
    @Test
    void freeWhenNothingBought() {
        assertEquals(0, Pricing.price(0, false));
    }

    @Test
    void membersGetTenPercentOff() {
        assertEquals(90, Pricing.price(100, true));
    }

    @Test
    void othersPayFullPrice() {
        assertEquals(100, Pricing.price(100, false));
    }
}
