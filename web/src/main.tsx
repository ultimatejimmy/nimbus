import React from 'react';
import ReactDOM from 'react-dom/client';
import App from './App';
import './index.css';

window.addEventListener('vite:preloadError', () => {
  const key = 'nimbus_preload_reloaded';
  if (!sessionStorage.getItem(key)) {
    sessionStorage.setItem(key, '1');
    window.location.reload();
  }
});

ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>,
);
