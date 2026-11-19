import React from 'react';
import { Laptop, RefreshCw, Trash2 } from 'lucide-react';
import { NimbusWebConfig } from '../../cloud';

interface Props {
  config: NimbusWebConfig;
  devices: string[];
  onOpenConnect: () => void;
  onSyncNow: () => Promise<void>;
  onClearCache: () => Promise<void>;
}

export const SettingsView: React.FC<Props> = ({
  config,
  devices,
  onOpenConnect,
  onSyncNow,
  onClearCache,
}) => {
  return (
    <div className="max-w-2xl space-y-6">
      <div>
        <h2 className="text-2xl font-semibold tracking-tight">Settings & Connected Devices</h2>
        <p className="text-sm text-slate-500 dark:text-slate-400">
          Manage your cloud provider, device identity, and offline IndexedDB cache.
        </p>
      </div>

      <div className="space-y-3 rounded-xl border border-slate-200 bg-white p-5 dark:border-slate-800 dark:bg-slate-900/70">
        <div className="flex items-center justify-between">
          <div>
            <p className="text-sm font-medium">Cloud Provider</p>
            <p className="text-xs text-slate-500 dark:text-slate-400">
              {config.provider === 'none' ? 'Not connected' : `${config.provider.toUpperCase()} · Root: /${config.remoteRoot}`}
            </p>
          </div>
          <div className="flex gap-2">
            <button
              onClick={onSyncNow}
              className="inline-flex items-center gap-1.5 rounded-lg border border-slate-200 px-3 py-1.5 text-xs font-medium text-slate-700 hover:bg-slate-100 dark:border-slate-700 dark:text-slate-200 dark:hover:bg-slate-800"
            >
              <RefreshCw className="h-3.5 w-3.5" /> Sync Now
            </button>
            <button
              onClick={onOpenConnect}
              className="rounded-lg bg-emerald-600 px-3 py-1.5 text-xs font-semibold text-white transition hover:bg-emerald-500 dark:bg-emerald-500 dark:text-slate-950 dark:hover:bg-emerald-400"
            >
              Change Provider
            </button>
          </div>
        </div>
        <div className="border-t border-slate-200 pt-3 text-xs text-slate-500 dark:border-slate-800 dark:text-slate-400">
          This browser device ID:{' '}
          <code className="rounded bg-slate-100 px-1.5 py-0.5 text-emerald-700 dark:bg-slate-950 dark:text-emerald-300">
            {config.deviceId}
          </code>
        </div>
      </div>

      <div className="space-y-3 rounded-xl border border-slate-200 bg-white p-5 dark:border-slate-800 dark:bg-slate-900/70">
        <h3 className="text-sm font-medium">Connected Sync Devices ({devices.length})</h3>
        {devices.length === 0 ? (
          <p className="text-xs text-slate-500">No device shards found yet.</p>
        ) : (
          <ul className="space-y-2">
            {devices.map((d) => (
              <li key={d} className="flex items-center gap-2 text-xs text-slate-700 dark:text-slate-300">
                <Laptop className="h-3.5 w-3.5 text-emerald-600 dark:text-emerald-400" />
                <span>{d}</span>
              </li>
            ))}
          </ul>
        )}
      </div>

      <div className="flex items-center justify-between rounded-xl border border-slate-200 bg-white p-5 dark:border-slate-800 dark:bg-slate-900/70">
        <div>
          <p className="text-sm font-medium">Local Offline Cache</p>
          <p className="text-xs text-slate-500 dark:text-slate-400">
            Clear downloaded ebooks & cover thumbnails from IndexedDB.
          </p>
        </div>
        <button
          onClick={onClearCache}
          className="inline-flex items-center gap-1.5 rounded-lg border border-rose-500/40 bg-rose-500/10 px-3 py-1.5 text-xs font-medium text-rose-600 hover:bg-rose-500/20 dark:text-rose-300"
        >
          <Trash2 className="h-3.5 w-3.5" /> Clear Cache
        </button>
      </div>
    </div>
  );
};
