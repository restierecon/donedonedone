package shop;

public final class Pricing {
    private Pricing() {
    }

    public static double price(double amount, boolean member) {
        if (amount <= 0) {
            return 0;
        }
        if (member) {
            return amount * 0.9;
        }
        return amount;
    }
}
