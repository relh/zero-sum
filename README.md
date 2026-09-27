# Battle Royal

A battle-royale Coworld: 8 teams of 2 — 16 contestants, one policy container per agent — spawn empty-handed on a pedestal ring around a loot-stocked central Fortress. Countdown, ignition fireworks, then a scramble: the best gear sits in the most dangerous place. A shrinking safe zone and scripted hazards force the fight; sponsors spend softcoin to airdrop supplies to their own team; the last contestant standing wins. Every death is a black firework.

Built in Nim on the [bitworld](https://github.com/Metta-AI/bitworld) engine library (see NOTICE), packaged and certified as a Coworld for the [coworld](https://github.com/Metta-AI/coworld) platform.

- `DESIGN.md` — the complete v1 design: arena, items, combat, stats, zone, sponsor economy, protocols, scoring, artifacts, determinism.
- `docs/PLATFORM_FACTS.md` — file:line evidence base for every engine/platform contract claim.
- `docs/recon/` — Phase A reconnaissance reports.
- `src/battle_royal/` — deterministic sim.
- `game/` — Coworld runnable adapter and shared live/static presentation.
- `player/` — baseline player.
- `tests/` — determinism, stat validation, scoring, softcoin accounting.

Match: 24 Hz, hard cap 9,120 ticks (6:20). Protocol: `battle_royal.player.v1` (JSON over WS). Live and static replay presentation: sprite_v1.

> [!CAUTION]
> **Do not upload until the platform-side rename is confirmed.** The manifest
> templates now carry `game.name` `battle-royal` / `battle-royal-duos`, but the
> published Coworld is still registered under `zero-sum`.
>
> **`game.name` is the upload-time ownership key: the first authenticated upload
> of a name claims that name** (`docs/PLATFORM_FACTS.md`, "the first
> authenticated upload of a `game.name` claims name ownership"). Running
> `coworld build` + `upload-coworld` against these templates today would not
> rename anything — it would mint a **brand-new Coworld with zero version
> history**, stranding the `0.1.9 → 0.1.18` chain and its league behind the old
> name. The Progress / counterfactual-evals comparison needs a name that has
> already played, so a fresh name silently produces no comparison at all.
>
> An in-place rename of the Coworld rows and the league has been requested from
> the platform team and is **not yet confirmed**. Until it is:
>
> - **Hold all uploads.**
> - If something must ship urgently, build with `game.name` temporarily reverted
>   to `zero-sum` / `zero-sum-duos` — ship under the old name and rename later.
> - Delete this block once the platform confirms the rename.
>
> Also wire-visible at the next canonical upload: the protocol id is now
> `battle_royal.player.v1` (was `zero_sum.player.v1`) and the replay magic is
> `BATTLE_ROYAL_FRAMES` (legacy `ZERO_SUM_FRAMES` still parses). Third-party
> policies pinning the old protocol string will break — say so in the upload
> announcement.

## League profiles

`python tools/gen_manifest.py` generates two publishable templates from the
same game image:

- `coworld_manifest_template.json` (`battle-royal`) is the Solo profile. Each
  external seat owns one contestant and receives that contestant's score.
- `coworld_manifest_duos_template.json` (`battle-royal-duos`) is the self-paired
  Duos profile. Use platform `team_n` seating with `team_count: 8`; external
  seats `i` and `i+8` are remapped onto the adjacent internal team
  `(2i, 2i+1)`, and both seats receive that team's combined score. The
  platform's per-policy mean therefore equals the requested team total.

The two names are separate because a Coworld league seed is unique by Coworld
name. Build the Duos package with explicit paths so it does not overwrite the
Solo artifact:

```bash
uv run coworld build --project . --version <version> \
  --template coworld_manifest_duos_template.json \
  --output dist/duos/coworld_manifest.json
```

Status: Phase C (implementation) in progress.

## Training

Compile `tools/training_bridge.nim` with the pinned Nimby dependencies:

```bash
nim c -d:release --hints:off -o:/tmp/battle-royal-training-bridge tools/training_bridge.nim
python3 tools/test_training_bridge.py /tmp/battle-royal-training-bridge
```

The persistent JSONL bridge controls one seeded seat against the ordinary survival
policy. Numeric decisions contain 357 values, 29 action slots, and game-owned legal
masks. Pass the compiled bridge to Metta's current `recipes.external.coworld` with
`players=1`, `max_decisions=9120`, and a finite timestep budget. The default runs
the full match; a single integer argument explicitly selects a shorter curriculum.
Native PufferLib requires a reserved NVIDIA GPU.

The semantic view preserves the native private observation and visible chat.
Metta post-training can collect complete teacher episodes from the same bridge.
Its independent `say` request supports broadcast or direct-message speech through
the game's validator, without consuming the pending action decision. Speech is
rate-limited to one message per 24 ticks and sanitized by the game's normal rules.
Opponent actions and messages come from the same policy used by ordinary players.
The simulation reaches match end before emitting terminal scores, even when the
learner dies earlier.

The numeric curriculum uses the bundled stat allocation and has no generated speech.
Its codec in `player/numeric_codec.nim` also reads the ordinary private player view.
`player/numeric.nim` sends that encoding to a frozen Metta policy service and sends
the selected action through the normal player socket. The player owns inference;
the game retains validation, scoring, results, and replay.

```bash
nim c -d:release --hints:off -o:/tmp/battle-royal-numeric-player player/numeric.nim
metta-choice-serve /path/to/exported-policy --port 18888
COWORLD_PLAYER_WS_URL='ws://localhost:8080/player?slot=0&token=seat-token' \
  PLAYER_NUMERIC_URL=http://localhost:18888/actions /tmp/battle-royal-numeric-player
```

One service process owns one episode and seat. Restart it between episodes.
The player uses the bundled stat allocation and ordinary scripted speech.
Numeric weights select actions; generated speech remains a separate policy path.

Historical Metta RL optimizer proof is recorded in PR #26; its retired recipe is not
a current entry point. Training does not authorize an upload or the pending rename.
