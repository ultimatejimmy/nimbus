import React, { useMemo } from 'react';
import { BarChart, Bar, XAxis, YAxis, Tooltip, ResponsiveContainer } from 'recharts';
import { Clock, Flame, BookCheck, Layers } from 'lucide-react';
import { BookCatalogEntry, ProgressRecord, ReadingSession } from '../../cloud/types';

interface Props {
  sessions: ReadingSession[];
  books: BookCatalogEntry[];
  progressByBook: Record<string, ProgressRecord>;
}

export const StatsView: React.FC<Props> = ({ sessions, books, progressByBook }) => {
  const stats = useMemo(() => {
    let totalSec = 0;
    let totalPages = 0;
    const byDay = new Map<string, number>();

    for (const s of sessions) {
      totalSec += s.duration_sec || 0;
      totalPages += s.pages_read || 0;
      const day = new Date(s.start_time * 1000).toISOString().slice(0, 10);
      byDay.set(day, (byDay.get(day) || 0) + Math.round((s.duration_sec || 0) / 60));
    }

    const chartData = Array.from(byDay.entries())
      .sort(([a], [b]) => a.localeCompare(b))
      .slice(-14)
      .map(([date, minutes]) => ({ date: date.slice(5), minutes }));

    const finishedCount = Object.values(progressByBook).filter((p) => p.status === 'finished').length;
    const hours = (totalSec / 3600).toFixed(1);
    const pagesPerHour = totalSec > 60 ? Math.round((totalPages / totalSec) * 3600) : 0;

    return { hours, totalPages, finishedCount, activeDays: byDay.size, pagesPerHour, chartData };
  }, [sessions, progressByBook]);

  return (
    <div className="space-y-6">
      <div>
        <h2 className="text-2xl font-semibold tracking-tight">Reading Statistics</h2>
        <p className="text-sm text-slate-400">
          Combined reading sessions from KOReader & Nimbus Web Reader.
        </p>
      </div>

      <div className="grid grid-cols-2 gap-4 md:grid-cols-4">
        <div className="rounded-xl border border-slate-800 bg-slate-900/70 p-4">
          <div className="flex items-center gap-2 text-xs text-slate-400">
            <Clock className="h-4 w-4 text-sky-400" /> Total Reading Time
          </div>
          <p className="mt-2 text-2xl font-bold">{stats.hours}h</p>
        </div>
        <div className="rounded-xl border border-slate-800 bg-slate-900/70 p-4">
          <div className="flex items-center gap-2 text-xs text-slate-400">
            <Layers className="h-4 w-4 text-emerald-400" /> Pages Read
          </div>
          <p className="mt-2 text-2xl font-bold">{stats.totalPages}</p>
        </div>
        <div className="rounded-xl border border-slate-800 bg-slate-900/70 p-4">
          <div className="flex items-center gap-2 text-xs text-slate-400">
            <Flame className="h-4 w-4 text-amber-400" /> Active Days
          </div>
          <p className="mt-2 text-2xl font-bold">{stats.activeDays}</p>
        </div>
        <div className="rounded-xl border border-slate-800 bg-slate-900/70 p-4">
          <div className="flex items-center gap-2 text-xs text-slate-400">
            <BookCheck className="h-4 w-4 text-purple-400" /> Books Finished
          </div>
          <p className="mt-2 text-2xl font-bold">{stats.finishedCount}</p>
        </div>
      </div>

      <div className="rounded-xl border border-slate-800 bg-slate-900/70 p-5">
        <h3 className="mb-4 text-sm font-medium text-slate-300">Daily Reading Minutes (Last 14 Active Days)</h3>
        {stats.chartData.length === 0 ? (
          <p className="py-12 text-center text-sm text-slate-500">
            No reading sessions synced yet. Read a book in KOReader or the Web Reader to see your charts.
          </p>
        ) : (
          <div className="h-64 w-full">
            <ResponsiveContainer width="100%" height="100%">
              <BarChart data={stats.chartData}>
                <XAxis dataKey="date" stroke="#64748b" fontSize={12} />
                <YAxis stroke="#64748b" fontSize={12} />
                <Tooltip
                  contentStyle={{ backgroundColor: '#0f172a', border: '1px solid #1e293b', borderRadius: 8 }}
                />
                <Bar dataKey="minutes" fill="#38bdf8" radius={[4, 4, 0, 0]} />
              </BarChart>
            </ResponsiveContainer>
          </div>
        )}
      </div>

      <div className="rounded-xl border border-slate-800 bg-slate-900/70 p-5">
        <h3 className="mb-2 text-sm font-medium text-slate-300">Library Overview</h3>
        <p className="text-xs text-slate-400">
          {books.length} total books · Average speed: {stats.pagesPerHour} pages/hour
        </p>
      </div>
    </div>
  );
};
