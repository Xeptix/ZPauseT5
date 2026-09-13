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

The download has an **`installer`** folder, one for each system:

```
installer\windows\install.bat
installer/linux/install.sh
```

That is the ZPause Manager, and it is the same one in every ZPause download: it knows all
five games, finds whichever you have — Plutonium under `%localappdata%`, Steam's folder
and every drive; Black Ops III and Black Ops 4 wherever Steam or you put them — and asks
you to point at a folder only if it can't. Pick a game it has no files for and it offers
to fetch that game's release from GitHub, so a copy kept on your PC can install a game you
buy later.

Run it and it offers to install straight away — pressing Enter is the whole job. Press
`m` instead and you get the menu, which can:

- **install or update** ZPause — it lists what it is about to write, shows the changelog
  for the version you are about to get, and asks once
- show **what's installed**, and which version each copy is
- **configure ZPause** — every setting, grouped the way the script groups them, each with
  its default and a one-line description of what it does. See below.
- **remove** ZPause again
- **check GitHub** for a newer release and download it, with a progress bar
- **install a different version** — every download it makes is kept, so going back to an
  older build is the same two keystrokes as going forward. It can list what GitHub has and
  fetch any of those too.
- **put back a file it replaced** — it copies out whatever it is about to overwrite, so an
  install can be undone even over a script you had edited yourself
- **check my setup** — one key that looks for the handful of things that actually go
  wrong: copies at different versions, a script path your build does not read, files
  something has edited since they were installed, settings that never reached the game
- **keep itself** on your PC with a Desktop or Start-menu shortcut, so you never have to
  go looking for the download again

Nothing in that keep-list is ever deleted behind your back. After a download it shows what
it is holding and offers to clear the older ones out — answering no keeps them all. It
also writes a plain-text log of everything it installs or removes.

### Configuring it from the installer

Every setting is a dvar, and the config editor is a way to set them without touching a
console. It reads the settings out of the script itself, so the list is always right for
the version you have, with the description of each one from the table below.

Saving writes a **`zpause.cfg`** — plain `set zp_vote "1"` lines, which is exactly what a
dedicated server execs, so it is also the file to send someone or reuse on another PC —
and puts the values into the installed script, so they take effect with no console step.
You can pick either or both. Your settings are re-applied automatically after an update, so
a new version never quietly resets them.

Settings that take a fixed set of values offer that list rather than a blank prompt, so a
typo cannot leave you with a combo the game silently ignores. Type a setting's name at any
config screen to jump straight to it. You can keep several **profiles** — a solo one and a
server one, say — and switch between them; each is its own shareable cfg. And when an
update changes a default you had been getting implicitly, it says so before installing.

### Checksums

Every download from v1.4 on carries a **`SHA256SUMS`**, and the installer checks the whole
download against it before touching anything. It is a plain coreutils manifest, so you can
check it yourself in the extracted folder:

```bash
sha256sum -c SHA256SUMS
```

### Without the menu

```
install.bat -Install -Yes        install, asking nothing
install.bat -Uninstall -Yes      remove every copy it can find
install.bat -Find                show what it detects, change nothing
```

`install.sh` takes the same things as `--install --yes`, `--uninstall --yes` and `--find`.

It asks before it touches the network, every run — answer no and it makes no connection
at all. It only ever writes or removes `zpause.gsc`, at paths it found itself: no deletes,
no folders removed, nothing else touched.

Extract the zip first and run it from the extracted folder; running it from inside
Windows' zip viewer won't work.

It's optional. Dragging the `Plutonium` folder across yourself is identical.

**On Linux**, `installer/linux/install.sh` does all of the same things, and knows where
Plutonium ends up when it is running under Wine or Proton — DeckOps' compatdata prefix
on a Steam Deck, Heroic's shared prefix, Lutris, Bottles, plain `~/.wine`, and the Flatpak
version of each. SteamOS SD cards are searched too. Tested against SteamOS, CachyOS and
Bazzite layouts.

```bash
./install.sh          # or  bash install.sh
./install.sh --find   # show what it detects, change nothing
```

### On a Steam Deck

