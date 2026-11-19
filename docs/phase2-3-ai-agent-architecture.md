# Phase 2/3: AI agent architecture (GPU + local LLM + Discord voice bot)

Status: **designed, not yet built.** Blocked on the XFX Radeon AI Pro R9700
32GB GPU arriving (Phase 2b/3 below). Phase 2a does not need the GPU and can
start any time.

This supersedes the brief Phase 2/3 bullets in [`ROADMAP.md`](./ROADMAP.md)
with a detailed design, based on a source architecture diagram
(`mermaid-diagram.png`, repo root) plus several rounds of review and
refinement.

## Goal

A Discord voice bot that (a) chats naturally via a local personality LLM, and
(b) can execute real infrastructure actions (create/delete VMs, etc.) across
multiple possible backends, gated by risk-tiered safety checks and human
approval — without ever blocking the conversation on a slow or pending action.

## Diagram review verdict

The source diagram is fundamentally sound: it correctly identifies the real
risk (a voice-triggered agent with genuine infra control) and designs real
mitigations — risk tiers, human approval, secrets isolation, audit logging,
and an output-safety filter before TTS (important given this project's own
history of generating real passwords/tokens mid-conversation). The
refinements below sharpen it; they don't replace it.

## Decisions

- **Cost-aware, multi-backend dispatch is a hard requirement.** The
  Capability Router must not default every action-shaped request to Claude
  Code. Deterministic tasks go to **n8n** (zero LLM cost), simple lookups go
  straight to a tool call, and the model choice (local LLM / Claude / ChatGPT
  or another API) is a real per-request decision, config-driven rather than
  hardcoded. This reconciles with, rather than reverses, the earlier ROADMAP
  decision "Claude Code, not n8n" — that decision was about which engine
  drives genuinely open-ended agentic reasoning, not a ban on n8n for known,
  repeatable automations.
- **Risk-tier default posture: approvable via human confirmation, not
  hard-forbidden.** Destructive/irreversible actions (delete VM, etc.)
  default to the `risky` tier and can proceed if a human approves via a
  Discord button — not permanently blocked. The `forbidden` tier is reserved
  for a short, explicit list where even Discord-button approval isn't
  enough because the action could compromise the enforcement mechanism
  itself — see item 3's concrete list (privilege escalation, backup
  deletion, ZFS destruction, changes to the agent's own security controls).
- **Secrets: SOPS-encrypted, never pushed to GitHub, even encrypted.** Keep
  the two-tier Proxmox/k8s credentials in a gitignored/local-only path.
- **Bot/orchestrator language: Node.js** (`discord.js` + `@discordjs/voice`).
  Chosen for performance/maturity of its real-time voice pipeline (jitter
  buffers, per-user Opus streams) over Python's comparatively experimental
  voice-receive support. STT/TTS/local-LLM serving still run as separate
  Python-hosted services on the GPU VM regardless — process boundary via
  HTTP — so this only affects the orchestrator/bot process itself.
- **Docs stay local-only**, consistent with the rest of `docs/`.

## Refined architecture

1. **Capability Router — a real, custom-built component.** Its job is
   cost-aware dispatch across multiple backends, most of which shouldn't
   touch a paid LLM at all:
   - **Predefined skills / n8n workflows** — known, repeatable tasks (e.g.
     "restart the Minecraft server") run as a fixed automation, zero LLM cost.
   - **Direct tool calls** — e.g. a plain web search or browser fetch needs no
     model reasoning; call the tool directly.
   - **Local LLM** — free, always-on, handles casual chat and simple
     classification/lookup tasks that need some judgment but not deep
     multi-step reasoning.
   - **Claude Code** — reserved for tasks that genuinely need multi-step
     agentic tool use and planning over real infra state — not the default
     handler for every action-shaped request.
   - **Other model APIs (e.g. ChatGPT)** — the model-selection branch is a
     pluggable backend registry (config-driven), not hardcoded to "local or
     Claude," so another provider can be added later without re-architecting.
2. **Result-checking lives at the router level, not solely inside Claude
   Code** — it has to judge success/failure across whichever backend handled
   the request and decide whether to escalate to a more capable (typically
   pricier) backend on failure. That cross-backend judgment can't live inside
   any single backend's own loop.
