import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    // DOM tests need jsdom; pure-logic/crypto tests opt into node via
    // `// @vitest-environment node` at the top of the file.
    environment: "jsdom",
    include: ["test/**/*.test.js"],
  },
});