Switch to Desktop Mode and use **`installer/linux/Install ZPause.desktop`** —
double-clicking it runs the installer in a terminal window, which is how most Deck tools
are launched.

KDE will not run a desktop entry until you allow it, once:

1. Right-click `Install ZPause.desktop` → **Properties**
2. **Permissions** → tick **Is executable** → **OK**
3. Double-click it

It finds Plutonium wherever DeckOps put it — the game's own Proton prefix under
`compatdata`, or Heroic's shared prefix on an LCD Deck — including on an SD card. The
manager can put a shortcut in your application menu too, so next time it is one click.




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

### Who decides

Five settings answer the same question — who may pause, and who has to agree. They can all
be on at once, so this is the order the script applies them in.

**Asking to pause:**

| | Setting | What happens |
|---|---|---|
| 1 | `zp_host_only` | Anybody but the host is turned away here. Nothing below runs for them. |
| 2 | — | Refused while the game is still starting. |
| 3 | `zp_round_pause` | If a pause is already waiting for the round to end, asking again calls it off. |
| 4 | `zp_max_pauses` | Refused once the match has spent its budget. |
| 5 | `zp_cooldown` | Refused if the last pause was too recent. |
| 6 | `zp_host_approve` | A non-host's ask goes to the host to answer. **Takes precedence over `zp_vote`.** |
| 7 | `zp_vote` | Otherwise, with voting on, it goes to a vote. |
| 8 | `zp_round_pause` | Once it is agreed — outright, approved or voted — it waits for the round to end instead of happening now. |

**Asking to resume:**

| | Setting | What happens |
|---|---|---|
| 1 | `zp_host_only` | Anybody but the host is turned away. |
| 2 | — | With a vote already open, the input is a yes instead. |
| 3 | `zp_cooldown` | Refused if the last toggle was too recent. |
| 4 | `zp_ready_check` | The input marks you ready rather than resuming. **Takes precedence over `zp_vote_unpause`.** |
| 5 | `zp_vote_unpause` | Otherwise, with `zp_vote` on as well, it goes to a vote. |

Three things sit outside all of that:

- **`zp_max_pause_time` ends a pause whatever else is set.** It is the way out of a ready
  check nobody answers, or a request the host never sees. Leave it at `0` and there is no
  way out but somebody pressing something.
- **A pause nobody asked for skips the lot.** `zp_pause_on_disconnect` pauses immediately:
  it does not wait for the round, does not spend the budget, and asks nobody.
- **`zp_host_only` with `zp_host_approve` is just `zp_host_only`.** The first turns the
  request away before there is anything left to approve.

## Configuration

Every setting is at the top of the file, and each one is also a dvar of the same name.
The script creates each dvar with its default on load, so you can set them straight from
the console:

```bash
zp_countdown 5
```

The config is re-read every five seconds while the game is running, and again
whenever a pause is requested, so a change takes effect **almost straight away** — no map
restart needed.

The periodic re-read is skipped while the game is paused: the HUD is built from these
settings when the pause starts and nothing rebuilds it in place, so moving them underneath
would leave elements where the old values put them. A change made mid-pause lands the
moment play resumes. It also means `zp_combo` can be changed by hand — before, that needed
a pause to take effect, and the combo is what asks for one.

`set zp_config_print 1` in the console prints every setting below with the value it is
currently holding, then puts the switch back so it can be used again.

