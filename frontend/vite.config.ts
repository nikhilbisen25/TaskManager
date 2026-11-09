import tailwindcss from '@tailwindcss/vite'
import react from '@vitejs/plugin-react'
import { defineConfig } from 'vite'

// The app always calls the relative path /api. In dev, Vite proxies it to the services running
// natively; in docker-compose nginx does the same; in AWS CloudFront routes /api/* to the backends.
export default defineConfig({
  plugins: [react(), tailwindcss()],
  server: {
    port: 5173,
    proxy: {
      '/api/auth': 'http://localhost:8001',
      '/api/tasks': 'http://localhost:8002',
    },
  },
})
