export function Outer(x: number) {
  const onClick = () => {
    if (x) { return 1; }
    return 2;
  };
  return onClick;
}
