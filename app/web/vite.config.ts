import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Everything is bundled into the image. The cluster has no route to the
// internet, so a runtime CDN reference would render a blank page in production
// and work perfectly on the developer's laptop.
export default defineConfig({
  plugins: [react()],
  build: {
    outDir: "dist",
    emptyOutDir: true,
    assetsInlineLimit: 0,
  },
  server: {
    proxy: { "/ask": "http://127.0.0.1:8080" },
  },
});
