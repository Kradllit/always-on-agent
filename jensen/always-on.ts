// The always-on part, on the Claude Agent SDK. The app reports where the person is
// (POST /location); every WATCH_S seconds Jensen looks at each person who moved, finds what's
// around them, and decides by itself whether something deserves a tap on the shoulder.
// What it decides to show waits in a queue the badge and the app pick up (GET /badge/next).
import { createSdkMcpServer, query, tool } from "@anthropic-ai/claude-agent-sdk";
import { z } from "zod";
import { profiles, shown, type Profile, type Shown } from "./brain.ts";
import { nearby } from "./nearby.ts";

const MODEL = process.env.JENSEN_AGENT_MODEL || "claude-sonnet-5-5";
const WATCH_S = Number(process.env.JENSEN_WATCH_S || 20);
const RADIUS_M = Number(process.env.JENSEN_RADIUS_M || 250);

export const whereabouts = new Map<string, { lat: number; lon: number; at: number; checked?: number }>();
export const badgeQueue = new Map<string, Shown[]>();
export const log: { at: number; profile: string; line: string }[] = [];
const note = (profile: string, line: string) => { log.push({ at: Date.now(), profile, line }); console.log(`[${profile}] ${line}`); };

type Nearby = { name: string; distance_m: number; summary: string; image?: string; url: string; lat: number; lon: number };

/** Real places around a point, from Wikipedia and OpenStreetMap (nearby.ts). */
async function placesAround(lat: number, lon: number): Promise<Nearby[]> {
  const { places } = await nearby(lat, lon, RADIUS_M, 15);
  return places.map((p) => ({ name: p.name, distance_m: p.distance_m ?? 0, summary: [p.category, p.summary].filter(Boolean).join(": "),
    image: p.image, url: p.url || "", lat: p.lat!, lon: p.lon! }));
}

function toolsFor(profile: Profile, found: Nearby[]) {
  const showOnBadge = tool(
    "show_on_badge",
    "Pop one place up on the person's round badge, with its picture and your reason. Use at most once per check, only for a place that clearly fits them.",
    {
      place: z.string().describe("Exactly one of the names from the list you were given"),
      headline: z.string().describe("The place's name, at most 4 words"),
      why: z.string().describe("At most 30 words, to them ('You ...'): which of their interests it fits, and one concrete true reason to go in"),
    },
    async ({ place, headline, why }) => {
      const hit = found.find((f) => f.name === place);
      if (!hit) return { content: [{ type: "text", text: `No place called ${place} in the list.` }] };
      const entry: Shown = { id: Math.random().toString(36).slice(2, 10), headline, why, at: Date.now(),
        place: { name: hit.name, distance_m: hit.distance_m, summary: hit.summary, lat: hit.lat, lon: hit.lon, url: hit.url, ...(hit.image ? { image: hit.image } : {}) } as any };
      shown.set(profile.id, [...(shown.get(profile.id) || []), entry]);
      badgeQueue.set(profile.id, [...(badgeQueue.get(profile.id) || []), entry]);
      note(profile.id, `showed ${hit.name}: ${why}`);
      return { content: [{ type: "text", text: "Shown on the badge." }] };
    },
  );
  return [showOnBadge];
}

/** One look around for one person: the agent sees the places and decides. */
async function check(profile: Profile, lat: number, lon: number) {
  const seen = new Set((shown.get(profile.id) || []).map((s) => s.place.name));
  const found = (await placesAround(lat, lon)).filter((f) => !seen.has(f.name));
  if (!found.length) return note(profile.id, "nothing new nearby");
  const tools = toolsFor(profile, found);
  const prompt = `${profile.name} is walking. They are into: ${profile.interests.join("; ")}.${profile.notes ? ` Also: ${profile.notes}.` : ""}
Places within ${RADIUS_M} m that they haven't seen yet, nearest first:
${found.map((f) => `- ${f.name} (${f.distance_m} m): ${f.summary.slice(0, 280)}`).join("\n")}

If one of these clearly fits what they're into, show it on their badge with show_on_badge. If none does, show nothing and say "nothing". Never show more than one.`;
  const run = query({
    prompt,
    options: {
      model: MODEL,
      systemPrompt: "You are Jensen, an always-on walking companion. You interrupt only for places that truly fit the person, and you use only facts you were given or are certain of. Plain text, no emoji.",
      tools: [],
      mcpServers: { jensen: createSdkMcpServer({ name: "jensen", tools }) },
      allowedTools: tools.map((t) => `mcp__jensen__${t.name}`),
      permissionMode: "dontAsk",
      settingSources: [],
      persistSession: false,
      maxTurns: 4,
    },
  });
  for await (const m of run) if (m.type === "result" && m.subtype !== "success") note(profile.id, `check stopped: ${m.subtype}`);
}

/** The loop that never stops: everyone who moved since their last check gets looked after. */
export function startWatching() {
  let busy = false;
  setInterval(async () => {
    if (busy) return;
    busy = true;
    try {
      for (const [pid, w] of whereabouts) {
        const p = profiles.get(pid);
        if (!p || (w.checked && w.checked >= w.at)) continue;
        w.checked = Date.now();
        await check(p, w.lat, w.lon).catch((e) => note(pid, `check failed: ${e}`));
      }
    } finally { busy = false; }
  }, WATCH_S * 1000);
  console.log(`Jensen is watching: a look around every ${WATCH_S} s for anyone who moved (model ${MODEL})`);
}