3. **The safety/permission check is a shared, backend-agnostic gateway — and
   it operates on a fixed catalogue of typed actions, never generic command
   execution.** In the source diagram, "check individual action" and
   "secrets and permissions" sit *after* the capability router, downstream
   of every branch — meaning the check must be a single chokepoint every
   backend passes through, not something wired only into one backend's SDK.
   Concretely: build a small **Action Execution Gateway** service, with
   these properties:
   - **Fixed action catalogue, not generic shell/kubectl/Proxmox-API
     execution.** The gateway only knows how to perform a pre-defined,
     parameterized set of actions (e.g. `create_vm(template, cpu, ram)`,
     `delete_vm(vm_id)`, `restart_service(name)`) — it has no "run this
     arbitrary command" entry point. This is what makes risk classification
     and auditing tractable at all: an open-ended exec surface gated only by
     an LLM's own judgment of "how risky is this" is a much larger, far less
     securable attack surface, especially given the agent is voice/LLM
     driven and therefore manipulable by prompt injection (see the untrusted
     input principle below). Every backend — n8n workflow, local-LLM
     function call, Claude Code tool call, ChatGPT function call — can only
     ever invoke a catalogue entry, never a raw command.
   - **The gateway determines risk; it never trusts a backend's own risk
     classification.** Risk tier is a static property of the catalogue entry
     itself, looked up in `agent/policy/risk-tiers.yaml` (`safe | risky |
     forbidden`) by action type and parameters — not something an LLM
     self-reports and the gateway takes at face value. If Claude Code (or
     any backend) claims an action is "safe," the gateway still classifies
     it independently from the catalogue.
   - **Approval is bound to the exact action, parameters, target, and a plan
     hash — with the full lifecycle guarantees that make the hash actually
     mean something, not just present.** A hash alone doesn't secure
     anything; the security property comes from what the gateway does with
     it:
     - The approval record includes: a canonical (deterministic)
       serialization of the action parameters, a random one-time nonce, an
       expiration time, the requesting user's identity, the approving
       user's identity, which `risk-tiers.yaml` policy version classified
       it, and a digest of the relevant target state/configuration (not
       just an ID — see below).
     - **The Discord button carries only an opaque action/approval ID**,
       never trusted action parameters supplied by the client interaction —
       the gateway looks up the real parameters server-side from the
       `actions` table by that ID, it never trusts anything embedded in the
       button payload itself.
     - Approval is **consumed atomically, in the same Postgres transaction**
       that transitions the action into its executable state — the gateway
       checks `stored plan digest = approved plan digest = current
       execution plan digest` as one atomic operation, so a second
       concurrent execution attempt (or a replayed approval) can't slip
       through between the check and the state transition.
     - **Immediately before execution**, the gateway re-verifies
       preconditions against live state, not just the digest captured at
       approval time — for a VM action, checking the VM ID alone is
       insufficient, since an ID can theoretically be deleted and reused;
       re-check the VM name and a resource/config fingerprint, not ID
       alone.
   - **Only the gateway ever holds real Proxmox/k8s credentials** — both
     the always-on `safe`-tier read-only token and the post-approval
     privileged token (item 7). No backend (n8n, local LLM, Claude Code,
     ChatGPT) is ever handed a credential directly, even for a `safe`-tier
     read; every action, regardless of tier, is invoked through the gateway
     so every credential use is classified, scoped, and logged in one
     place.
   - Waits for Discord-button approval if `risky`, injects the scoped
     credential, executes, and logs to the `actions` table (below). When
     Claude Code is the chosen backend, its MCP tool for "perform an infra
     action" calls this gateway rather than touching credentials directly —
     the Agent SDK's own `canUseTool` can still be used as a secondary,
     cheap sanity check within Claude's own turn, but the gateway is the
     sole authoritative enforcement point across all backends.
   - **Idempotency is mandatory before any real write/destructive action is
     enabled — not an open question to defer.** If a call like `qm clone`
     times out, the worker genuinely cannot tell whether the request never
     reached Proxmox, is still running, completed successfully, or
     completed but the response was lost. Blindly retrying risks duplicate
     resources. Every catalogue entry must define, before it's usable for
     real: an idempotency key, a way to check whether the action already
     happened (e.g. querying Proxmox for a resource matching the intended
     result before creating another), retry rules, timeout behavior, and
     explicit behavior for the case where external state is genuinely
     uncertain. A new action status, `unknown_requires_reconciliation`,
     covers that last case — distinct from `failed`, since retrying a
     `failed` action is often fine but retrying an `unknown` one might
     duplicate a real resource. **Destructive actions are never
     auto-retried unless the gateway can conclusively prove the original
     action did not execute** — when it can't prove that, the action goes
     to `unknown_requires_reconciliation` for a human to resolve, not an
     automatic retry.
   - **`forbidden`-tier actions are manual-only in the strictest sense: a
     human does them directly (Proxmox UI/SSH), not even via a
     Discord-approved agent action.** Concrete starter list: privilege
     escalation (e.g. granting cluster-admin), backup deletion, ZFS pool
     destruction, and any change to the agent's own security controls
     (`risk-tiers.yaml`, the allowlist, the gateway itself). That last
     category matters most: if the agent's own enforcement can be modified
     *by* the agent, a successful prompt injection could disable the very
     mechanism meant to contain it — human-in-the-loop Discord approval
     doesn't help if the compromise is in the approval mechanism's own
     configuration. These stay outside the catalogue entirely, not just
     defaulted to a tier that happens to require approval.
4. **Speaker authorization — a gate missing from the original diagram.**
   Discord voice audio is per-speaker, so the Discord user ID is known at
   capture time. Before any request reaches the planning/action path, check
   the speaker's ID against a trusted-user allowlist. This is a coarser,
   earlier check than the per-action risk tier — "who may act at all" vs. "how
   dangerous is this specific action" are different questions. Casual chat
   stays open to anyone in the channel; only action-type requests are gated.
5. **Interaction-level authorization — the same allowlist gates Discord UI,
   not just voice.** Speaker authorization (above) covers voice capture, but
   every Discord button click (Approve/Deny) and slash command (`/agent
   pause`, `/agent stop <id>`, etc.) needs the same check: `interaction.
   user.id` is available natively on the interaction, so the handler checks
   it against the same trusted-user allowlist before honoring an approval,
   a deny, or a kill/pause command. Layer Discord's own per-guild
   command/channel permissions on top as defense-in-depth, and log any
   rejected attempt (wrong user clicking a button or invoking a command) to
   the `actions` table — a security-relevant event worth auditing, not a
   silent no-op.
6. **Human approval UX: a Discord text channel with Approve/Deny buttons**,
   not spoken yes/no — voice STT misrecognition on a safety-critical
   confirmation is a real failure mode; a button click isn't. The message
   must render the exact concrete action — target resource, operation, and
   whether it's reversible (e.g. "Delete VM 'lilith-mc' (ID 105)?
   Irreversible.") — not a vague "approve this action?" prompt, so approval
   requires actually reading what will happen rather than reflexively
   clicking a familiar-looking button. This rendered detail is exactly what
   gets hashed for the plan-hash binding in item 3 — what the human reads is
   what gets cryptographically tied to what's allowed to execute.
7. **Credentials: Kubernetes and Proxmox need separate designs, because
   their capabilities and lifecycles differ — don't treat "two-tier scoped
   credentials" as one uniform pattern across both.**
   - **Kubernetes**: short-lived, narrowly-scoped service-account tokens are
     genuinely feasible to mint per-approval — a `safe`-tier read-only token
     always available *to the gateway* (never distributed to individual
     backends, per item 3), plus a privileged token minted for a specific
     approved action, short TTL, torn down after use. This explicitly does
     not repeat the pattern this project actually hit in practice: the
     Kubernetes Dashboard's `admin-user` service account, found live-bound
     to `cluster-admin` via ClusterRoleBinding — a real, currently-active
     blanket admin token, not just a hypothetical anti-pattern. That binding
     needs review independent of this design work.
   - **Proxmox**: dynamically minting a privileged credential per-approval
     is a real design problem, not just a detail to fill in later — doing
     so would require the gateway to hold an *even more privileged* identity
     capable of managing tokens and permissions itself, which is a worse
     concentration of power than the thing it's trying to avoid. The safer
     initial design is a **fixed set of narrowly-scoped tokens/roles**,
     provisioned once, ahead of time, not minted on demand:
     - `proxmox-readonly` — one permanent read-only token.
     - Several purpose-specific tokens/roles scoped to a narrow action
       class, e.g. `proxmox-vm-power` (start/stop only), `proxmox-vm-create-
       in-agent-pool` (create, but only within a designated resource pool),
       `proxmox-vm-delete-in-disposable-pool` (delete, but only within a
       pool reserved for agent-created disposable VMs).
     - All of these live exclusively in the gateway; policy (not the LLM)
       selects which credential a specific approved action is allowed to
       use, based on the catalogue entry.
     - **No gateway-held Proxmox token may modify users, ACLs, roles, or
       API tokens** — administering the agent's own credentials stays
       manual-only, for the same reason forbidden-tier actions do (item 3):
       the agent must not be able to expand its own privileges.
