import { renderToString } from "react-dom/server";
import { expect, test } from "vitest";
import { Price } from "./Price";

test("free when nothing bought", () => {
  expect(renderToString(<Price amount={0} member={false} />)).toBe("<span>free</span>");
});

test("members get ten percent off", () => {
  expect(renderToString(<Price amount={100} member={true} />)).toBe("<span>90</span>");
});

test("others pay full price", () => {
  expect(renderToString(<Price amount={100} member={false} />)).toBe("<span>100</span>");
});