| Dvar | Default | What it does |
|---|---|---|
| `zp_host_only` | `0` | Only the host can pause or resume. Everyone else's combo is ignored, and a pause never goes to a vote. On a dedicated server there is no host, so it falls to whoever holds the first player slot. |
| `zp_button_combo` | `1` | Enable the button combos. |
| `zp_combo` | `crouch_melee` | Pause combo: `crouch_melee`, `jump_use`, `jump_melee`, `use_melee`, `ads_melee`, `ads_use`, `throw_use`. |
| `zp_button_hold_time` | `0.3` | How long a combo must be held. |
| `zp_combo_dead` | `use_ads` | Combo used while downed or spectating. `""` = no button in that state. |
| `zp_vote_no_combo_dead` | `use_attack` | The same, for a no vote. |
| `zp_host_approve` | `0` | The host pauses at once; anyone else has to ask and the host answers yes or no. It runs as a vote only the host can cast, so the yes/no input, the HUD and the timeout are a vote's. Pausing only — resuming still follows `zp_vote`. `zp_host_only` wins where both are set. |
| `zp_ready_check` | `0` | Resuming waits for the players to say they're back. Not a vote — nobody says no and it can't fail, so it needs no `zp_vote`, and it wins over `zp_vote_unpause` where both are set. |
| `zp_ready_percent` | `100` | How much of the room has to be ready. `100` is everybody. |
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
| `zp_ease` | `1` | **No effect on this engine.** See below. |
| `zp_ease_time` | `0.35` | The same. |
| `zp_countdown` | `3` | Seconds of 3‑2‑1 before play resumes. |
| `zp_grace` | `2` | Seconds of invulnerability after resuming. |
| `zp_max_pauses` | `0` | How many times one match can be paused. `0` is no cap. Only a pause somebody asked for spends one — an automatic pause does not. |
| `zp_pause_on_disconnect` | `0` | Pause when somebody drops, so whoever is left isn't overrun while they rejoin. Nothing un-pauses on its own, so `zp_max_pause_time` is the way out if they don't come back. |
| `zp_round_pause` | `0` | Hold a pause until the round is over instead of freezing the game mid-horde. Asking again calls it off. |
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
| `zp_hud` | `1` | Draw the pause block at all. The vote HUD is separate and still draws. |
| `zp_hud_timer` | `1` | Show who paused and how long it's been. |
| `zp_hud_position` | `center` | Where the pause banner sits: `top`, `center`, `middle`, `bottom`, `left`, `right`. |
| `zp_vote_hud_position` | `top` | Where the vote tally sits. |
| `zp_hud_glow` | `1` | Black glow behind the HUD text. |
| `zp_hud_binds` | `1` | Draw combos as each player's bound buttons instead of words. |
| `zp_hud_panel` | `0` | Black slab behind the whole block. |
| `zp_hud_panel_alpha` | `0.45` | How opaque that slab is. |
| `zp_hud_panel_width` | `340` | How wide it is, in HUD units. |
| `zp_blackout` | `1` | Dim everyone's screen while paused, which keeps the pause text readable over a bright skybox. Raise `zp_blackout_alpha` for the anti-scouting blackout this used to be. |
| `zp_blackout_alpha` | `0.2` | How far it dims. `0.2` is a light darkening; `1` is fully black. |
| `zp_blur` | `1` | Blur everyone's screen while paused. |
| `zp_blur_amount` | `2` | Blur strength. `4` is the blur the game runs when you buy a perk. |
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


### `zp_ease` does nothing here

On Black Ops II and Black Ops III, `zp_ease` ramps time down as the pause takes hold and
back up as it lifts, so the stop reads as deliberate rather than as a hitch.

There's no way to do that on this engine. `setslowmotion()` appears nowhere in the stock
script dump, so there's no reachable way to ramp the timescale from a zombies script —
and calling a builtin that might not exist is how a script dies on load rather than
degrading quietly.