8. **GPU hosting: a dedicated Proxmox VM** (`ai-gpu-vm`), not passed into
   `k3s-node1`. Isolates the fragile ROCm/driver stack from the node already
   running Minecraft/monitoring/Dashboard/DNS, and avoids AMD device-plugin/
   SR-IOV complexity that isn't needed for a single, unshared GPU. This VM
   hosts STT (whisper.cpp/faster-whisper), the local personality LLM
   (vLLM-ROCm or llama.cpp server, OpenAI-compatible API), and TTS
   (Piper/XTTS) as internal HTTP services reachable over the LAN. Since
   these run directly on a plain VM, not as k3s pods, their process
   supervision is systemd units or plain Docker containers with restart
   policies and healthchecks — see the corrected mechanisms in item 12 for
   exactly which failure triggers which restart, since "k3s liveness probe"
   doesn't apply to this VM at all. Which of the two (systemd vs. Docker)
   gets used is an open question below; either is fine, but the doc must
   not imply k3s mechanisms apply to a VM that's deliberately outside the
   cluster.

   **The orchestrator's location is decided, not open**: it runs as a k3s
   Deployment on `k3s-node1`, alongside the capability router, background
   worker, Action Execution Gateway, Postgres, and n8n — none of these need
   the GPU, and running them in k3s gets restart policies, resource limits,
   and the existing monitoring stack for free. Only the GPU-dependent
   services (STT, TTS, local LLM) live on `ai-gpu-vm`.

   **Network protection must not depend on VLAN support existing — that's
   a strengthening, not the baseline.** A dedicated VLAN separating this VM
   (and the orchestrator) from Proxmox's management interface is desirable,
   but the minimum protection has to work on a flat LAN too, since whether
   the router/switch supports VLANs is still an open question here. On a
   flat LAN, Phase 2a still requires: the Proxmox API firewalled to accept
   requests only from the gateway's IP (Proxmox's own host firewall is
   confirmed **disabled** on this cluster right now — this is a real gap,
   not a hypothetical); `ai-gpu-vm` has no direct Proxmox API access at all;
   n8n and model-worker processes can't reach the management API directly
   either — only the gateway can; the gateway's own API requires mTLS or
   equivalent strong service authentication, so a backend can't act just by
   reaching an unauthenticated internal HTTP endpoint; and the gateway
   validates both which backend is calling and which action is being
   invoked, not just that *some* internal caller hit the endpoint. Anything
   that only fetches web content or drives a browser (the search skill,
   etc.) gets no network path to the management plane at all. A VLAN later
   strengthens this; it isn't what makes it exist in the first place.
9. **Audio must be processed as VAD-segmented utterances, never buffered for
    the whole session — this is what keeps a multi-hour call from growing
    memory usage.** Raw audio capture feeds a voice-activity-detector; as
    soon as silence is detected, that utterance-sized chunk goes to STT and
    is discarded immediately, rather than accumulating the session's full
    raw PCM/Opus audio in memory. Combined with the short-term buffer
    already being a bounded last-N-turns window (not proportional to call
    length) and the LLM context per turn being built from that window plus
    retrieved memory rather than the full transcript, none of the
    conversational pipeline's memory usage scales with how long a call
    runs — a 6-hour session should use the same steady-state memory as a
    6-minute one. Concretely, both tools needed for this are already part
    of the chosen stack, nothing new to integrate: `@discordjs/voice`'s
    receiver, subscribed with `end: { behavior: EndBehaviorType.AfterSilence,
    duration: <ms> }`, closes a speaking user's audio stream after N ms of
    silence — a built-in, per-user utterance-boundary detector based on
    Discord's own speaking-state signal. Refine with a **VAD interface
    that's independent of whichever STT engine ends up chosen**, rather
    than hard-wiring to one library's feature: define it as a pluggable
    step with implementations such as Silero VAD (standalone), faster-
    whisper's built-in `vad_filter=True` (Silero under the hood, but only
    relevant if faster-whisper specifically is the STT choice),
    whisper.cpp-compatible VAD, or Discord's own silence boundary paired
    with a secondary VAD service — whichever gets picked, refine residual
    silence/noise the Discord-level cutoff misses (mic noise, breathing)
    and avoid wasting GPU cycles transcribing near-silent audio, without
    coupling this item's design to one specific STT library. Also specify,
    before real implementation: a maximum utterance duration (so one
    person talking continuously doesn't grow an unbounded buffer),
    a maximum buffered audio size, per-speaker queue limits, backpressure
    behavior when STT can't keep up, and explicit handling for overlapping
    speakers (Discord's per-user streams make this tractable, but the
    behavior still needs to be defined, not left implicit).
10. **Turn-taking: the bot must be able to decide not to respond, and
    barge-in needs debouncing — this is what makes a group voice channel
    feel like a natural three-person conversation rather than talking to an
    assistant.** Two related problems, addressed together:
    - **Silence is a first-class outcome, not a missing branch.** Every
      transcribed utterance currently implies either a chat reply or an
      action — there's no way for the bot to just not answer. Add a
      turn-taking gate right after STT, before chat/action classification:
      given recent conversational context (who's speaking, whether the
      bot's name was used, whether the utterance reads as addressed to
      another specific human), classify it as addressed-to-bot /
      addressed-to-someone-else / ambiguous. Addressed-to-someone-else
      utterances still update the short-term buffer (the bot needs to have
      "heard" it for later context) but produce no reply and no TTS
      output — exactly like a person in a group not jumping in on every
      exchange between two other people. Casual chat's open-to-anyone
      policy (item 4) still applies to *whether* an utterance is eligible
      for a reply; this gate decides *whether a reply is warranted at all*.
    - **The ambiguous case is driven by the persona's own traits (item
      13), not a separate tunable.** An extroverted/high-directness persona
      interjects more readily when it's unclear whether the group wants its
      input; a shy one defaults to staying quiet unless directly addressed.
      Reuses the trait system already designed rather than adding new
      infrastructure.
    - **Barge-in must be debounced, not instant.** Given Discord's inherent
      audio delay, stopping TTS playback the instant any voice activity is
      detected would cut the bot off on coincidental overlaps or false
      starts (both speakers start at once; the user stops because they
      want to hear the answer) — the opposite of the intended feel.
      Require a short confirmation window (a few hundred ms of continued,
      non-trivial speech) before committing to an interrupt, rather than
      reacting to the first VAD trigger.
11. **Output safety filter — structural removal first, pattern/entropy
    scanning as defense-in-depth, not the guarantee.** Pattern and entropy
    scanning alone cannot guarantee secrets never reach TTS — it can miss
    unusual token formats, a secret spoken in separate pieces, low-entropy
    passwords, a secret the model has transformed, or sensitive information
    that doesn't look like a conventional credential at all. The actually
    strong design: tools and the gateway never return raw secret values to
    the model in the first place — sensitive response fields are removed
    structurally at the tool/gateway boundary, logs and command output are
    filtered before they ever enter the model's context, and the model only
    ever sees explicitly allowlisted result fields. Pattern/entropy scanning
    then runs as a final, last-resort layer before TTS, not the mechanism
    doing the actual guaranteeing. Separately: non-secret infrastructure
    details — internal IPs, usernames, security configuration — may still
    be inappropriate to speak aloud in a group voice channel even though
    they aren't technically secrets; route results like that to a
    restricted text channel instead of TTS.
