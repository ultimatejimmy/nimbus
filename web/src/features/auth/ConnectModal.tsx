import React, { useEffect, useState } from 'react';
import { Cloud, ExternalLink, Loader2, X } from 'lucide-react';
import { NimbusWebConfig } from '../../cloud';
import { DeviceCodeInfo, OAuthProvider, pollTokenOnce, requestDeviceCode } from '../../cloud/oauth';
import { CloudProviderId, OAuthTokens } from '../../cloud/types';
import { WebDAVWebDriver } from '../../cloud/webdav';

interface Props {
  config: NimbusWebConfig;
  onSaveConfig: (next: NimbusWebConfig) => void;
  onClose: () => void;
}

export const ConnectModal: React.FC<Props> = ({ config, onSaveConfig, onClose }) => {
  const [provider, setProvider] = useState<CloudProviderId>(config.provider === 'none' ? 'gdrive' : config.provider);
  const [remoteRoot, setRemoteRoot] = useState(config.remoteRoot || 'Nimbus');
  const [wdUrl, setWdUrl] = useState(config.webdav?.url || '');
  const [wdUser, setWdUser] = useState(config.webdav?.username || '');
  const [wdPass, setWdPass] = useState(config.webdav?.password || '');
  const [wdProxy, setWdProxy] = useState(config.webdav?.corsProxy || '');
  const [deviceInfo, setDeviceInfo] = useState<DeviceCodeInfo | null>(null);
  const [statusMsg, setStatusMsg] = useState('');
  const [errorMsg, setErrorMsg] = useState('');
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    if (!deviceInfo || provider === 'webdav' || provider === 'none') return;
    let active = true;
    const timer = setInterval(async () => {
      try {
        const tok: OAuthTokens | null = await pollTokenOnce(provider as OAuthProvider, deviceInfo.device_code);
        if (tok && active) {
          clearInterval(timer);
          setDeviceInfo(null);
          setStatusMsg('Connected!');
          onSaveConfig({
            ...config,
            provider,
            remoteRoot: remoteRoot.trim() || 'Nimbus',
            oauthTokens: { ...config.oauthTokens, [provider]: tok },
          });
          onClose();
        }
      } catch (e: any) {
        if (active) {
          clearInterval(timer);
          setDeviceInfo(null);
          setErrorMsg(e?.message || String(e));
        }
      }
    }, Math.max(3000, deviceInfo.interval * 1000));
    return () => {
      active = false;
      clearInterval(timer);
    };
  }, [deviceInfo, provider]);

  const startOAuth = async () => {
    if (provider !== 'gdrive' && provider !== 'onedrive' && provider !== 'dropbox') return;
    setErrorMsg('');
    setStatusMsg('Requesting authorization code...');
    setBusy(true);
    try {
      const info = await requestDeviceCode(provider);
      setDeviceInfo(info);
      setStatusMsg('Waiting for browser authorization...');
      if (info.verification_url) window.open(info.verification_url, '_blank', 'noopener');
    } catch (e: any) {
      setErrorMsg(e?.message || String(e));
      setStatusMsg('');
    } finally {
      setBusy(false);
    }
  };

  const connectWebDAV = async () => {
    setErrorMsg('');
    setBusy(true);
    try {
      const creds = { url: wdUrl.trim(), username: wdUser.trim(), password: wdPass, corsProxy: wdProxy.trim() };
      const drv = new WebDAVWebDriver(creds);
      await drv.testConnection();
      onSaveConfig({
        ...config,
        provider: 'webdav',
        remoteRoot: remoteRoot.trim() || 'Nimbus',
        webdav: creds,
      });
      onClose();
    } catch (e: any) {
      setErrorMsg(
        (e?.message || String(e)) +
          ' — If connecting to Nextcloud/NAS from a browser, ensure CORS headers allow this origin or configure a CORS proxy below.',
      );
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-slate-950/80 p-4 backdrop-blur-sm">
      <div className="w-full max-w-md rounded-2xl border border-slate-800 bg-slate-900 p-6 shadow-2xl">
        <div className="mb-4 flex items-center justify-between">
          <div className="flex items-center gap-2">
            <Cloud className="h-5 w-5 text-sky-400" />
            <h3 className="text-lg font-semibold">Connect Cloud Storage</h3>
          </div>
          <button onClick={onClose} className="text-slate-400 hover:text-slate-200">
            <X className="h-5 w-5" />
          </button>
        </div>

        <div className="space-y-4">
          <div className="grid grid-cols-2 gap-2">
            {(
              [
                ['gdrive', 'Google Drive'],
                ['onedrive', 'OneDrive'],
                ['dropbox', 'Dropbox'],
                ['webdav', 'WebDAV'],
              ] as const
            ).map(([id, label]) => (
              <button
                key={id}
                onClick={() => {
                  setProvider(id);
                  setDeviceInfo(null);
                  setErrorMsg('');
                }}
                className={`rounded-lg border px-3 py-2 text-sm font-medium transition ${
                  provider === id
                    ? 'border-sky-500 bg-sky-500/15 text-sky-300'
                    : 'border-slate-800 bg-slate-950/60 text-slate-300 hover:border-slate-700'
                }`}
              >
                {label}
              </button>
            ))}
          </div>

          <div>
            <label className="mb-1 block text-xs font-medium text-slate-400">Remote Root Folder</label>
            <input
              value={remoteRoot}
              onChange={(e) => setRemoteRoot(e.target.value)}
              className="w-full rounded-lg border border-slate-800 bg-slate-950 px-3 py-2 text-sm text-slate-100"
            />
          </div>

          {provider === 'webdav' ? (
            <div className="space-y-3">
              <input
                value={wdUrl}
                onChange={(e) => setWdUrl(e.target.value)}
                placeholder="https://cloud.example.com/remote.php/dav/files/user/"
                className="w-full rounded-lg border border-slate-800 bg-slate-950 px-3 py-2 text-sm"
              />
              <input
                value={wdUser}
                onChange={(e) => setWdUser(e.target.value)}
                placeholder="Username"
                className="w-full rounded-lg border border-slate-800 bg-slate-950 px-3 py-2 text-sm"
              />
              <input
                type="password"
                value={wdPass}
                onChange={(e) => setWdPass(e.target.value)}
                placeholder="Password / App Password"
                className="w-full rounded-lg border border-slate-800 bg-slate-950 px-3 py-2 text-sm"
              />
              <input
                value={wdProxy}
                onChange={(e) => setWdProxy(e.target.value)}
                placeholder="Optional CORS Proxy URL (Advanced)"
                className="w-full rounded-lg border border-slate-800 bg-slate-950 px-3 py-2 text-xs text-slate-300"
              />
              <button
                disabled={busy}
                onClick={connectWebDAV}
                className="w-full rounded-lg bg-sky-500 py-2.5 text-sm font-semibold text-slate-950 hover:bg-sky-400 disabled:opacity-50"
              >
                {busy ? 'Testing Connection...' : 'Connect WebDAV'}
              </button>
            </div>
          ) : (
            <div className="space-y-3">
              {deviceInfo ? (
                <div className="rounded-xl border border-sky-500/30 bg-sky-500/10 p-4 text-center">
                  <p className="text-xs text-slate-300">Enter this code in the opened browser tab:</p>
                  <p className="my-2 font-mono text-2xl font-bold tracking-widest text-sky-300">
                    {deviceInfo.user_code}
                  </p>
                  <a
                    href={deviceInfo.verification_url}
                    target="_blank"
                    rel="noreferrer"
                    className="inline-flex items-center gap-1 text-xs text-sky-400 underline"
                  >
                    Open authorization page <ExternalLink className="h-3 w-3" />
                  </a>
                </div>
              ) : (
                <button
                  disabled={busy}
                  onClick={startOAuth}
                  className="flex w-full items-center justify-center gap-2 rounded-lg bg-sky-500 py-2.5 text-sm font-semibold text-slate-950 hover:bg-sky-400 disabled:opacity-50"
                >
                  {busy && <Loader2 className="h-4 w-4 animate-spin" />}
                  Sign In with {provider === 'gdrive' ? 'Google Drive' : provider === 'onedrive' ? 'OneDrive' : 'Dropbox'}
                </button>
              )}
            </div>
          )}

          {statusMsg && <p className="text-xs text-sky-400">{statusMsg}</p>}
          {errorMsg && <p className="rounded-lg bg-rose-500/10 p-2.5 text-xs text-rose-300">{errorMsg}</p>}
        </div>
      </div>
    </div>
  );
};
