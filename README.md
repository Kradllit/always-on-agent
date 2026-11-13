# Jensen

Team Jensen's entry for the Anthropic Partner Basecamp hackathon: **Jensen, an always-on agent**.
Jensen watches a (synthetic) company's production incidents, deploys and vendor contracts
around the clock, and has a body: a small round touchscreen badge that shows what it is doing.

## What's in this repo

| Folder | What |
|---|---|
| `issues/`, `runbooks/`, `deploys/`, `contracts/`, `compliance-policy.md` | The synthetic enterprise Jensen works on, from the hackathon's starter repo ([rosscrooke/always-on-agent](https://github.com/rosscrooke/always-on-agent)) |
| `badge/` | Rust firmware for Jensen's badge, the Waveshare ESP32-S3-Touch-AMOLED-1.75C: eyes, touch, text, sound, Wi-Fi, Bluetooth. Brought in with its history from [Kradllit/basecamp-badge](https://github.com/Kradllit/basecamp-badge); see `badge/README.md` |

All data in the enterprise folders is fictional.

---

# Synthetic Enterprise Repo

This is the working environment for the Always-On Ops Agent. Fork or clone this into a GitHub repo on your own account, then point your routine at it.

## What's in here

- `issues/` — Open production incidents (JSON). Realistic but synthetic.
- `runbooks/` — Operational playbooks the agent can reference.
- `deploys/` — Recent deploy log (`recent.json`), used for correlating incidents with deploys.
- `contracts/` — Vendor contracts (for Card C — Compliance Drift).
- `compliance-policy.md` — The policy the compliance agent enforces.

All data is fictional. Companies, names, error messages, contract terms — none of it maps to real systems.

## How to use

```bash
# Clone (or fork) this into your own GitHub
gh repo create my-hackathon-repo --private --clone
cd my-hackathon-repo
cp -r ../partner-basecamp-hackathon/01-always-on-ops-agent/synthetic-repo/* .
git add . && git commit -m "Seed synthetic enterprise data" && git push

# Then point your routine at this repo via the Routines UI
```