12. **RAM budget must be re-checked at Phase 2b time, not assumed now — and
    the k3s node's budget is tighter than the raw total suggests once
    Minecraft's real ceiling is accounted for.** Per `phase1-proxmox-k3s.md`'s
    resource budget, `win11-vm` has been removed entirely (it was only a
    test VM), and `k3s-node1` was resized 2026-09-01 from 4 vCPU/48GB to
    **8 vCPU/54GB** (applied via `qm set` + a reboot, confirmed all
    workloads including `prominence-server` came back healthy afterward).
    That leaves the future AI GPU VM (24-32GB placeholder) against a
    smaller remaining margin than before the resize — the top of that
    placeholder range would now push the real total close to or past 96GB,
    so re-checking the GPU VM's actual footprint before committing to its
    final size (Phase 2b) matters more, not less, now that some of the
    headroom `win11-vm`'s removal created has been spent on the k3s node
    itself.

    Real data from `prominence-server` (the live Minecraft deployment on
    `k3s-node1`) confirmed the `INIT_MEMORY`/`MAX_MEMORY` pattern this doc
    recommends fixes *idle* usage (dropped from ~44GB to ~9GB idle by
    replacing a fixed `MEMORY=40G`, which forces `Xms=Xmx=40G` immediately,
    with `INIT_MEMORY=4G` + `MAX_MEMORY=40G`) — but it does **not** reduce
    the *maximum* possible usage: the JVM can still legitimately grow to a
    40GB heap under real load, and with off-heap overhead the process could
    again approach ~44GB+. The live container's `resources.limits.memory`
    was also found set to `50Gi`, which **exceeded the VM's entire previous
    48GB of physical RAM** — an impossible ceiling that provided no real
    protection, since the VM would run out of memory at the host level
    before that cgroup limit ever triggered. **Applied 2026-09-01**:
    `MAX_MEMORY=32G`, container `limits.memory: 36Gi`, `requests.memory:
    8Gi` — confirmed live at ~8.8GB immediately after restart, healthy.
    Combined with the node resize, this leaves comfortably more room for
    k3s itself, Postgres, n8n, the orchestrator, the gateway, and
    monitoring than before, though Minecraft can still legitimately use up
    to its 32GB ceiling under real load — that's still the majority of the
    node's 54GB if it happens.

    As a safety net against slow leaks in any long-lived process (even
    carefully bounded code can leak over hours), the mechanisms differ and
    shouldn't be conflated: for the orchestrator (a k3s pod), a **memory
    limit** exceeded triggers `OOMKilled` and a restart per the pod's
    restart policy — a separate mechanism from a **liveness probe**, which
    restarts a container that's unhealthy or unresponsive regardless of its
    memory usage; both are worth having, but they catch different failure
    modes and don't substitute for each other. For the STT/TTS/local-LLM
    services on `ai-gpu-vm`, which are **not** k3s pods (item 8), the
    equivalent is systemd's `MemoryMax=` (cgroup kills the process on
    breach) paired with `Restart=on-failure` to bring it back — or a Docker
    memory limit + restart policy + healthcheck, if containerized instead.
    Reuse the existing monitoring stack for visibility across all of these
    rather than trusting code discipline alone for multi-hour sessions.
13. **Memory stores**: short-term (per-session rolling buffer) in Redis or
    in-process with a TTL; long-term semantic memory + the action audit log
    in **Postgres + pgvector** (one dependency doing double duty, avoids
    standing up a separate vector DB at this scale). This is infra, though —
    what actually gets stored is the piece that drives the "feels alive"
    personality goal:
    - **Short-term buffer**: last N raw turns of the current session,
      verbatim — keeps a single conversation coherent turn-to-turn.
    - **Long-term store holds three content types, not raw transcripts**:
      (a) discrete facts about the user (name, preferences, ongoing
      projects, important dates), extracted and upserted as they come up;
      (b) rolling session summaries (a few sentences per session, not full
      transcripts) so history stays queryable without unbounded growth; (c)
      relationship/rapport state — running inside jokes, nicknames, open
      narrative threads ("promised to show me the new VM rack") — the
      specific ingredient that produces callbacks and makes the persona feel
      like it's tracking an ongoing relationship rather than answering fresh
      every time.
    - **Write path**: after a turn/session, a lightweight extraction step
      (cheap — the local LLM itself via a small classification prompt) pulls
      new facts/summary updates and upserts them, rather than embedding
      every raw utterance as its own vector row.
    - **Read path**: each turn, retrieve top-K relevant entries via vector
      similarity on the current message, plus always include a small set of
      "pinned" facts (name, core relationship facts) regardless of
      similarity score, and inject both into the system prompt alongside
      the short-term buffer.
    - **Per-user identity and privacy boundaries are required fields, not a
      later refinement.** Since casual chat is open to anyone in the voice
      channel (item 4), memory rows need `guild_id`, `channel_id`,
      `subject_user_id`, `source_message_id`, `memory_type`, `confidence`,
      `created_at`, `valid_from`, `valid_until`, and `last_confirmed_at`.
      Personal facts and relationship state are stored **per Discord user**
      — several people talking in the same voice channel must never
      collapse into one shared/global fact about "the user." Required user
      rights: inspect their own stored memories, correct an inaccurate one,
      delete an individual memory, delete everything tied to their Discord
      ID, and opt out of long-term memory entirely.
    - **Retrieved memory is untrusted data, same as item 17's principle for
      Discord messages and web content — it must never be interpreted as
      system instructions or action authorization**, even though the bot
      itself originally wrote it. A memory entry summarizing something
      someone said is still just data describing what was said.
    - **The extraction step must not permanently store**: credentials,
      private infrastructure details, access tokens, or sensitive personal
      information that isn't actually needed for the personality feature to
      work. "Extract useful facts" is not a blank check to persist anything
      that appeared in a conversation.
