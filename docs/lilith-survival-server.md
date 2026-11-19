# Lilith Survival Server (Minecraft, Forge 1.20.1)

A fourth Minecraft deployment on the existing `k3s-node1` cluster, built from
the modpack exported in `Modpack/Lilith 1.noriskpack` (a NoRiskClient launcher
profile — a zip containing a `profile.json` manifest with a per-mod Modrinth/
CurseForge source and direct download URL, not a CurseForge/Modrinth
`.mrpack`). Namespace: `lilith-survival-server` (the user asked for
`LilithSurvivalServer`; Kubernetes namespace names must be lowercase
DNS-1123 labels, so it was lowercased/hyphenated).

Status: **deployed 2026-11-19, awaiting the user's in-game verification**
before merge, per this repo's branch workflow (`CLAUDE.md`).

## What's running

- `itzg/minecraft-server:java17`, `TYPE=FORGE`, `VERSION=1.20.1`,
  `FORGE_VERSION=recommended` (the modpack's own `profile.json` left
  `loader_version` blank too — same as letting the NoRiskClient launcher
  auto-pick — so the image resolves whatever Forge currently calls
  "recommended" for 1.20.1 rather than a version pinned here).
- Mods are fetched directly by URL (`MODS_FILE` pointing at a ConfigMap-mounted
  list), not through the CurseForge or Modrinth APIs — no API key needed,
  since `profile.json` already carried a resolved download URL per mod.
