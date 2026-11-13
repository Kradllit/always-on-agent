// Real places around a point, from two free sources that need no key (PLAN-nearby-places.md):
// Wikipedia for landmarks, buildings and history, and OpenStreetMap (Overpass) for restaurants,
// cafes, bars, museums and historic sites. Merged, de-duplicated, cached per ~100 m square.
import type { Place } from "./brain.ts";

export type NearbyPlace = Place & { source: "wikipedia" | "osm" | "wikipedia+osm"; image?: string; wikipedia_title?: string };
type SourceState = "ok" | string;

const UA = { "user-agent": "jensen-hackathon/0.1" };
const TIMEOUT_MS = 8000;
const CACHE_MS = 10 * 60 * 1000;
const cache = new Map<string, { at: number; wiki: NearbyPlace[]; osm: NearbyPlace[]; sources: Record<string, SourceState> }>();

const rad = Math.PI / 180;
export function metres(aLat: number, aLon: number, bLat: number, bLon: number) {
  const h = Math.sin(((bLat - aLat) * rad) / 2) ** 2 + Math.cos(aLat * rad) * Math.cos(bLat * rad) * Math.sin(((bLon - aLon) * rad) / 2) ** 2;
  return 2 * 6371000 * Math.asin(Math.sqrt(h));
}
const timed = (url: string, init: RequestInit = {}) => fetch(url, { ...init, headers: { ...UA, ...(init.headers || {}) }, signal: AbortSignal.timeout(TIMEOUT_MS) });

async function wikipedia(lat: number, lon: number, radius: number): Promise<NearbyPlace[]> {
  const q = new URLSearchParams({
    action: "query", format: "json", generator: "geosearch", ggscoord: `${lat}|${lon}`, ggsradius: String(Math.min(radius, 10000)),
    ggslimit: "30", prop: "pageimages|extracts|coordinates|info|description", inprop: "url", exintro: "1", explaintext: "1",
    exsentences: "2", exlimit: "30", pithumbsize: "600",
  });
  const r = await timed(`https://en.wikipedia.org/w/api.php?${q}`);
  if (!r.ok) throw new Error(`wikipedia ${r.status}`);
  const pages = Object.values(((await r.json()) as any).query?.pages || {}) as any[];
  return pages.filter((p) => p.coordinates?.[0]).map((p) => ({
    name: p.title, category: p.description || "landmark", lat: p.coordinates[0].lat, lon: p.coordinates[0].lon,
    summary: p.extract || p.description || "", url: p.fullurl, image: p.thumbnail?.source, wikipedia_title: p.title, source: "wikipedia" as const,
  }));
}

const OSM_FILTERS = [
  `nwr["amenity"~"^(restaurant|cafe|bar|pub|ice_cream|fast_food)$"]["name"]`,
  `nwr["tourism"~"^(museum|attraction|viewpoint|gallery|artwork)$"]["name"]`,
  `nwr["historic"]["name"]`,
];
async function openStreetMap(lat: number, lon: number, radius: number): Promise<NearbyPlace[]> {
  const body = `[out:json][timeout:8];(${OSM_FILTERS.map((f) => `${f}(around:${radius},${lat},${lon});`).join("")});out center tags 200;`;
  const r = await timed("https://overpass-api.de/api/interpreter", { method: "POST", body: new URLSearchParams({ data: body }) });
  if (!r.ok) throw new Error(`overpass ${r.status}`);
  const els = ((await r.json()) as any).elements || [];
  return els.map((e: any) => {
    const t = e.tags || {}, la = e.lat ?? e.center?.lat, lo = e.lon ?? e.center?.lon;
    const extra = [t.cuisine && `cuisine: ${t.cuisine.replace(/;/g, ", ")}`, t.opening_hours && `hours: ${t.opening_hours}`,
      t.start_date && `built: ${t.start_date}`, t.architect && `architect: ${t.architect}`, t.heritage && "heritage listed",
      t.description].filter(Boolean).join("; ");
    const wp = typeof t.wikipedia === "string" && t.wikipedia.startsWith("en:") ? t.wikipedia.slice(3) : undefined;
    return {
      name: t.name, category: t.amenity || t.tourism || (t.historic ? `historic ${t.historic}` : "place"), lat: la, lon: lo,
      address: [t["addr:housenumber"], t["addr:street"]].filter(Boolean).join(" ") || undefined,
      summary: extra, url: t.website || (wp ? `https://en.wikipedia.org/wiki/${encodeURIComponent(wp.replace(/ /g, "_"))}` : undefined),
      wikipedia_title: wp, source: "osm" as const,
    };
  }).filter((p: NearbyPlace) => p.name && p.lat != null);
}