14. **Personality state: slow-evolving traits plus a per-session mood, kept
    strictly separate.** This is what lets the persona feel consistent
    turn-to-turn without feeling frozen forever — the goal is a character
    that develops over weeks/months, not one with hardcoded trait values,
    and not one whose personality randomly swings within a single
    conversation either. Two distinct timescales, two distinct mechanisms:
    - **Traits (long-term, persists across sessions)**: a small structured
      table (`personality_traits`: trait name, baseline, current_value,
      last_updated) — e.g. shyness, humor, warmth, directness, curiosity.
      Each trait has a **baseline** (the core identity — keeps the character
      recognizable and prevents it drifting into someone else entirely) and
      a **current_value** that can drift slowly within a bounded range
      around that baseline (e.g. baseline shyness 7/10, bounded to roam
      3-9). Traits change only via small, capped deltas — never a full
      rewrite — so evolution is gradual and can't be swung drastically by
      any single conversation.
    - **Mood (short-term, resets each session)**: a lightweight, ephemeral
      state (tired, excited, annoyed, etc.) that colors the current session
      but never gets written back into the trait table — it's context, not
      character development. This is the piece that keeps a single bad or
      unusually intense conversation from accidentally becoming a permanent
      personality shift.
    - **Write path**: reuse the same lightweight extraction step already
      driving the memory write path (the local LLM itself, a small
      reflection prompt run after each session) — extend it to also propose
      small trait deltas based on what happened in that session (e.g. a
      comfortable, successful interaction nudges shyness down a notch),
      clamped to each trait's bounded range around its baseline before
      being applied. Mood, by contrast, is set/updated live during the
      session (e.g. from sentiment of the current exchange) and simply
      discarded when the session ends — no extraction step, no persistence.
    - **Read path**: each turn's system prompt is built from
      current_value (not baseline) for every trait, plus the session's live
      mood — so the described personality reflects both where it's drifted
      to over time and how it's feeling right now, not a fixed dossier.
    - **Risk worth flagging**: letting a model self-reflect and propose its
      own trait deltas is inherently less predictable than hand-coded
      rules. The bounded range around baseline contains that unpredictability
      rather than eliminating it — it can't run away to an extreme, but it
      also isn't fully deterministic. A manual override/reset path (an admin
      command to nudge or reset a trait) is worth having for when it drifts
      somewhere undesired.
15. **Translation moves from unconditional to conditional — and even on the
    action branch, it's a narrower need than originally scoped.** The
    source diagram translates into an internal working language
    unconditionally, at ingestion, before intent classification even runs.
    That cost is pure waste on every chat-only turn; casual chat stays in
    the user's native language end-to-end. On the action branch: given the
    fixed action catalogue (item 3), infrastructure execution operates on a
    **validated typed action with structured parameters**, not on
    translated natural-language text — the catalogue call itself needs no
    translation regardless of backend. Translation is only relevant to a
    backend's own *reasoning quality* (e.g. if a chosen model's tool-use
    planning measurably performs worse given German input than English) —
    so only translate when there's a measured reason to, not by default for
    every action-branch turn. Whichever happens, **the original German
    request is always retained in the audit record** — the audit trail
    reflects what was actually said, not a lossy translation of it.