- `INIT_MEMORY=2G` / `MAX_MEMORY=8G` originally proposed, then raised to
  **`MAX_MEMORY=16G`** per the user's explicit request after reviewing the
  plan. Container `requests.memory=4Gi` / `limits.memory=20Gi` (the 4Gi gap
  above `MAX_MEMORY` is JVM off-heap headroom, same reasoning as
  `prominence-server`'s `MAX_MEMORY=32G`/`limits=36Gi`).
  - **Known tradeoff, not re-confirmed after the bump**: at the time of
    deploy, `k3s-node1` already had ~47.8Gi of memory *limits* allocated
    across existing pods (88% of the node's ~54Gi) while *actual* usage was
    only ~13.7Gi (25%) — k8s limits are soft caps, not reservations, so this
    runs fine today, but if `prominence-server` and this pod ever both hit
    their ceilings at once (36Gi + 20Gi = 56Gi) that alone exceeds the node's
    physical RAM. Real request-based scheduling headroom was fine (only
    ~10.7Gi of requests reserved before this pod); the risk is worst-case
    concurrent *usage*, not a scheduling failure.
- `Recreate` Deployment strategy + one `ReadWriteOnce` 20Gi PVC (`local-path`),
  matching the pattern in `docs/phase1-proxmox-k3s.md`.
- `NodePort` service, container port 25565 → **node port `30567`** (next free
  after the existing 25565/30565, 25567/30566, 25565/30970). Connect from a
  Minecraft 1.20.1 Forge client to `192.168.178.40:30567`.
- Generous startup probes: this modpack's worldgen stack (Terralith + Biomes
  O' Plenty + Tectonic/TerraBlender + L_Ender's Cataclysm + Aquamirae, plus
  74 mods to fetch on a fresh PVC) can take a while on a cold start.
  Confirmed on the real first boot: mods downloaded, Forge installed, and the
  server reached `Done (67.546s)!` well inside the probe budget — no restart
  loop. Liveness `initialDelaySeconds: 1800` is deliberately generous for any
  future cold start (e.g. after a node reboot) that's slower than this one
  was.

## Mods: 74 of the pack's 89 run on the server; 15 were left off

The pack's own `profile.json` already had 3 mods disabled by the user
(`Tough As Nails` [superseded by its CurseForge-sourced duplicate, which
stayed enabled], `Tough As Nails +`, `Simply Swords Tweaks`) and one
duplicate entry (`GlitchCore` was listed twice, once per source — only one
jar was kept). Of the remaining 85, 11 more were excluded from the **server**
mods folder specifically (the client/launcher profile still has them, they
just don't belong on a dedicated server):

**Wrong loader for this pack (Fabric/NeoForge-only, can't load under Forge
at all)**: `Sodium`, `The Graveyard (Fabric/Neoforge)`,
`Forge Config API Port`, `Additional Ores`, `Fabric API`.

**Confirmed client-only via Modrinth's own `server_side` project metadata
(queried live, not guessed)**: `Embeddium`, `Entity Culling`,
`Retro Damage Indicators`, `Simply Tooltips`, `S-Lib` — all
`server_side: unsupported`.

**Manual exclusion**: `Oculus` (CurseForge-only Forge port of Iris — client
shaders, no Modrinth listing to check against, unambiguously rendering-only).

All three exclusion categories, the exact memory numbers, and node port were
reviewed with the user before deploying; all were approved, including the
later `MAX_MEMORY` increase from 8G to 16G.

### The 74 mods actually on the server

<details>
<summary>Full list</summary>

- Terralith
- Lithostitched
- Tectonic
- ChoiceTheorem's Overhauled Village
- Born in Chaos
- Geckolib
- VillagersTradingPlus
- Sophisticated Backpacks
- Just Enough Items (JEI)
- MezzConfig
- Panda's Falling Trees
- PandaLib
- Architectury API
- Sophisticated Core
- Alex's Mobs
- Citadel
- Farmer's Delight
- Quark
- Zeta
- In Control!
- Biomes O' Plenty
- TerraBlender
- GlitchCore
- Dynamic Trees - Biomes O' Plenty
- Dynamic Trees
- Dynamic Trees - Quark
- Dynamic Trees - Terralith
- When Dungeons Arise
- YUNG's Better Dungeons
- YUNG's API
- Dungeons and Taverns
- YUNG's Better Nether Fortresses
- YUNG's Better Ocean Monuments
- YUNG's Better Mineshafts
- YUNG's Better Jungle Temples
- YUNG's Better End Island
- YUNG's Better Strongholds
- YUNG's Better Witch Huts
- YUNG's Better Desert Temples
- YUNG's Extras
- Towns and Towers
- Cristel Lib
- Explorify
- L_Ender's Cataclysm
- Lionfish-API
- Curios API
- Improved Mobs
- TenshiLib
- Enhanced Celestials
- Data Anchor
- CorgiLib
- Illager Invasion
- Puzzles Lib
- Serene Seasons
- Diet
- Corpse
- Aquamirae
- Fragmentum
- Aquamirae Delight
- Apotheosis
- Patchouli
- Apothic Attributes
- Placebo
- Pufferfish's Skills
- Default Skill Trees
- Pufferfish's Attributes
- Simply Swords
- Fzzy Config
- Kotlin for Forge
- Guard Villagers
- AppleSkin
- Clumps
- Tough As Nails
- Jade 🔍

</details>

The exact download URLs for all 74 are in
`k8s/lilith-survival-server/configmap-mods.yaml`.

## Observed at first boot (2026-11-19)

- Pod `lilith-survival-server-74b8b6ff94-txzss`: `Running`, `1/1 Ready`,
  reached `Done (67.546s)!` with no crash and no restart.
- Two benign, non-fatal log lines worth knowing about if they recur:
  - `ForgeConfigSpec/CORE: Incorrect key interaction.canopyCrash was
    corrected from null to its default, true` — a config auto-correction on
    first run, not an error.
  - `[incontrol/]: Error writing areas.json!` — `In Control!`'s spawn-area
    config failed to write on this first boot. No custom spawn areas are
    configured in this pack, so default spawning behavior is unaffected;
    worth checking `/data/config/incontrol/areas.json` if custom spawn rules
    are ever added later and don't seem to apply.

## Open items (not done yet)

- **No backup mechanism** — same gap already flagged for `prominence-server`
  in `docs/phase1-proxmox-k3s.md` section 6. This is a fresh world with
  nothing in it yet; revisit before real playtime accumulates.
- **User has not yet connected a Minecraft client to verify.** Per
  `CLAUDE.md`, nothing merges to `main` until that happens.
