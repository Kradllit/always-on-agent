// Jensen's brain: decides whether a nearby place is worth a tap on the shoulder, writes the
// personal reason shown on the badge, and answers follow-up questions (typed in the app or
// spoken to the badge), with tools to book a table, get tickets or add the visit to a calendar.
import Anthropic from "@anthropic-ai/sdk";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";

// Fast enough for a spoken reply; override with JENSEN_MODEL.
export const MODEL = process.env.JENSEN_MODEL || "claude-haiku-5-5";

// The key comes from the environment or from a local.env (KEY='value' lines) next to this
// folder or at the top of the repository. Git ignores local.env.
function apiKey(): string | undefined {
  if (process.env.ANTHROPIC_API_KEY) return process.env.ANTHROPIC_API_KEY;
  for (const file of [join(import.meta.dir, "local.env"), join(import.meta.dir, "..", "local.env")]) {
    if (!existsSync(file)) continue;
    const line = readFileSync(file, "utf8").match(/^ANTHROPIC_API_KEY=(.+)$/m);
    if (line) return line[1].trim().replace(/^(['"])(.*)\1$/, "$2");
  }
  return undefined;
}
const client = new Anthropic({ apiKey: apiKey() });

// ── What Jensen keeps ───────────────────────────────────────────────────────────────────
export type Profile = {
  id: string;
  name: string;
  /** What the person said they're into, in their words or as the app's chips. */
  interests: string[];
  /** Anything else the interview learned ("walks slowly", "vegetarian", "visiting for 3 days"). */
  notes?: string;
};
export type Place = {
  name: string;
  category?: string;      // Apple Maps' category, e.g. "restaurant", "landmark"
  address?: string;
  lat?: number;
  lon?: number;
  distance_m?: number;
  summary?: string;       // anything known about it: a Wikipedia intro, opening hours, a menu line
  url?: string;
  phone?: string;
};
export type Shown = { id: string; place: Place; headline: string; why: string; at: number };
export type Action = { type: "booking" | "tickets" | "calendar"; summary: string; url?: string };

export const profiles = new Map<string, Profile>();
/** Places shown to each person, newest last; follow-up questions are about the newest. */
export const shown = new Map<string, Shown[]>();
export const actions: (Action & { profile: string; at: number })[] = [];
export const calendar = new Map<string, string>(); // id → .ics text

const id = () => Math.random().toString(36).slice(2, 10);

function aboutPerson(p: Profile) {
  return `Name: ${p.name}\nInto: ${p.interests.join("; ") || "not said yet"}` + (p.notes ? `\nAlso: ${p.notes}` : "");
}
function aboutPlace(pl: Place) {
  return [
    `Name: ${pl.name}`,
    pl.category && `Kind: ${pl.category}`,
    pl.address && `Address: ${pl.address}`,
    pl.distance_m != null && `Distance: ${Math.round(pl.distance_m)} m (${Math.max(1, Math.round(pl.distance_m / 80))} min walk)`,
    pl.summary && `Known about it: ${pl.summary}`,
    pl.url && `Website: ${pl.url}`,
  ].filter(Boolean).join("\n");
}

// ── 1. Recommend: is this place worth a ping, and why for this person? ──────────────────
const RECOMMEND_SYSTEM = `You are Jensen, an always-on walking companion. The person's phone just passed a place.
Decide whether it is worth interrupting them for, given what they told you they like, and if so write the
message that pops up on their round badge.

Rules:
- show is true only if the place clearly fits at least one of their interests. When in doubt, false.
- headline: the place's name, shortened to fit a small round screen (at most 4 words).
- why: one or two sentences, at most 30 words, speaking to them ("You ..."). Tie it to something they
  said, then give one concrete, true reason to go in: a fact, a dish, a detail to look at.
  Use only facts given to you or that you are certain of; never invent prices, hours or menu items.
- Plain text: Latin letters, digits and common punctuation only. No emoji, no markdown.`;

const RECOMMEND_SCHEMA = {
  type: "object",
  properties: {
    show: { type: "boolean" },
    headline: { type: "string" },
    why: { type: "string" },
    matched_interest: { type: "string", description: "Which of their interests it fits, in their words" },
  },
  required: ["show", "headline", "why", "matched_interest"],
  additionalProperties: false,
} as const;

export async function recommend(profile: Profile, place: Place) {
  const already = (shown.get(profile.id) || []).map((s) => s.place.name);
  const resp = await client.messages.create({
    model: MODEL,
    max_tokens: 400,
    system: RECOMMEND_SYSTEM,
    messages: [{
      role: "user",
      content: `THE PERSON\n${aboutPerson(profile)}\n\nTHE PLACE\n${aboutPlace(place)}` +
        (already.length ? `\n\nAlready shown today: ${already.join(", ")}` : ""),
    }],
    output_config: { format: { type: "json_schema", schema: RECOMMEND_SCHEMA } },
  } as any);
  const text = resp.content.map((b: any) => (b.type === "text" ? b.text : "")).join("");
  const out = JSON.parse(text) as { show: boolean; headline: string; why: string; matched_interest: string };
  if (!out.show) return { show: false as const, matched_interest: out.matched_interest };
  const entry: Shown = { id: id(), place, headline: out.headline, why: out.why, at: Date.now() };
  shown.set(profile.id, [...(shown.get(profile.id) || []), entry]);
  return { show: true as const, ...entry, matched_interest: out.matched_interest };
}

// ── 2. Ask: a follow-up question about the place on the badge, with tools ───────────────
const ASK_SYSTEM = `You are Jensen, an always-on walking companion that lives on a small round badge and in a phone app.
The person is asking a follow-up question, usually about the place you just showed them. They may be speaking
to the badge, so your reply is read aloud and shown on a small round screen.

Rules:
- Reply in one or two short sentences, at most 35 words. Plain text: Latin letters, digits and common
  punctuation. No lists, markdown or emoji.
- Use only facts given to you or that you are certain of. If you don't know (hours, prices, whether there's a
  table), say so plainly and offer to check or book.
- You can act: book a table, get tickets, or add a visit to their calendar. Ask once for anything you need
  (time, number of people) when they haven't said it; otherwise just do it and say what you did.
- These bookings are requests that Jensen records and hands to the person with a link to finish the booking;
  say "I've put in a request" or "here's the link", never that a restaurant has confirmed.`;

const TOOLS: Anthropic.Tool[] = [
  {
    name: "book_table",
    description: "Request a restaurant table for the person. Use when they ask to eat, reserve or book at a place.",
    input_schema: {
      type: "object",
      properties: {
        place: { type: "string" },
        when: { type: "string", description: "Local date and time, ISO 8601, e.g. 2026-11-13T19:30" },
        party_size: { type: "integer", minimum: 1 },
      },
      required: ["place", "when", "party_size"],
    },
  },
  {
    name: "get_tickets",
    description: "Find tickets for a museum, tour or show at a place. Use when they ask to visit something that needs a ticket.",
    input_schema: {
      type: "object",
      properties: {
        place: { type: "string" },
        date: { type: "string", description: "Local date, ISO 8601" },
        quantity: { type: "integer", minimum: 1 },
      },
      required: ["place", "quantity"],
    },
  },
  {
    name: "add_to_calendar",
    description: "Put a visit on the person's calendar, e.g. 'remind me to come back on Saturday'.",
    input_schema: {
      type: "object",
      properties: {
        title: { type: "string" },
        start: { type: "string", description: "Local date and time, ISO 8601" },
        minutes: { type: "integer", minimum: 5, default: 60 },
        location: { type: "string" },
        notes: { type: "string" },
      },
      required: ["title", "start"],
    },
  },
  {
    name: "clock",
    description: "The current local date and time where the person is. Use before booking anything for 'tonight' or 'tomorrow'.",
    input_schema: { type: "object", properties: {} },
  },
];

const TZ = process.env.JENSEN_TZ || "America/Los_Angeles";
const BASE = () => process.env.JENSEN_PUBLIC_URL || `http://localhost:${process.env.PORT || 8787}`;

function ics(title: string, start: string, minutes: number, location = "", notes = "") {
  const fmt = (d: Date) => d.toISOString().replace(/[-:]/g, "").replace(/\.\d{3}/, "");
  const s = new Date(start), e = new Date(s.getTime() + minutes * 60000);
  return ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Jensen//EN", "BEGIN:VEVENT", `UID:${id()}@jensen`,
    `DTSTAMP:${fmt(new Date())}`, `DTSTART:${fmt(s)}`, `DTEND:${fmt(e)}`, `SUMMARY:${title}`,
    `LOCATION:${location}`, `DESCRIPTION:${notes.replace(/\n/g, "\\n")}`, "END:VEVENT", "END:VCALENDAR"].join("\r\n");
}

function runTool(profile: Profile, name: string, input: any): { text: string; action?: Action } {
  switch (name) {
    case "clock":
      return { text: new Date().toLocaleString("en-US", { timeZone: TZ, dateStyle: "full", timeStyle: "short" }) };
    case "book_table": {
      const url = `https://www.opentable.com/s?term=${encodeURIComponent(input.place)}&covers=${input.party_size}&dateTime=${encodeURIComponent(input.when)}`;
      const action: Action = { type: "booking", summary: `Table for ${input.party_size} at ${input.place}, ${input.when}`, url };
      return { text: `Request recorded. Link for the person to confirm: ${url}`, action };
    }
    case "get_tickets": {
      const url = `https://www.google.com/search?q=${encodeURIComponent(`${input.place} tickets ${input.date || ""}`.trim())}`;
      const action: Action = { type: "tickets", summary: `${input.quantity} ticket(s) for ${input.place}${input.date ? `, ${input.date}` : ""}`, url };
      return { text: `Ticket search ready for the person: ${url}`, action };
    }
    case "add_to_calendar": {
      const cid = id();
      calendar.set(cid, ics(input.title, input.start, input.minutes || 60, input.location, input.notes));
      const url = `${BASE()}/calendar/${cid}.ics`;
      const action: Action = { type: "calendar", summary: `${input.title}, ${input.start}`, url };
      return { text: `Added. Calendar file: ${url}`, action };
    }
  }
  return { text: `Unknown tool ${name}` };
}

/** Earlier questions and answers per person, so "book it for two" follows "is it good for lunch?". */
const talk = new Map<string, Anthropic.MessageParam[]>();

export async function ask(profile: Profile, question: string) {
  const last = (shown.get(profile.id) || []).at(-1);
  const system = `${ASK_SYSTEM}\n\nTHE PERSON\n${aboutPerson(profile)}` +
    (last ? `\n\nTHE PLACE ON THE BADGE NOW\n${aboutPlace(last.place)}\nWhat you told them: ${last.why}` : "\n\nNo place is on the badge right now.");
  const history = (talk.get(profile.id) || []).slice(-8);
  const messages: Anthropic.MessageParam[] = [...history, { role: "user", content: question }];
  const done: Action[] = [];
  for (let turn = 0; turn < 5; turn++) {
    const resp = await client.messages.create({ model: MODEL, max_tokens: 500, system, tools: TOOLS, messages });
    messages.push({ role: "assistant", content: resp.content });
    if (resp.stop_reason !== "tool_use") {
      const reply = resp.content.map((b) => (b.type === "text" ? b.text : "")).join(" ").trim();
      talk.set(profile.id, [...history, { role: "user", content: question }, { role: "assistant", content: reply }]);
      for (const a of done) actions.push({ ...a, profile: profile.id, at: Date.now() });
      return { reply, actions: done, place: last?.place.name ?? null };
    }
    const results: Anthropic.ToolResultBlockParam[] = [];
    for (const block of resp.content) {
      if (block.type !== "tool_use") continue;
      const r = runTool(profile, block.name, block.input);
      if (r.action) done.push(r.action);
      results.push({ type: "tool_result", tool_use_id: block.id, content: r.text });
    }
    messages.push({ role: "user", content: results });
  }
  return { reply: "Sorry, I got stuck on that one. Try asking me again.", actions: done, place: last?.place.name ?? null };
}

export function newProfile(name: string, interests: string[], notes?: string): Profile {
  const p = { id: id(), name: name || "friend", interests, notes };
  profiles.set(p.id, p);
  return p;
}
