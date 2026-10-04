package shop;

public final class Shipping {
    public static int shipping(String region, int weight, boolean express) {
        int base;
        if (region.equals("eu")) {
            base = 5;
        } else if (region.equals("us")) {
            base = 7;
        } else if (region.equals("ca")) {
            base = 9;
        } else {
            base = 12;
        }
        if (weight > 10) {
            base += 3;
        }
        if (express) {
            base *= 2;
        }
        return base;
    }
}
