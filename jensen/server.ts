// Jensen's brain over HTTP, for the iOS app and the badge server.
//
//   bun server.ts                 listens on PORT (8787)
//
//   POST /profile    {name, interests: [..], notes?}            → {id, ...}
//   POST /recommend  {profile_id, place: {name, category, address, lat, lon, distance_m, summary}}
//                    → {show: false} or {show: true, id, headline, why, place}
//   POST /ask        {profile_id, text}   a follow-up, typed or spoken, about the place on the badge
//                    → {reply, actions: [{type, summary, url}]}
//   GET  /calendar/<id>.ics                                        a visit Jensen added
//   GET  /state?profile_id=..                                      what Jensen showed and did
import { actions, ask, calendar, MODEL, newProfile, profiles, recommend, shown } from "./brain.ts";

const PORT = Number(process.env.PORT || 8787);
const json = (data: unknown, status = 200) =>
  new Response(JSON.stringify(data), { status, headers: { "content-type": "application/json", "access-control-allow-origin": "*" } });

Bun.serve({
  port: PORT,
  async fetch(req) {
    const url = new URL(req.url);
    if (req.method === "OPTIONS") return new Response(null, { headers: { "access-control-allow-origin": "*", "access-control-allow-headers": "content-type" } });
    try {
      if (url.pathname === "/health") return json({ ok: true, model: MODEL });
      if (req.method === "POST" && url.pathname === "/profile") {
        const b = await req.json();
        return json(newProfile(String(b.name || ""), (b.interests || []).map(String), b.notes));
      }
      if (req.method === "POST" && (url.pathname === "/recommend" || url.pathname === "/ask")) {
        const b = await req.json();
        const profile = profiles.get(b.profile_id) ?? (b.profile ? newProfile(b.profile.name, b.profile.interests || [], b.profile.notes) : undefined);
        if (!profile) return json({ error: "unknown profile_id; POST /profile first, or send profile inline" }, 400);
        const t0 = performance.now();
        const out = url.pathname === "/recommend" ? await recommend(profile, b.place) : await ask(profile, String(b.text || ""));
        return json({ profile_id: profile.id, ...out, ms: Math.round(performance.now() - t0) });
      }
      const ics = url.pathname.match(/^\/calendar\/(\w+)\.ics$/);
      if (ics && calendar.has(ics[1])) return new Response(calendar.get(ics[1]), { headers: { "content-type": "text/calendar" } });
      if (url.pathname === "/state") {
        const p = url.searchParams.get("profile_id") || "";
        return json({ profile: profiles.get(p), shown: shown.get(p) || [], actions: actions.filter((a) => a.profile === p) });
      }
      return json({ error: "not found" }, 404);
    } catch (e) {
      return json({ error: String(e) }, 500);
    }
  },
});
console.log(`Jensen's brain on http://localhost:${PORT} (model ${MODEL})`);