/** A photo taken near a point, from Wikimedia Commons, for places whose article has none (and all OSM places). */
const photoCache = new Map<string, string | null>();
async function photoNear(lat: number, lon: number): Promise<string | undefined> {
  const key = `${lat.toFixed(4)},${lon.toFixed(4)}`;
  if (photoCache.has(key)) return photoCache.get(key) ?? undefined;
  try {
    const q = new URLSearchParams({ action: "query", format: "json", generator: "geosearch", ggsnamespace: "6",
      ggscoord: `${lat}|${lon}`, ggsradius: "60", ggslimit: "3", prop: "imageinfo", iiprop: "url|mime", iiurlwidth: "600" });
    const r = await timed(`https://commons.wikimedia.org/w/api.php?${q}`);
    const pages = Object.values(((await r.json()) as any).query?.pages || {}) as any[];
    const jpg = pages.map((p) => p.imageinfo?.[0]).find((i) => i && /jpe?g|png/.test(i.mime || ""));
    photoCache.set(key, jpg?.thumburl ?? null);
    return jpg?.thumburl;
  } catch { return undefined; }
}

/** One entry per real place: an OSM place that links to, or sits within 60 m of a same-named, Wikipedia article. */
export function merge(wiki: NearbyPlace[], osm: NearbyPlace[]): NearbyPlace[] {
  const out: NearbyPlace[] = [...wiki.map((w) => ({ ...w }))];
  const norm = (s: string) => s.toLowerCase().replace(/[^a-z0-9]/g, "");
  for (const o of osm) {
    const twin = out.find((w) => w.source !== "osm" && (
      (o.wikipedia_title && norm(o.wikipedia_title) === norm(w.wikipedia_title || w.name)) ||
      (norm(o.name) === norm(w.name) && metres(o.lat!, o.lon!, w.lat!, w.lon!) < 60)));
    if (twin) {
      Object.assign(twin, { category: o.category, address: o.address ?? twin.address, source: "wikipedia+osm",
        summary: [twin.summary, o.summary].filter(Boolean).join(" ") });
    } else if (!out.some((x) => norm(x.name) === norm(o.name) && metres(o.lat!, o.lon!, x.lat!, x.lon!) < 60)) out.push({ ...o });
  }
  return out;
}

export async function nearby(lat: number, lon: number, radiusM = 400, limit = 40) {
  const t0 = performance.now();
  const radius = Math.max(50, Math.min(2000, radiusM));
  const key = `${lat.toFixed(3)},${lon.toFixed(3)},${radius}`; // ~100 m square
  let hit = cache.get(key);
  if (!hit || Date.now() - hit.at > CACHE_MS) {
    const [w, o] = await Promise.allSettled([wikipedia(lat, lon, radius), openStreetMap(lat, lon, radius)]);
    hit = { at: Date.now(),
      wiki: w.status === "fulfilled" ? w.value : [], osm: o.status === "fulfilled" ? o.value : [],
      sources: { wikipedia: w.status === "fulfilled" ? "ok" : String(w.reason), osm: o.status === "fulfilled" ? "ok" : String(o.reason) } };
    // Don't keep a lookup where both sources failed; try again next time.
    if (hit.sources.wikipedia === "ok" || hit.sources.osm === "ok") cache.set(key, hit);
  }
  const places = merge(hit.wiki, hit.osm)
    .map((p) => ({ ...p, distance_m: Math.round(metres(lat, lon, p.lat!, p.lon!)) }))
    .filter((p) => p.distance_m <= radius)
    .sort((a, b) => a.distance_m - b.distance_m)
    .slice(0, limit);
  // Every place should come with a picture: fill the gaps from Commons photos taken on the spot.
  await Promise.all(places.filter((p) => !p.image).map(async (p) => { const img = await photoNear(p.lat!, p.lon!); if (img) { p.image = img; (p as any).image_source = "commons-nearby"; } }));
  return { places, sources: hit.sources, ms: Math.round(performance.now() - t0) };
}
