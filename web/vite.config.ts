import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import { VitePWA } from 'vite-plugin-pwa';

export default defineConfig({
  base: process.env.VITE_BASE_PATH || '/',
  plugins: [
    react(),
    VitePWA({
      registerType: 'autoUpdate',
      includeAssets: ['favicon.svg'],
      manifest: {
        name: 'Nimbus Cloud Library & Reader',
        short_name: 'Nimbus',
        description: 'Zero-self-hosting ebook library, Whispersync, highlights, and reading stats.',
        theme_color: '#0f172a',
        background_color: '#0f172a',
        display: 'standalone',
        icons: [
          {
            src: 'favicon.svg',
            sizes: 'any',
            type: 'image/svg+xml',
          },
        ],
      },
    }),
  ],
  build: {
    target: 'esnext',
  },
  server: {
    port: 5180,
  },
  preview: {
    port: 4180,
  },
});