16. **Both capability backends and output modalities are pluggable — this is
    the extension point for future tools.** Adding a new *capability* (a
    backend the router can dispatch to) means registering it in the backend
    registry, not restructuring the router. Adding a new *output modality*
    (e.g. a future VTuber avatar driven by VTube Studio's WebSocket API) is a
    different kind of extension: it doesn't touch the router at all — it's a
    second consumer of the existing TTS/emotion output stream, alongside
    "play audio into the voice channel," fed by audio plus whatever
    emotion/intent metadata the personality LLM already produces.
17. **Treat Discord messages, retrieved web content, and stored memories as
    untrusted input — not just as data.** Anything that ends up in the
    LLM's context that didn't come from a trusted, authenticated user (a
    message from an untrusted guild member, scraped search results, even a
    memory entry the bot itself wrote based on past untrusted input) can
    contain adversarial instructions embedded in ordinary-looking text —
    classic indirect prompt injection. This is precisely why the fixed
    action catalogue (item 3) matters: even if injected content convinces
    the LLM to "decide" something risky is safe, there's no generic exec
    path for it to reach, and the gateway's own independent risk lookup
    doesn't care what the LLM claims. The turn-taking gate (item 10) and
    speaker/interaction authorization (items 4-5) are the other layers this
    depends on — none of them should be bypassable by anything the LLM
    merely *read*, only by what an authorized human actually said or
    clicked.
18. **Agentic coding sessions — a second, structurally distinct capability
    from the fixed action catalogue, not a variant of it.** Everything in
    item 3 assumes a small, enumerable set of pre-parameterized actions
    (`restart_service`, `delete_vm`) — that model doesn't extend to "help me
    build my side-project," which is genuinely open-ended and can't be
    pre-enumerated or per-action risk-tiered the same way. This capability is
    for a different use case entirely: talking through building an unrelated
    external app with Eco in voice, the way a user might pair-program with
    Claude Code in a text session, but voice-first and personality-driven.
    - **Flow**: Eco (the personality LLM) converses naturally, using
      short-term and long-term memory (item 13) for continuity across
      sessions on the same project, until the user's intent is concrete
      enough to act on. She then composes an explicit engineering prompt
      and dispatches it — via the Capability Router's backend registry
      (item 16), as its own registered backend — to a full Claude Code
      agent session with real tool access (Edit/Write/Bash), not the
      `--restricted`/`--strict-mcp-config` mode used for Phase 2a's
      classification-only calls. Progress and completion are reported back
      through the same async `actions`-table/worker/outbox pattern (below)
      that already exists for infra actions, since a real coding task can
      run long and needs status updates, not a synchronous voice-blocking
      wait.
    - **Containment is by scope, not by a fixed catalogue.** Since the task
      itself can't be enumerated in advance, the safety property has to come
      from *where* the agent is allowed to act: each enrolled project gets
      its own dedicated workspace (e.g. a separate git worktree/checkout),
      and the session's tool access is confined to that directory only. It
      must never be able to reach this project's own repos
      (`ai-server-management`, `ProjectEco`), their secrets, or the
      Proxmox/k8s credentials the Action Execution Gateway holds — that
      separation needs to be structural (a different credential set, a
      different filesystem root), not a prompt instruction the agent could
      be talked out of.
    - **Human review before anything merges — the same branch-based
      workflow this project already requires of itself.** The agent session
      works on a branch and stops there; it does not autonomously merge to
      main or publish a release. The user reviews the actual diff (or has
      Eco walk through it in voice) before anything ships, mirroring the
      "create branch → ask user to verify → only then merge" flow already
      mandated for every project's own `CLAUDE.md` in this whole effort.
    - Still gated on Phase 2b's personality LLM (item 13/14) for the
      conversational front end — recorded here as a planned capability-
      registry entry, not a Phase 2a build item.

## Latency budget: is real-time conversation actually feasible?

Estimated, based on the chosen stack (faster-whisper/whisper.cpp STT, a
quantized 7-13B local personality LLM via vLLM-ROCm/llama.cpp, Piper/XTTS,
Claude Code for actions), assuming models stay resident on `ai-gpu-vm` (no
cold-start reloads) and requests aren't queued behind other GPU work:

| Turn type | Rough total latency |
|---|---|
| Chat only: VAD → STT → context fetch → local-LLM reply → safety scan → TTS | **~1.3-3.1s with Piper** (~2.1-5.6s with XTTS — a real trade-off, not just a quality knob) |
| Action: ack → Claude Code (or other backend) plan + per-step round trips (2-10s each) → the real infra operation (seconds to minutes) → optional human-approval wait (unbounded) → completion announcement | **Tens of seconds to several minutes** — dominated by real infra work and approval wait, not AI inference |

**Verdict**: pure conversation can feel responsive (comparable to Alexa/Google
Assistant) if models are kept warm and Piper is the default TTS. Action turns
are inherently slow and open-ended once a human approval is involved — there
is no way to make that fast. This means the conversation **must never block**
on an in-flight action; see concurrency below, which is a hard requirement for
the assistant to be usable, not an optional refinement.

**These numbers are targets to benchmark once real hardware and models exist,
not reliable estimates** — they're derived from published figures for the
chosen tools under favorable assumptions (warm models, no GPU contention),
not from anything measured on this project's actual GPU. Treat them as "is
this stack even in the right ballpark" reasoning, not a commitment.

## Concurrency, killswitch, and logging — one shared mechanism

These three requirements turn out to be the same underlying piece of
infrastructure: a **persistent, live-queryable set of Postgres tables**, plus
a background worker that drives whichever backend the router selected,
decoupled from the voice turn loop.

**Database structure is four tables, not one, so state, plan, audit, and
delivery don't get conflated:**
- `actions` — current state only: `id, session_id, request, backend, status:
  pending/running/awaiting_approval/done/failed/cancelled/
  unknown_requires_reconciliation, current_plan_step, lease_owner,
  lease_expires_at, heartbeat_at, created_at, updated_at`.
- `action_steps` — the planned and executed steps for an action, so a
  multi-step plan's progress is queryable independent of the action's
  overall status.
- `action_events` — append-only audit events (every intent classification,
  tool-call proposal, permission decision, approval/denial with identity,
  and final response), correlated by session ID. This is the durable audit
  trail; nothing here is ever mutated or deleted.
- `outbox` — Discord/TTS notifications still awaiting delivery. `LISTEN/
  NOTIFY` (below) is a fast wake-up hint, but the outbox row is what
  actually guarantees a notification survives a restart and gets
  delivered, replayed if needed — the hint and the durable delivery
  record are different jobs. **This is at-least-once delivery, not
  exactly-once** — confirmed live in ProjectEco's implementation: a crash
  in the narrow window between the message actually being sent and the
  row being marked delivered causes a real duplicate send on the next
  poll, since there's no Discord-side idempotency key to dedupe against
  (the regular channel-message API doesn't support one). Accepted as a
  known tradeoff rather than fixed for now — the two alternatives aren't
  actually better: marking delivered *before* sending would flip the
  failure mode from "occasional duplicate" to "occasional silent loss,"
  which is worse for an audit-oriented system, since a lost completion
  message means a finished action might go unnoticed entirely. Revisit
  only if actual usage shows duplicates are a real nuisance, not
  preemptively.

- **Async action execution**: when intent classification routes to the
  action path, the orchestrator (a) immediately gives a short verbal
  acknowledgement via the normal fast conversational path, (b) inserts a row
  into `actions` and **returns control to the voice loop immediately** — the
  user can keep talking about anything else right away, (c) a separate
  background worker picks up the job and drives whichever backend the router
  chose (invoking the Action Execution Gateway for any real infra step,
  regardless of backend), recording each step in `action_steps` and every
  notable event in `action_events` as it progresses, (d) on reaching a
  terminal state or an approval gate, it writes a row to `outbox` and fires a
  Postgres `LISTEN/NOTIFY` event (no need for a heavier queue like Kafka/
  RabbitMQ at this scale) that the voice-session handler picks up and speaks
  proactively into the channel — e.g. "the VM is ready" — even if unrelated
  conversation happened in between.
- **`LISTEN/NOTIFY` is only a wake-up mechanism, not the source of truth.**
  Postgres `NOTIFY` is fire-and-forget — if the listening process is down or
  restarting at the exact moment it fires, the event is lost forever, no
  replay. The actual correctness mechanism is the `actions` table itself:
  the worker reconciles against row status on a regular cycle regardless of
  whether a notification arrived, so a missed `NOTIFY` just means the update
  is noticed on the next reconciliation pass instead of instantly, not lost.
  On top of that, add **job leases and heartbeats**: a worker claims a row
  with a lease expiry and updates a heartbeat/`last_seen` column while
  processing it; if a worker crashes mid-action, another reconciliation pass
  (by the same worker after restart, or a different one) detects a `running`
  row with a stale heartbeat and re-claims it, rather than leaving it stuck
  forever with no visibility. Combined with the **action idempotency**
  requirement already noted in Open Questions (an idempotency key or
  "did this already happen?" check before retrying), this means a worker
  restart mid-action is a recoverable event, not a silent failure or a
  duplicated infra operation.
- **`action_events` is the log/observability system**: "what's happening
  right now" is a query against `actions` joined with `action_steps`; "what
  happened and who approved it" is a query against `action_events`. The user
  can also ask the bot conversationally ("what's the VM doing?") and it
  answers from these tables directly, without re-invoking a backend just to
  check status. Pair it with a simple live status page/panel — reuse the
  existing `monitoring-proxmox-k8s` dashboard pattern already running on
  this cluster rather than standing up a separate observability stack
  (Loki/Grafana would be overkill at this scale; an optional later upgrade
  only). Every intent classification, tool-call proposal, permission
  decision (who approved what), and final response gets an `action_events`
  row, correlated by session ID, so a full conversation+action thread is
  reconstructable — but **not every casual voice transcript gets logged
  permanently**. Given casual chat is open to anyone in the voice channel,
  not just trusted users (see item 4), indefinitely storing verbatim
  transcripts of guests' conversations is a real privacy concern with no
  corresponding benefit. Action-relevant and security-relevant entries (what
  was requested, who approved what, what executed) get full permanent
  logging since audit value there is high; casual-chat transcript rows get
  a bounded retention window, consistent with the long-term memory design
  (item 13) already preferring rolling summaries over raw transcripts for
  the same reason.
- **Killswitch, three explicit levels** (a single vague "stop button" isn't
  enough — these answer different questions):
  1. `/agent stop <action-id>` — cancel one specific in-flight action: marks
     the row `cancelled`, signals the active backend to abort between steps,
     and the Action Execution Gateway denies any further calls for that
     action even if one is mid-loop. A tool call *already dispatched* (e.g. a
     `qm clone` already sent to Proxmox) can't be un-sent — this stops the
     agent from taking further steps, it doesn't rewind real infra work
     already in flight.
  2. `/agent pause` — global freeze: the Action Execution Gateway auto-denies
     all new actions (safe or risky, from any backend) until unpaused.
     Conversation keeps working normally; existing in-flight actions may
     finish their current step but take no new ones. This is the "something
     feels off, stop doing infra stuff but keep talking to me" switch.
  3. **Full stop — must actually stop action execution, not just make the
     bot leave voice.** Scaling only `agent-orchestrator` to zero
     (`kubectl scale deploy/agent-orchestrator --replicas=0`) is
     insufficient on its own if the worker and the Action Execution Gateway
     are separate services (which they are) — they could keep processing
     already-queued or in-flight actions after the orchestrator is gone. A
     complete emergency stop: (a) writes a **persistent global-pause flag**
     into the gateway's own state (a row in Postgres, checked on every
     request) so it rejects all new action executions — persistent meaning
     it survives a service or database restart and stays active until
     someone explicitly clears it, not just an in-memory flag; (b) scales
     the action worker to zero, not just the orchestrator; (c) scales the
     orchestrator to zero; (d) optionally revokes the gateway's active
     execution credentials or blocks its management-network access at the
     firewall, for the case where the compromise might be in the gateway
     itself. Critically, **this procedure must work via Proxmox/SSH
     directly, independent of Discord, the bot's own event loop, Postgres
     `LISTEN/NOTIFY`, the normal agent application, or the model backend**
     — if any of those is what's compromised or broken, the full stop still
     has to work.
  Levels 1-2 should be reachable via a Discord slash command handled by a
  small, always-responsive listener that does **not** share an event loop/
  queue with the potentially-busy action-execution worker, so the killswitch
  stays responsive even when something's gone wrong elsewhere. Level 3 is
  deliberately infrastructure-level and does not depend on the app being
  healthy at all.

## Scaling model

Two distinct scaling questions get conflated easily — worth separating them
explicitly:

- **Throughput (many concurrent requests) vs. latency (one slow request).**
  More pods help the former, not the latter. A single slow Google search
  finishes just as slowly whether there are 1 or 10 replicas of the search
  skill — replicas only help when *multiple* searches are happening at once
  across sessions. For the single-slow-request case, the mitigation is
  either intra-request fan-out (fire a few query variants in parallel, merge
  results) or, more importantly, leaning on the async non-blocking action
  design above so a slow action never blocks the conversation regardless of
  how long it takes to resolve.
- **CPU/IO-bound skills scale horizontally for free.** Web search, most n8n
  workflows, and other direct-tool-call skills are already independent
  services the router calls over HTTP — deploying each as its own k3s
  Deployment + Service + HPA (scaling on CPU or request-queue depth) is a
  deploy-pattern choice, not an architecture change. Skills scale
  independently of each other (e.g. `web-search-skill` can run 5 replicas
  while `restart-minecraft-skill` stays at 1).
- **GPU-bound services do not scale the same way.** The local LLM, STT, and
  TTS all run on the single GPU in `ai-gpu-vm`. Running multiple replicas of
  any of them on one GPU doesn't multiply throughput — the GPU itself is the
  bottleneck. Scaling these later means more GPU capacity or a request queue
  in front of a single instance, not horizontal pod replication. Don't apply
  the "just add replicas" pattern here.
- **Expected concurrency is low today** (a home system, a handful of trusted
  users), so per-skill HPA is a documented default pattern for later, not a
  Phase 2a build requirement — the value right now is keeping skills as
  independent services so scaling is a config change if/when it's needed,
  not a redesign.

## Phased build order

- **Phase 2a (no GPU needed, can start any time) — priority order matters
  within this phase, and a specific vertical slice comes first.** The
  safest possible starting point, concrete enough to build immediately:

  ```
  Discord text command → typed vm_status action → Action Execution Gateway
  → read-only Proxmox token → action + action_events records
  → response in Discord
  ```

  This exercises the whole chokepoint (catalogue, gateway, credential
  custody, audit logging) with a read-only action before any write/
  destructive capability exists at all. From there, in order:
  1. Minecraft status lookup (another read-only action).
  2. Minecraft restart as an allowlisted, reversible action — the first
     action with a real side effect, but a safe, recoverable one.
  3. Worker crash and reconciliation tests (kill the worker mid-action,
     confirm the lease/heartbeat mechanism recovers it correctly).
  4. Duplicate-delivery and idempotency tests (deliberately retry an
     already-completed action, confirm no duplicate resource results).
  5. Approval flow exercised against a disposable test VM (the first
     `risky`-tier, plan-hash-bound approval, end-to-end for real).
  6. Global pause and full emergency-stop tests (confirm level 2 and level
     3 of the killswitch actually halt the gateway/worker, not just the
     orchestrator).
  7. Natural-language routing (the router deciding which backend handles a
     free-form request, once the underlying action execution is trusted).
  8. GPU VM and local model services (start of Phase 2b, below).
  9. Voice conversation.
  10. Voice-triggered infrastructure actions.
  11. Long-term memory and personality evolution.

  **Idempotency, the full approval lifecycle (canonical serialization,
  nonce, expiry, atomic consumption), the corrected credential design
  (item 7), the complete killswitch (item above), and authenticated
  service-to-service networking (item 8) must all be real, working
  requirements by step 5 — not general design ideas still — before any
  approval is exercised against even a disposable test VM.** Everything
  else in the original component list (Postgres + pgvector with the four
  tables above; the authorization allowlist gate; the Capability Router's
  dispatch logic and `risk-tiers.yaml`; n8n for the deterministic-skill
  branch; the async background worker with reconciliation; the Discord
  approval-button workflow; SOPS-encrypted secrets) gets built in support
  of proving this slice, not as a separate checklist. Only after the safe
  vertical slice and its safety mechanisms are proven: start the discord.js
  bot skeleton with voice join/leave + per-user audio capture logged as a
  stub (no STT yet), and start on personality trait storage/memory content
  (items 12-14). All of this is independently testable today with text
  stand-ins for voice and the real Claude API — nothing here is GPU-gated.
- **Phase 2b (needs the GPU installed)**: create `ai-gpu-vm`, passthrough the
  GPU, re-check the RAM budget with real numbers, deploy STT/TTS as internal
  services, deploy the local personality LLM, wire the Phase 2a orchestrator
  to call them.
- **Phase 3 (needs both 2a and 2b)**: wire real audio → STT → turn-taking
  gate (addressed-to-bot / addressed-to-someone-else / ambiguous) → memory
  assembly → personality-LLM classification of "chat vs. action," branching
  into either (3A) direct reply → output-safety/secret-redaction → TTS,
  staying in the user's native language throughout, or (3B) routing to the
  typed action catalogue (item 3) — which needs no translation, since it
  operates on structured parameters, not natural-language text — with
  translation only invoked if a specific backend's own reasoning is
  measured to perform worse on German input, and the original German
  request always retained in `action_events` regardless. Play into the
  voice channel with debounced barge-in. Test with a `safe`-tier read-only
  action end-to-end before ever exercising the `risky`-tier approval loop
  for real.

## Technology choices

| Component | Choice |
|---|---|
| Capability Router + result-checking | Custom service: cost-aware dispatch across n8n/direct-tool/local-LLM/Claude Code/other-API backends |
| Complex agentic infra reasoning | Claude Agent SDK, headless mode, MCP tools — one backend among several, used only when genuinely needed |
| Deterministic skills | n8n workflows — zero LLM cost for known, repeatable tasks |
| Action execution + risk enforcement | Custom Action Execution Gateway service, fixed typed-action catalogue only (no generic exec), shared by every backend; `risk-tiers.yaml` (`safe/risky/forbidden`); approval atomically bound to a plan hash + nonce + expiry; idempotency mandatory before real writes |
| Human approval UX | Discord message components (Approve/Deny buttons carrying only an opaque ID), rendering the exact action |
| Speaker authorization | Flat allowlist of trusted Discord user IDs |
| Secrets | SOPS-encrypted files, kept out of GitHub entirely |
| Kubernetes credentials | Two-tier, held exclusively by the gateway (never distributed to backends): always-on read-only + post-approval privileged, short TTL |
| Proxmox credentials | Fixed set of narrowly-scoped tokens/roles provisioned ahead of time (`proxmox-readonly`, `proxmox-vm-power`, etc.), held exclusively by the gateway — never a dynamically-minted privileged token; no gateway token can modify users/ACLs/roles/tokens |
| Short-term memory | Redis or in-process buffer, per-session, TTL'd |
| Long-term memory + audit log | Postgres + pgvector; per-user identity fields, user inspect/correct/delete/opt-out rights; casual transcripts bounded-retention, action/security events permanent |
| Action/job state + concurrency + log | Postgres, four tables: `actions` (current state, leases/heartbeats), `action_steps` (plan progress), `action_events` (append-only audit), `outbox` (durable notification delivery); `LISTEN/NOTIFY` as a wake-up hint only |
| Killswitch | 3-tier (per-action cancel / persistent global pause in the gateway / full-stop that halts worker + gateway + orchestrator), small standalone listener, reachable via Discord slash command + infra-level fallback independent of Discord/the app/the model backend |
| Network protection | Host-firewall-restricted Proxmox API (gateway IP only) + service-to-service auth (mTLS or equivalent) as the Phase 2a baseline; VLAN segmentation as a later strengthening, not a prerequisite |
| Output safety | Structural removal of secret fields at the tool/gateway boundary (allowlisted result fields only) as the primary control; pattern/entropy scan before TTS as defense-in-depth |
| STT | whisper.cpp or faster-whisper (on `ai-gpu-vm`), behind an STT-independent VAD interface |
| TTS | Piper or XTTS (on `ai-gpu-vm`) — pick once GPU headroom is known |
| Local personality LLM | vLLM-ROCm or llama.cpp server, OpenAI-compatible API |
| Discord bot/orchestrator | Node.js: discord.js + `@discordjs/voice`, runs as a k3s Deployment alongside the router/worker/gateway/Postgres/n8n |
| GPU hosting | Dedicated Proxmox VM (`ai-gpu-vm`), not shared into k3s-node1; systemd or Docker process supervision (not k3s liveness probes) |

## Open questions (not blocking, decide later)

- Local LLM model/size and quantization — needs real VRAM numbers post-install.
- TTS engine final pick (Piper vs XTTS) — depends on GPU headroom once shared
  with the personality LLM.
- Whether an n8n instance already exists to reuse, or one needs to be stood
  up fresh for the deterministic-skill backend.
- Which additional model API(s) (ChatGPT, etc.) to actually wire up at
  Phase 2a build time vs. just leaving the backend registry pluggable for
  later.
- Which skills, if any, actually warrant a k3s HPA at Phase 2a build time vs.
  just being a plain single-replica Deployment until real usage shows a
  bottleneck.
- Whether/when a VTuber avatar output adapter gets built, and which avatar
  software (VTube Studio vs. alternatives) — noted here only as a validated
  future extension point, not a Phase 2/3 deliverable.
- Pruning/decay strategy for stale long-term memory entries (resolved
  narrative threads, outdated facts) — not needed for MVP, revisit once
  there's real usage data.
- Exact trait list and per-trait bounded ranges (how far current_value may
  roam from baseline) — needs some real usage to tune sensibly, and the
  admin override/reset command's interface (Discord slash command vs. a
  config file edit).