The setting still exists, with the same name and default as the other ports, so one config
file works across all of them. It simply has nothing to do here.

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
- **Zombies at a window.** Holding a zombie by its goal tells the game it has arrived, so
  one caught on its way to a window would start tearing from wherever it stood. On resume,
  a zombie short of its spot is walked the rest of the way first.
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
| Black Ops 4 (T8) | [ZPauseT8](https://github.com/Xeptix/ZPauseT8) |
| Black Ops III (T7) | [ZPauseT7](https://github.com/Xeptix/ZPauseT7) |
| Black Ops II (T6) | [ZPause](https://github.com/Xeptix/ZPause) |
| Black Ops (T5) | ZPauseT5 — you are here |
| World at War (T4) | [ZPauseT4](https://github.com/Xeptix/ZPauseT4) |

Versions are kept in step: the same version number means the same feature set, allowing
for what each engine can actually do.

**All five in one download.** The
[Treyarch Bundle](https://github.com/Xeptix/ZPause/releases/latest) carries every game
ZPause runs on, laid out as each drops in — the `Plutonium` tree for this game and the
other two, Black Ops III's loader folders, Black Ops 4's mod folder — with one installer
that knows all five. By hand, drop its `Plutonium` folder into `%localappdata%\Plutonium`,
say yes to the merge, and delete the game folders you don't have.

---

## Changelog

### v1.4

- **A zombie paused on its way to a window now finishes the walk.** Before, resuming sent
  it straight into the board-tearing animation wherever it stood — even far from the
  window — and it only walked up once the boards were gone. The pause holds zombies by
  pinning their goal to the spot, which is the only stop this engine offers, but the game
  takes a reached goal as "at the window". On resume, any zombie still short of its spot is
  sent the rest of the way first.

- **`zp_hud`** — draw the pause block at all. Off leaves the pause itself working with
  nothing on screen, which is what a recording or a server drawing its own overlay wants.
  The vote HUD is separate and still draws. On by default.

- **`zp_blackout` is on by default now**, at the new **`zp_blackout_alpha`** of `0.2`. It
  was off in v1.3, so this is the one change you will notice without going looking: while
  paused, the screen dims slightly. That is deliberate — it carries the pause text over a
  bright skybox, which matters more now that every port shares one readability setting.
  `zp_blackout 0` puts it back, and `zp_blackout_alpha 1` gives the full anti-scouting
  blackout it used to be at when it was switched on by hand.

- **`zp_blur_amount` moved from `1.5` to `2`** for the same reason. Both defaults are
  reported by the installer when you update, if you had been leaving them alone.

- **`zp_round_pause`** — hold a pause until the round is over rather than freezing the game
  mid-horde. Asking again calls it off. Off by default.
- **`zp_ready_check`** and **`zp_ready_percent`** — resuming waits for the players to say
  they are back, all of them by default. Not a vote: nobody says no, and it cannot fail.
  Off by default.

- **`zp_max_pauses`** — a cap on how many times one match can be paused, for a server where
  that would otherwise become an argument. Off by default.
- **`zp_pause_on_disconnect`** — pause when somebody drops, so whoever is left isn't overrun
  while they rejoin. Off by default.

- **`zp_host_approve`** — the host pauses at once; anyone else has to ask, and the host
  answers yes or no. It runs as a vote with an electorate of one, so it uses the same
  yes/no input and the same clock, and works where there is no chat. Pausing only, so
  nobody is stranded if the host walks away. Off by default.

- **`zp_config_print`** — `set zp_config_print 1` in the console prints every setting and
  the value it currently holds.

- **`zp_host_only`** — only the host can pause or resume. Everyone else's combo is
  ignored, and a pause never goes to a vote, since there is nobody left to ask. Off by
  default.

- **`zp_ease`** and **`zp_ease_time`** added for config parity with the other ports.
  They have no effect on this engine — see [`zp_ease` does nothing here](#zp_ease-does-nothing-here).

- **The config editor.** Every setting is a dvar, and the installer now sets them without
  a console — it reads the list out of the installed script, so it is always right for the
  version you have, with each setting's description from the README table. Settings that
  take a fixed set of values offer that list rather than a blank prompt. You can keep
  several **profiles** and switch between them, and each one exports as a portable
  `zpause.cfg` of `set` lines, which is what a dedicated server execs and what you send
  somebody. Your settings are re-applied after an update, so a new version never quietly
  resets them.

- **Settings take effect without a map restart.** The config is re-read every five seconds
  while the game runs, and again whenever a pause is requested. The periodic re-read is
  skipped while paused, since the HUD is built when the pause starts and nothing rebuilds
  it in place — a change made mid-pause lands the moment play resumes.

- **The installer is now a manager.** It shows what is installed and which version each
  copy is, removes them again, checks GitHub for a newer release and downloads it with a
  progress bar, and can keep itself on your PC behind a Desktop or Start-menu shortcut. It
  asks before it touches the network, every run. The installers moved into
  `installer\windows\` and `installer/linux/` in the download.

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
