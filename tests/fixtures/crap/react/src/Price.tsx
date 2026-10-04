export function Price({ amount, member }: { amount: number; member: boolean }) {
  if (amount <= 0) {
    return <span>free</span>;
  }
  if (member) {
    return <span>{amount * 0.9}</span>;
  }
  return <span>{amount}</span>;
}