- Session boundary definition — what starts/ends a "session" for the
  short-term buffer and per-session mood (voice-channel join/leave? an
  inactivity timeout? does leaving and rejoining count as the same
  session?).
- A cap on cross-backend escalation (item 2) — without a max-retry/
  escalation depth, a stubborn failure could bounce through every backend
  repeatedly, which undercuts the router's whole cost-aware premise.
- Actual cost/budget tracking for paid backends (Claude Code, ChatGPT) —
  nothing currently tracks real spend or caps it; worth a budget alert or
  circuit breaker once there's real usage to size it against.
- Debounce duration for barge-in and the specific addressee-classification
  approach (name/wake-word detection vs. a lightweight LLM classifier vs.
  both) — needs real conversation testing to tune, not a value to guess at
  design time.
- Whether STT/TTS/local-LLM services on `ai-gpu-vm` run as systemd units or
  plain Docker containers (item 8) — either works, decide based on whichever
  is easier to manage alongside the ROCm driver stack once the GPU is
  actually installed.
- Whether the LAN's router/switch actually supports VLANs, to size the
  AI-network/Proxmox-management segmentation in item 8 as a Phase 2
  deliverable vs. a later hardware-dependent upgrade.
- Exact mechanism for gateway service-to-service authentication (mTLS vs.
  another strong auth scheme) — a Phase 2a requirement per item 8, exact
  implementation still to choose.
