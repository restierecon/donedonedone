import { defineConfig } from "vitest/config";

export default defineConfig({
  esbuild: { jsx: "automatic" },
  test: {
    coverage: { provider: "v8", reporter: ["lcov"], include: ["src/**"] },
  },
});
