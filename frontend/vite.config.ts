import { defineConfig } from 'vitest/config'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'

// Tailwind is the project-wide styling layer (ADR-0003); shadcn/ui components
// get pulled in individually on top of it where they earn their place.
export default defineConfig({
  plugins: [react(), tailwindcss()],
  server: {
    // 0.0.0.0 so the dev server is reachable from outside its container (§12 step 0).
    host: true,
    port: 5173,
    // Polling: file-change events don't cross the bind-mount boundary reliably
    // on macOS, so HMR silently stops working without it.
    watch: { usePolling: true },
  },
  test: {
    environment: 'jsdom',
    globals: true,
    setupFiles: './src/test/setup.ts',
    css: true,
  },
})
