# ZPause T5

**Synced co-op pause for Black Ops Zombies (Plutonium T5)**

by Xep

[**Download the latest release**](https://github.com/Xeptix/ZPauseT5/releases/latest)

A port of [ZPause](https://github.com/Xeptix/ZPause), the Black Ops II pause mod, to
Black Ops 1. Same design, same settings, same version numbering — v1.3 here is feature
equal to v1.3 there.

Any player can pause. Any player can unpause. The state lives on `level`, so it's
identical for everyone — there's no per-client state that can desync.

- Zombies stop where they are, and stop spawning
- Players are locked and can't be hurt
- Powerup timers, effect countdowns and bleedout all hold
- Resumes on a 3‑2‑1 countdown with a short grace period

---

## Requirements

Plutonium T5 (Black Ops), zombies. No other mods or dependencies.

**Only the host needs this file.** Every part of ZPause runs on the host and reaches
everyone else as ordinary server-to-client traffic — the freeze, the invulnerability, the
HUD, the vote tally, the sounds. Players joining your game install nothing.

---

## Install

Copy the **`Plutonium`** folder from the download into:

```
%localappdata%
```

It mirrors your existing `%localappdata%\Plutonium` exactly, so Windows will ask whether
to merge — say yes. The only thing it replaces is an older `zpause.gsc`.

That puts the file here:

```
%localappdata%\Plutonium\storage\t5\raw\scripts\sp\zpause.gsc
```

**`sp`, not `zm`** — Black Ops 1 zombies runs on the singleplayer script tree. That's the
same folder Plutonium's own zombies scripts live in.

### Or run the installer

`install.bat` in the download does the same copy for you. It lists what it's about to
install, asks once, and copies — no deletes, no downloads, nothing else touched. Extract
the zip first and run it from the extracted folder; running it from inside Windows' zip
viewer won't work.

It's optional. Dragging the `Plutonium` folder across yourself is identical.


There's no mod-folder version of this one. Plutonium's `mods` folder and its in-game Mods
menu are Black Ops II features; T5 has neither, so the script drop-in is the whole
delivery.

You don't need to restart the game to reload a script — just end the current game and
start a new one.

---

## Usage

| Action | Input |
|---|---|
| Pause / unpause | hold **crouch + melee** together for ~0.3s |
| Vote yes, while a vote is open | the same combo |
| Vote no, while a vote is open | hold **jump + melee** |

Crouching *or* prone counts, by any binding — Black Ops 1 splits crouch across four
separate binds and `CHANGE STANCE` goes prone when held, so the script reads your stance
rather than a key.

The combo keeps working while you're frozen: `freezecontrols()` blocks movement and
weapon use, but button state still reaches the server. That's what lets a frozen player
resume.

**There are no chat commands.** Black Ops 1 has no `say` callback for a script to bind to,
so unlike the Black Ops II version there's no `!pause` or `!yes`. Everything is on the
combos, which is why the down-state combos below matter.

### While you're down

You can't crouch from the floor, and once you've bled out the engine stops delivering
those buttons at all. Downed and spectating players switch to:

| Action | Input |
|---|---|
| Pause / unpause / vote yes | hold **use + aim** |
| Vote no | hold **use + fire** |

The HUD shows a `while down:` line whenever anybody is in that state, so nobody has to
remember it.

---

## Voting

Off by default. `zp_vote 1` and a pause has to carry the room instead of any one player
stopping the game.

Calling a vote is the same action as pausing. The vote runs 30 seconds and everyone gets
a tally: the count, the clock, and every player with how they voted.

The bar is whichever is higher, `zp_vote_min` or `zp_vote_percent` of the players in the
game, then clamped to how many are actually present — so a lobby can't set a threshold
nobody there can clear, and solo play skips the vote entirely. With the defaults that's
2 of 2, 2 of 3, 3 of 4.

A vote ends the moment it's decided either way: enough yeses to pass, or enough noes that
everyone left couldn't carry it. Disconnects take their vote with them. A failed vote
locks out the next one briefly so it can't be spammed.

Resuming doesn't need a vote by default, so one AFK player can't strand everyone in a
paused game — `zp_vote_unpause 1` if you want both directions voted. `zp_vote_hold 1`
freezes the game while the vote runs and puts it back if it fails.

---

## Configuration

Every setting is at the top of the file, and each one is also a dvar of the same name.
The script creates each dvar with its default on load, so you can set them straight from
the console:

```bash
zp_countdown 5
```

The config is re-read whenever a pause is requested, so a change takes effect on the
**next pause** — no map restart needed.

| Dvar | Default | What it does |
|---|---|---|
| `zp_button_combo` | `1` | Enable the button combos. |
| `zp_combo` | `crouch_melee` | Pause combo: `crouch_melee`, `jump_use`, `jump_melee`, `use_melee`, `ads_melee`, `ads_use`, `throw_use`. |
| `zp_button_hold_time` | `0.3` | How long a combo must be held. |
| `zp_combo_dead` | `use_ads` | Combo used while downed or spectating. `""` = no button in that state. |
| `zp_vote_no_combo_dead` | `use_attack` | The same, for a no vote. |
| `zp_vote` | `0` | Put pauses to a vote. |
| `zp_vote_min` | `2` | Minimum yes votes, whatever the player count. |
| `zp_vote_percent` | `51` | Percent of players who must vote yes. |
| `zp_vote_time` | `30` | Seconds a vote stays open. |
| `zp_vote_unpause` | `0` | Resuming needs a vote too. |
| `zp_vote_hold` | `0` | Freeze the game while the vote runs, and resume if it fails. |
| `zp_vote_initiator_yes` | `1` | Whoever called the vote counts as a yes. |
| `zp_vote_lockout` | `10` | Seconds before another vote can be called after one fails. |
| `zp_vote_alive_only` | `1` | Leave bled-out spectators out of the threshold and the count. |
| `zp_vote_hud` | `1` | Show the vote tally on screen. |
| `zp_vote_show_voters` | `1` | List each player and how they voted. |
| `zp_vote_result_time` | `2` | Seconds the result stands on the tally afterwards. |
| `zp_vote_no_combo` | `jump_melee` | Combo for a no vote. |
| `zp_countdown` | `3` | Seconds of 3‑2‑1 before play resumes. |
| `zp_grace` | `2` | Seconds of invulnerability after resuming. |
| `zp_cooldown` | `2` | Minimum seconds between toggles. |
| `zp_max_pause_time` | `0` | Auto-resume after N seconds. `0` = unlimited. |
| `zp_drift_guard` | `1` | Snap back any AI that still manages to move. |
| `zp_stop_anims` | `1` | Cut scripted animations, so zombies can't finish tearing a barrier through the pause. |
| `zp_godmode` | `1` | Make players invulnerable while paused. |
| `zp_control_guard` | `1` | Re-apply the player freeze every tick. |
| `zp_freeze_bleedout` | `1` | Stop downed players bleeding out. |
| `zp_freeze_powerups` | `1` | Stop ground powerups timing out. |
| `zp_freeze_effects` | `1` | Hold the insta-kill, double points, fire sale, bonfire, tesla and minigun timers. |
| `zp_silence_zombies` | `1` | Stop zombies growling while paused. |
| `zp_show_hint` | `1` | Tell players how to pause when they spawn. |
| `zp_hud_timer` | `1` | Show who paused and how long it's been. |
| `zp_hud_position` | `center` | Where the pause banner sits: `top`, `center`, `middle`, `bottom`, `left`, `right`. |
| `zp_vote_hud_position` | `top` | Where the vote tally sits. |
| `zp_hud_glow` | `1` | Black glow behind the HUD text. |
| `zp_hud_binds` | `1` | Draw combos as each player's bound buttons instead of words. |
| `zp_hud_panel` | `0` | Black slab behind the whole block. |
| `zp_hud_panel_alpha` | `0.45` | How opaque that slab is. |
| `zp_hud_panel_width` | `340` | How wide it is, in HUD units. |
| `zp_blackout` | `0` | Black out everyone's screen while paused (anti-scouting). |
| `zp_blur` | `1` | Blur everyone's screen while paused. |
| `zp_blur_amount` | `1.5` | Blur strength. `4` is the blur the game runs when you buy a perk. |
| `zp_pause_sound` | `zmb_box_poof` | Played when the game is paused. `""` = silent. |
| `zp_countdown_sound` | `zmb_bolt` | Played on each countdown tick. |
| `zp_resume_sound` | `zmb_perks_power_on` | Played when play resumes. |

### The pause clock is in minutes

`zp_hud_timer` reports in minutes — `under a minute`, `3 minutes`, `over an hour` —
rather than the live mm:ss the Black Ops II version shows.

That's a hard constraint, not a shortcut. Black Ops 1 has no HUD timer element, so a
clock has to be drawn as text, and every distinct string costs a configstring. A ticking
second counter burns one a second until the pool runs dry and drops the server. Minutes
bound the whole set to about sixty strings, all reused.

---

## How it works

**Black Ops II ships a working full-game pause** — it's what runs during a host
migration — and the original ZPause is built on that recipe. Black Ops 1 has no host
migration in zombies and no `disablezombies()` builtin to go with it, so the engine-level
AI freeze simply isn't available here.

Everything else carries over, and the AI freeze is done in script instead:

- **`flag_clear("spawn_zombies")`** is the flag the spawn loop actually blocks on, so
  spawning stops at the source.
- **The AI enforcer** holds `ignoreall`, pins every goal to where the zombie is standing,
  and snaps back anything that drifts. On Black Ops II this is a safety net around the
  engine freeze; here it *is* the freeze.
- **`zp_stop_anims`** cancels scripted animations, because a zombie tearing a barrier is
  driven by its animation rather than by pathing — goals and positions don't govern it.
  Everything cancelled is released again on resume, or the zombie would stand there for
  the rest of the game.
- **The stuck-zombie watchdog.** `round_spawn_failsafe()` kills any zombie that hasn't
  moved 24 units in 30 seconds, assuming it's stuck outside the playspace — and a paused
  zombie trips it every time. ZPause keeps the barrier-chunk timestamp fresh, which the
  watchdog honours, so it loops harmlessly instead of firing.
- **Ground powerups.** `powerup_timeout()` is a plain `wait()` chain and can't be paused,
  so the thread is cut and restarted on resume.
- **Powerup effects.** Every timed powerup keeps an `_on` flag and a `_time` countdown;
  pinning the countdowns holds all six on-screen timers at once. Insta-kill and double
  points also run a plain `wait( 30 )` underneath, so a bounded thread holds them on for
  whatever the frozen countdown says is left.
- **Bleedout** is pinned so a downed player doesn't bleed out.
- **Late joiners and respawns** are frozen on spawn, and everything is torn down on
  `end_game` so nobody is left frozen at the scoreboard.

---

## Notes

- **Zombies stand still rather than freeze solid.** Their animation is cancelled rather
  than frozen; a true animation freeze isn't reachable from server-side GSC.
- **Scripted rides keep running.** Pause mid-ride and it finishes underneath the pause —
  `zp_control_guard` only stops it handing your controls back early.
- **Not held:** the magic box close timer, teleporter cooldowns, trap durations and
  Easter egg step timers.

---

## Ports

| Game | Repo |
|---|---|
| Black Ops III (T7) | [ZPauseT7](https://github.com/Xeptix/ZPauseT7) |
| Black Ops II (T6) | [ZPause](https://github.com/Xeptix/ZPause) |
| Black Ops (T5) | ZPauseT5 — you are here |
| World at War (T4) | [ZPauseT4](https://github.com/Xeptix/ZPauseT4) |

Versions are kept in step: the same version number means the same feature set, allowing
for what each engine can actually do.

**All three in one download.** The
[Treyarch Bundle](https://github.com/Xeptix/ZPause/releases/latest) is laid out in
Plutonium's storage folder structure — drop it into `%localappdata%\Plutonium`, say yes to
the merge, and it installs whichever of the three games you have. Delete the folders for
the ones you don't.

---

## Changelog

### v1.3

First release. Feature equal to ZPause v1.3 for Black Ops II, except where the engine
doesn't allow it:

- **No chat commands** — Black Ops 1 has no `say` callback, so everything is on the button
  combos.
- **No match clock hold** — Black Ops 1 zombies has no match timer.
- **The pause clock is minute-granular** rather than live mm:ss, for the configstring
  reason above.
- **`zp_stop_anims` is new here**, and has no counterpart in the Black Ops II build, which
  gets the same result from the engine-level freeze.

---

## Credits

- **Xep** — author
- **Treyarch** — `_zombiemode.gsc`
- **[plutoniummod/t5-scripts](https://github.com/plutoniummod/t5-scripts)** — stock T5
  script reference
