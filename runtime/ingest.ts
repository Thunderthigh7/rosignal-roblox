/**
 * Ingest settings: how much of the raw event firehose we actually store.
 *
 * Counts are always exact — they are aggregated in the game server and merged
 * into counter tables. Only the raw example rows behind the live feed and
 * drilldown are sampled, so cost stays flat as volume grows.
 *
 * Client-safe (no server imports) so the admin UI can render these.
 */

export interface IngestSettings {
  /** Share of raw events kept as browsable examples (0-1). Counts stay exact. */
  sampleRate: number;
  /** Hard ceiling on stored raw example rows, per game per UTC day. */
  rawPerGamePerDay: number;
  /** How long raw example rows are kept. */
  rawRetentionDays: number;
  /** How long per-minute counters are kept before they compact into days. */
  minuteRetentionDays: number;
  /** How long daily counters are kept. */
  dailyRetentionDays: number;
  /** How long per-player daily rows are kept. */
  playerRetentionDays: number;
  /** Seconds the in-game module waits between flushes. */
  flushSeconds: number;
  /** World studs per map heat cell captured in game. */
  mapCellSize: number;
  /** Distinct property values tracked per event property, per request. */
  maxPropValues: number;
  /** Property keys broken out per event. */
  maxPropKeys: number;
  /** Counter rows accepted in a single aggregate upload. */
  maxRowsPerUpload: number;
  /** Events one game can have counted in a single minute. */
  maxEventsPerMinute: number;
  /** Uploads one game key may send in a single minute. */
  maxUploadsPerMinute: number;
  /** Distinct event names one game may use in a UTC day. */
  maxEventNamesPerDay: number;
  /** Counter rows one game may write in a single minute. */
  counterRowsPerMinute: number;
  /** Per-player daily rows one game may store in a UTC day. */
  playerRowsPerGamePerDay: number;
  /** Map heat cells one game may store in a UTC day. */
  mapCellRowsPerGamePerDay: number;
  /** Largest request body accepted from a game server, in kilobytes. */
  maxBodyKb: number;
}

export const DEFAULT_INGEST_SETTINGS: IngestSettings = {
  sampleRate: 0.1,
  rawPerGamePerDay: 5_000,
  rawRetentionDays: 3,
  minuteRetentionDays: 7,
  dailyRetentionDays: 400,
  playerRetentionDays: 90,
  flushSeconds: 20,
  mapCellSize: 16,
  maxPropValues: 50,
  maxPropKeys: 5,
  maxRowsPerUpload: 2_000,
  maxEventsPerMinute: 2_000_000,
  maxUploadsPerMinute: 12,
  maxEventNamesPerDay: 300,
  counterRowsPerMinute: 500,
  playerRowsPerGamePerDay: 100_000,
  mapCellRowsPerGamePerDay: 50_000,
  maxBodyKb: 512,
};

export const INGEST_SETTING_LABELS: Record<keyof IngestSettings, string> = {
  sampleRate: "Raw sample rate",
  rawPerGamePerDay: "Raw rows per game per day",
  rawRetentionDays: "Raw example retention (days)",
  minuteRetentionDays: "Per-minute counter retention (days)",
  dailyRetentionDays: "Daily counter retention (days)",
  playerRetentionDays: "Per-player counter retention (days)",
  flushSeconds: "In-game flush interval (seconds)",
  mapCellSize: "Map cell size (studs)",
  maxPropValues: "Distinct values per property",
  maxPropKeys: "Properties broken out per event",
  maxRowsPerUpload: "Counter rows per upload",
  maxEventsPerMinute: "Events per game per minute",
  maxUploadsPerMinute: "Uploads per game per minute",
  maxEventNamesPerDay: "Distinct event names per day",
  counterRowsPerMinute: "Counter rows per minute",
  playerRowsPerGamePerDay: "Per-player rows per game per day",
  mapCellRowsPerGamePerDay: "Map cells per game per day",
  maxBodyKb: "Max upload size (KB)",
};

/** Current in-game module contract. Bump when the module must be reinstalled. */
export const MODULE_VERSION = 3;

const BOUNDS: Record<keyof IngestSettings, [number, number]> = {
  sampleRate: [0, 1],
  rawPerGamePerDay: [0, 5_000_000],
  rawRetentionDays: [1, 90],
  minuteRetentionDays: [1, 90],
  dailyRetentionDays: [7, 1_000],
  playerRetentionDays: [1, 400],
  flushSeconds: [5, 300],
  mapCellSize: [1, 512],
  maxPropValues: [1, 1_000],
  maxPropKeys: [0, 20],
  maxRowsPerUpload: [100, 20_000],
  maxEventsPerMinute: [1_000, 100_000_000],
  maxUploadsPerMinute: [1, 600],
  maxEventNamesPerDay: [10, 10_000],
  counterRowsPerMinute: [10, 10_000],
  playerRowsPerGamePerDay: [1_000, 10_000_000],
  mapCellRowsPerGamePerDay: [100, 1_000_000],
  maxBodyKb: [16, 4_096],
};

/** Merge stored JSON over the defaults, clamping anything out of range. */
export function resolveIngestSettings(...layers: (unknown | null | undefined)[]): IngestSettings {
  const out: IngestSettings = { ...DEFAULT_INGEST_SETTINGS };
  for (const layer of layers) {
    if (!layer || typeof layer !== "object") continue;
    const source = layer as Record<string, unknown>;
    for (const key of Object.keys(out) as (keyof IngestSettings)[]) {
      const value = source[key];
      if (typeof value !== "number" || !Number.isFinite(value)) continue;
      const [min, max] = BOUNDS[key];
      out[key] = Math.min(max, Math.max(min, value));
    }
  }
  return out;
}
