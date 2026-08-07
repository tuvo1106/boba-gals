import { defineConfig } from 'vitest/config'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'

// Tailwind is the project-wide styling layer (ADR-0003); shadcn/ui components
// get pulled in individually on top of it where they earn their place.

// `api` inside compose, localhost when the dev server runs on the host.
const apiTarget = process.env.VITE_API_TARGET ?? 'http://localhost:3000'

export default defineConfig({
  plugins: [react(), tailwindcss()],
  server: {
    // 0.0.0.0 so the dev server is reachable from outside its container (§12 step 0).
    host: true,
    port: 5173,
    // Polls the *filesystem* for edits — nothing to do with how the app talks
    // to the server, which is a websocket (see the /cable proxy below).
    // File-change events don't cross the bind-mount boundary reliably on macOS,
    // so HMR silently stops working without this.
    watch: { usePolling: true },
    // Same-origin in development, matching how nginx serves this bundle in
    // production (§14.1). The alternative — an API base URL in the client — is
    // one more environment variable to get wrong in the cluster.
    proxy: {
      '/api': { target: apiTarget, changeOrigin: true },
      // ws: true is what makes ActionCable work through the dev server. Without
      // it the upgrade request is proxied as plain HTTP and the board silently
      // never receives a broadcast (§9.2).
      '/cable': { target: apiTarget, ws: true, changeOrigin: true },
    },
  },
  test: {
    environment: 'jsdom',
    globals: true,
    setupFiles: './src/test/setup.ts',
    css: true,
  },
})