- Exact Proxmox role/permission definitions for the narrowly-scoped tokens
  in item 7 (`proxmox-vm-power`, `proxmox-vm-create-in-agent-pool`, etc.) —
  needs Proxmox's actual privilege/role system mapped out, not just named.
- The live `kubernetes-dashboard` `admin-user` ClusterRoleBinding to
  `cluster-admin`, confirmed present on the running cluster — decision
  made 2026-09-01 to leave it as-is for now; revisit before the Phase 2a
  Action Execution Gateway goes live, since that's exactly the situation
  this doc's credential design guards against.
- Outbox at-least-once delivery (confirmed via live test, 2026-09-02: a
  crash between send and mark-delivered causes a real duplicate Discord
  message) — accepted for now, see the outbox item above. Revisit with a
  claim/confirm mechanism only if actual duplicate messages turn out to
  be a real nuisance in practice, not preemptively.
- Agentic coding sessions (item 18): how a project gets "enrolled" (manual
  setup per project vs. some registration command), whether the agent opens
  an actual GitHub PR for review or just leaves a branch pushed for the user
  to inspect locally, and how much autonomy it has within its own turn
  (e.g. can it run tests/build commands unattended, or does every command
  need a check-in) — needs real usage on a real side-project to size
  sensibly, not a value to guess at design time.
