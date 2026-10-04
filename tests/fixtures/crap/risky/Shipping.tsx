export function shipping(region: string, weight: number, express: boolean): number {
  let base: number;
  if (region === "eu") {
    base = 5;
  } else if (region === "us") {
    base = 7;
  } else if (region === "ca") {
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
