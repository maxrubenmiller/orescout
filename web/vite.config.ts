import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// https://vite.dev/config/
export default defineConfig({
  plugins: [react()],
  // The prospectivity per-commodity strings live in the repo-root config/ (shared with the ETL);
  // allow the dev server to serve imports from one level above web/.
  server: { fs: { allow: ['..'] } },
})
