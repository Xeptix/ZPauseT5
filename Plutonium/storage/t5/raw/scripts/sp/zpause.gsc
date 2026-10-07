/*
======================================================================
    ZPAUSE T5 v1.6  --  Synced co-op pause for Black Ops Zombies
    Plutonium T5

    by Xep

======================================================================

    A port of ZPause (Plutonium T6) to Black Ops 1. Same design, against
    a different script base: BO1 zombies runs on the singleplayer tree,
    so the core is maps\_zombiemode.gsc rather than maps\mp\zombies\_zm.

        Buttons  hold crouch + melee

        Install  %localappdata%\Plutonium\storage\t5\raw\scripts\sp

    Zombies scripts go in sp, not a zm folder -- Black Ops 1 zombies runs
    on the singleplayer tree. There is no mod packaging for this game:
    Plutonium's mods folder and its in-game Mods menu are Black Ops 2
    only, so the script drop-in is the whole delivery.

    Everything runs on the host. Nobody else needs this file.

----------------------------------------------------------------------
    HOW IT WORKS, AND HOW IT DIFFERS FROM THE T6 BUILD

    T6 leans on disablezombies(), an engine-level AI freeze that exists
    in Black Ops 2 because host migration needs one. Black Ops 1 has no
    host-migration pause and no such builtin -- it appears nowhere in the
    stock script dump.

    So the AI enforcer below is not a safety net here, the way it is on
    T6. It IS the freeze. It holds ignoreall, pins every goal to the spot
    the zombie was standing on, and snaps back anything that drifts, on a
    tick, for as long as the pause lasts.

    The rest of the recipe carries over intact:

        flag_clear( "spawn_zombies" )   the spawner's own gate
        player freezecontrols( 1 )      lock players
        player enableinvulnerability()  nobody can be hurt

    And the two traps found on T6 turn out to be the same traps here:

    - The stuck-zombie watchdog. _zombiemode.gsc::round_spawn_failsafe()
      kills any zombie that has not moved 24 units in 30 seconds, and a
      paused zombie trips it every time. It skips the kill for anything
      that tore a barrier chunk in the last 8 seconds, so keeping that
      stamp fresh makes the watchdog loop harmlessly instead of firing.

    - Bleedout. _laststand.gsc::laststand_bleedout() counts a
      self.bleedout_time field down once a second, so pinning the field
      holds a downed player where they are. This is tidier than the T6
      equivalent.

----------------------------------------------------------------------
    NOT PORTED

    One T6 feature is deliberately not here: the match clock, which
    Black Ops 1 zombies does not have. The bind prompts are here, with
    crouch as a plain word -- this engine reads crouching as a stance
    rather than a button, so no single key marker can be right for it.
    See PORTING.md.

----------------------------------------------------------------------
    VERIFICATION

    There is no compiler for this engine -- gsc-tool's Treyarch support
    starts at T6, and Plutonium T5 loads raw source and compiles it at
    runtime, so there is no build step to check against.

    In its place, and re-run after every edit: every function call is
    checked against the stock T5 dump as a real call in a module a
    zombies script can reach; every field, notify, level flag,
    zombie_vars key, shader and sound alias it borrows is checked for
    existence there too; and the file parses under gsc-tool's T6 grammar,
    which shares this syntax. See audit.py and deep_check.py.

----------------------------------------------------------------------
    CREDITS

        Xep           author
        Treyarch      _zombiemode.gsc
        plutoniummod  t5-scripts, the stock script reference

----------------------------------------------------------------------
    LICENSE

        MIT -- see LICENSE. Keep this header on copies.

======================================================================
*/

/*
    These two are the only includes that resolve. maps\_zombiemode_utility
    does NOT: zombiemode scripts are not in the loaded script tree when a
    raw script is compiled, and including it fails the entire server with
    "Could not find script 'maps/_zombiemode_utility'".

    Stock Plutonium scripts reach that tree at runtime instead, through
    getFunction( "maps/_zombiemode_utility", ... ) with a string path, and
    so does everything here that needs it. A qualified call into it --
    maps\_zombiemode_utility::all_chunks_destroyed() -- is no different
    from the include: it has to resolve when the script is compiled too.
    v1.4 had two, and Black Ops stopped at boot. The HUD needs nothing from
    that tree -- see zp_hud_line().
*/
#include maps\_utility;
#include common_scripts\utility;


/* ==================================================================
    ENTRY POINT
   ================================================================== */

init()
{
    if ( is_true( level.zp_loaded ) )
        return;

    level.zp_loaded = 1;

    zp_load_config();

    /*
        Switched off. The descriptor still goes up, because "not here" and
        "here, and off" are different answers to a mod asking whether it
        can hand ZPause a pause.
    */
    if ( !level.zp.enabled )
    {
        zp_api_register( 0 );
        return;
    }

    level.zp_paused = 0;
    level.zp_busy = 0;
    level.zp_last_toggle = 0;
    level.zp_pause_start = 0;
    level.zp_pause_count = 0;
    level.zp_pending = 0;
    level.zp_pending_by = undefined;
    level.zp_spawn_flag_was_set = 0;
    level.zp_pauser_name = "someone";
    level.zp_hud = undefined;
    level.zp_hud_sub = undefined;

    /*
        Unconditional: precaching has to happen during init, so gating it
        on the config would mean turning zp_blackout on later silently did
        nothing.
    */
    precacheshader( "black" );

    level.zp_powerups = [];

    level.zp_vote_active = 0;
    level.zp_vote_serial = 0;
    level.zp_vote_kind = "pause";
    level.zp_vote_approval = 0;
    level.zp_vote_end_time = 0;
    level.zp_vote_last_fail = 0;
    level.zp_vote_provisional = 0;
    level.zp_vote_initiator = undefined;
    level.zp_vote_name = "someone";
    level.zp_vote_hud = undefined;
    level.zp_vote_sub = undefined;
    level.zp_vote_rows = [];
    level.zp_panel = undefined;
    level.zp_down_line = undefined;
    level.zp_hud_clock = undefined;
    level.zp_hud_meta = undefined;

    // Built once: arrays are parent variables, and the menu is opened
    // many times a match.
    zp_menu_table();

    level thread zp_connect_watcher();
    level thread zp_chat_listener();
    level thread zp_powerup_tracker();
    level thread zp_endgame_safety();
    level thread zp_round_watcher();
    level thread zp_personal_watcher();
    level thread zp_config_watcher();
    level thread zp_config_printer();
    /*
        Made here, not read into existence: the console can only assign to a
        dvar that already exists, so "Unknown cmd zp_hud_debug" is what a
        switch nobody created looks like from in the game.
    */
    if ( getdvar( "zp_hud_debug" ) == "" )
        setdvar( "zp_hud_debug", "0" );

    level thread zp_build_watermark();

    // Last, so the first thing that reads it finds a mod already up.
    zp_api_register( 1 );
}

main()
{
    init();
}


/* ==================================================================
    CONFIG

    Every value below is also a dvar of the same name, created with its
    default on load so the console can reach it. Re-read at the start of
    every pause, so an edit applies on the next pause without a restart.
   ================================================================== */

zp_load_config()
{
    // Reused rather than reallocated -- spawnstruct() takes a parent
    // script variable and this runs on every pause request.
    if ( !isdefined( level.zp ) )
        level.zp = spawnstruct();

    // The saved settings, once a match. See zp_file_read().
    if ( !isdefined( level.zp_file_names ) )
        zp_file_read();

    // Built-in defaults, gathered again as the settings below are read,
    // so zp_file_write() can leave out everything still at one.
    level.zp_def_names = [];
    level.zp_def_values = [];

    // --- general ---------------------------------------------------

    /*
        ZPause itself. On by default. Off, the script still loads, still
        says so on level.zmods -- with enabled 0 -- and installs nothing
        else: no threads, no HUD, no chat words, no button watcher and nothing
        precached. The match runs as it would with the file gone.

        Read once, as the match loads. Taking a pause that is already
        installed back out safely is not something a switch can do in the
        middle of a game, so this one lands on the next match, which is
        what a bundle's MODS page says about it.
    */
    level.zp.enabled = zp_cfg_int( "zp_enabled", 1 );

    // --- input -----------------------------------------------------

    /*
        Only the host may pause. With this on the script behaves as though
        the host is the only player in the game: nobody else can start or
        end a pause, and a pause never goes to a vote, because there is no
        one left to ask.

        The host is the player in the first slot. On a dedicated server
        nobody is really the host, and it falls to whoever holds it.
    */
    level.zp.host_only = zp_cfg_int( "zp_host_only", 0 );

    /*
        A personal pause. Off by default. With it on, the pause input holds
        only the player who pressed it -- frozen, protected, and ignored by
        the zombies -- while everybody else plays on. The whole game pauses
        by itself once nobody is left playing: everybody else paused too,
        or down. The first one back brings it back. See zp_personal_start().

        Personal to each player, so it never goes to a vote, the host's
        approval or the ready check, and zp_host_only does not stop it:
        what that setting protects is a game the others are playing, which
        a personal pause does not touch. It does spend one of the match's
        zp_max_pauses, and zp_max_pause_time ends it, the same as a pause.
    */
    level.zp.personal_pause = zp_cfg_int( "zp_personal_pause", 0 );

    /*
        The host's settings menu, opened while paused by holding fire and
        melee. See zp_menu_watcher().
    */
    level.zp.menu      = zp_cfg_int( "zp_menu", 1 );

    /*
        Which combo toggles the pause. Defaults to crouch + melee, the
        same as the T6 build.

            crouch_melee | jump_use | jump_melee | use_melee
            ads_melee | ads_use | throw_use

        Every one is built from engine builtins that stock zombies scripts
        call -- usebuttonpressed, meleebuttonpressed, jumpbuttonpressed,
        adsbuttonpressed, throwbuttonpressed and getstance. The
        use_button_pressed() style wrappers in _utility.gsc are avoided:
        they do not resolve from a raw script, and naming a function the
        engine cannot resolve is a compile error even in a branch that
        never runs.
    */
    // Chat words that toggle the pause. "!p" is the short form.
    level.zp.allow_short_words = zp_cfg_int( "zp_allow_short_words", 0 );

    level.zp.button_combo      = zp_cfg_int( "zp_button_combo", 1 );
    level.zp.combo             = zp_cfg_str( "zp_combo", "crouch_melee" );
    level.zp.button_hold_time  = zp_cfg_float( "zp_button_hold_time", 0.3 );

    /*
        Down on the floor or spectating, you cannot crouch, so the default
        combo goes dead exactly when a player most wants to say something.
        These are the combos used in that state instead, built from use,
        aim and fire, which stay reachable. Set either to "" to leave that
        state with nothing but the chat commands to act through.
    */
    level.zp.combo_dead        = zp_cfg_str( "zp_combo_dead", "use_ads" );
    level.zp.vote_no_combo_dead = zp_cfg_str( "zp_vote_no_combo_dead", "use_attack" );

    // --- voting ----------------------------------------------------

    /*
        Resuming waits for the players to say they are back, rather than
        the first one to press the button deciding for everybody. Off by
        default.

        Not a vote, and not built on one: nobody votes no, it cannot fail
        and it has no clock. It waits. That is why it does not need zp_vote
        turned on, and why it wins over zp_vote_unpause where both are set.
        zp_max_pause_time is what ends a pause nobody ever answers.
    */
    level.zp.ready_check = zp_cfg_int( "zp_ready_check", 0 );

    /*
        How much of the room has to be ready. 100 is everybody, which is
        the point of it; lower it where one person going quiet should not
        be able to hold the rest.
    */
    level.zp.ready_percent = zp_cfg_int( "zp_ready_percent", 100 );

    /*
        The host pauses at once; anybody else has to ask, and the host
        answers yes or no. Off by default.

        It is a vote with an electorate of one, and reuses the whole of
        one: the same yes/no combos, the same HUD, the same clock and the
        same timeout -- which is also what makes it work on Black Ops 4,
        the one port with no chat. Narrowing eligibility to the host is
        what stops the asker's own automatic yes from carrying it.

        Pausing only. A resume still follows zp_vote and zp_vote_unpause:
        needing the host's permission to un-pause would strand everybody
        if the host put the controller down, which is the opposite of what
        this is for.

        zp_host_only wins where both are set -- it turns the request away
        before there is anything to approve.
    */
    level.zp.host_approve = zp_cfg_int( "zp_host_approve", 0 );
    /*
        Vote to pause. Off by default: without it any player pauses on
        their own, which is what the fork has done so far.

        The bar is whichever is higher, zp_vote_min or zp_vote_percent of
        the players in the game, then clamped to how many are actually
        there -- so a lobby can never set a bar nobody present can clear,
        and solo play skips the vote entirely.

        Two ways to cast one: the pause combo votes yes and
        zp_vote_no_combo votes no, or !yes and !no in chat, which this
        engine turned out to carry after all.
    */
    level.zp.vote              = zp_cfg_int( "zp_vote", 0 );
    level.zp.vote_min          = zp_cfg_int( "zp_vote_min", 2 );
    level.zp.vote_percent      = zp_cfg_int( "zp_vote_percent", 51 );
    level.zp.vote_time         = zp_cfg_float( "zp_vote_time", 30 );
    level.zp.vote_unpause      = zp_cfg_int( "zp_vote_unpause", 0 );
    level.zp.vote_hold         = zp_cfg_int( "zp_vote_hold", 0 );
    level.zp.vote_initiator_yes = zp_cfg_int( "zp_vote_initiator_yes", 1 );
    level.zp.vote_lockout      = zp_cfg_float( "zp_vote_lockout", 10 );
    level.zp.vote_alive_only   = zp_cfg_int( "zp_vote_alive_only", 1 );
    level.zp.vote_hud          = zp_cfg_int( "zp_vote_hud", 1 );
    level.zp.vote_show_voters  = zp_cfg_int( "zp_vote_show_voters", 1 );
    level.zp.vote_result_time  = zp_cfg_float( "zp_vote_result_time", 2 );
    level.zp.vote_no_combo     = zp_cfg_str( "zp_vote_no_combo", "jump_melee" );

    // --- timing ----------------------------------------------------

    /*
        Hold a pause until the round is over instead of freezing the game
        mid-horde. Asking again while one is pending calls it off.

        Off by default: it takes "pause now" away, and that is often
        exactly why somebody is reaching for the button.
    */
    level.zp.round_pause = zp_cfg_int( "zp_round_pause", 0 );

    /*
        A cap on how many times one match can be paused, for a server where
        that would otherwise become an argument. 0 is no cap.

        Only a pause somebody asked for spends one: an automatic pause is
        not theirs to spend.
    */
    level.zp.max_pauses = zp_cfg_int( "zp_max_pauses", 0 );

    /*
        Pause when somebody drops. A crash or a dropped connection
        otherwise leaves whoever is left to be overrun, and on these
        clients the player can come back.

        Nothing here un-pauses on its own, so zp_max_pause_time is the
        way out when they do not come back.
    */
    level.zp.pause_on_disconnect = zp_cfg_int( "zp_pause_on_disconnect", 0 );
    /*
        On T6 and T7 this eases time down into the pause and back out
        rather than cutting to a stop.

        It does nothing here. setslowmotion() appears nowhere in the stock
        script dump for this engine, so there is no reachable way to ramp
        the timescale from a zombies script -- and guessing at a builtin
        that may not exist is how a script dies on load.

        The setting is still created, and still carries the same name and
        default as the other ports, so one config works everywhere.
    */
    level.zp.ease              = zp_cfg_int( "zp_ease", 1 );
    level.zp.ease_time         = zp_cfg_float( "zp_ease_time", 0.35 );

    level.zp.countdown         = zp_cfg_int( "zp_countdown", 3 );
    level.zp.grace             = zp_cfg_float( "zp_grace", 2 );
    level.zp.cooldown          = zp_cfg_float( "zp_cooldown", 2 );
    level.zp.max_pause_time    = zp_cfg_int( "zp_max_pause_time", 0 );

    // --- what gets frozen ------------------------------------------
    level.zp.drift_guard       = zp_cfg_int( "zp_drift_guard", 1 );

    /*
        EXPERIMENTAL, off by default. Cut the scripted animation on every
        zombie, over and over, for the length of the pause.

        The enforcer holds AI by pinning ignoreall, goals and position --
        all of which govern pathing. A zombie tearing boards off a barrier
        is not pathing: it is running a scripted animation that drives its
        own position, so it walks through the pause, finishes the entry,
        and only then stops. T6 never sees this because disablezombies()
        stops AI at the engine level, animation included; there is no
        equivalent here and zombie_think() has no gate to suspend.

        stopanimscripted() is the lever, and it works -- but only with
        zp_anim_release() below. Cancelling an animation leaves whatever
        started it waiting for an end that never comes, and the zombie
        stands there for the rest of the game. Releasing those waits is
        what makes this usable rather than a trade of one bug for a worse
        one.

        It runs on its own thread rather than inside zp_ai_enforcer() on
        purpose: on this engine that enforcer IS the freeze, and an error
        in here must not be able to take it down with it.
    */
    level.zp.stop_anims        = zp_cfg_int( "zp_stop_anims", 1 );
    level.zp.godmode           = zp_cfg_int( "zp_godmode", 1 );
    level.zp.freeze_players    = zp_cfg_int( "zp_freeze_players", 1 );
    level.zp.control_guard     = zp_cfg_int( "zp_control_guard", 1 );
    level.zp.freeze_bleedout   = zp_cfg_int( "zp_freeze_bleedout", 1 );
    level.zp.freeze_powerups   = zp_cfg_int( "zp_freeze_powerups", 1 );
    level.zp.freeze_effects    = zp_cfg_int( "zp_freeze_effects", 1 );

    /*
        Shut the zombies up while the game is held. A frozen horde stood
        next to you keeps growling, which is loud and misleading when
        nothing is happening.

        T6 does this by flagging each zombie is_inert, which
        do_zombies_playvocals() checks and returns on. Black Ops 1 has no
        inert system. Its vocals function has an equivalent early-out --
        is_true( self.shrinked ) -- but that flag is not audio-only here:
        on Shangri La it also drives the minecart, the achievement tracker
        and the sonic and napalm zombies, so borrowing it would have real
        gameplay side effects on that map.

        Cutting the sound instead has no side effects at all. The AI
        enforcer already walks every zombie on a tick, so it stops their
        sounds while it is there; a vocal that starts mid-pause is audible
        for at most one tick before it is cut.
    */
    level.zp.silence_zombies   = zp_cfg_int( "zp_silence_zombies", 1 );

    // --- presentation ----------------------------------------------

    /*
        Draw the pause block at all. Off leaves everything else working --
        the freeze, the vote, the chat replies -- with nothing on screen,
        which is what a recording or a server drawing its own overlay
        wants.

        The vote HUD is separate and keeps drawing, because a vote nobody
        can see is a vote nobody can answer.
    */
    level.zp.hud               = zp_cfg_int( "zp_hud", 1 );
    level.zp.show_hint         = zp_cfg_int( "zp_show_hint", 1 );

    /*
        Where each block of HUD text sits: top, center, middle, bottom,
        left or right. The left and right slots align their text to that
        edge rather than staying centred. "center" is the classic banner
        spot, horizontally centred and high enough to stay out of the
        fight; "middle" is the actual centre of the screen.

        There is no setpoint() on this engine, so these are set by hand
        through alignx / aligny / horzalign / vertalign.
    */
    /*
        Who paused, and how long ago, under the banner. Counts down to the
        auto-resume instead when zp_max_pause_time is set.

        Minutes only, capped at "> 60". There are no timer elements on this
        engine, so a clock has to be text -- and every distinct string
        settext() is given costs a configstring. A ticking second counter
        would burn one a second until the pool ran dry and dropped the
        server, which is exactly how the T6 build once died. Minutes bound
        the whole set to about sixty strings, all reused.

        The name is a separate element from the clock for the same reason:
        together they would cost one string per player per minute rather
        than one per player plus sixty.
    */
    level.zp.hud_timer         = zp_cfg_int( "zp_hud_timer", 1 );

    level.zp.hud_position      = zp_cfg_str( "zp_hud_position", "center" );
    level.zp.vote_hud_position = zp_cfg_str( "zp_vote_hud_position", "top" );

    /*
        Black glow behind the text. Nothing in the stock dump sets
        glowcolor, so it is unverified here -- but an unrecognised field on
        a hudelem is simply ignored, unlike an unrecognised function, which
        would not compile. Worst case it does nothing.
    */
    level.zp.hud_glow          = zp_cfg_int( "zp_hud_glow", 1 );

    /*
        Draw the combos as the buttons each player has bound rather than as
        words. [{+bind}] markers are substituted by the client at draw
        time, so one string shows a key on a keyboard and a pad glyph on a
        controller, per player, following rebinds.

        Confirmed working in play: settext does substitute, despite stock
        scripts only ever using these markers in SetHintString.

        Crouch is the exception and stays a word -- see zp_bind() for why
        no single crouch marker can be right for everyone. Grenade uses
        +frag, which is the standard name but appears nowhere in the T5
        dump; if it turns out wrong it draws as "UNBOUND" rather than
        breaking anything.
    */
    level.zp.hud_binds         = zp_cfg_int( "zp_hud_binds", 1 );

    /*
        Heavier alternative: a black slab behind the whole block.
        setshader( "black", w, h ) is used by stock scripts, so this one is
        solid. Off by default -- it is a lot of screen for a co-op pause.

        The width is a dvar because nothing here can measure a rendered
        string. Widen it if a long line overhangs.
    */
    level.zp.hud_panel         = zp_cfg_int( "zp_hud_panel", 0 );
    level.zp.hud_panel_alpha   = zp_cfg_float( "zp_hud_panel_alpha", 0.45 );
    level.zp.hud_panel_width   = zp_cfg_int( "zp_hud_panel_width", 340 );
    /*
        Black out every screen for the length of the pause, so nobody can
        study the horde they are frozen in front of. Off by default; the
        blur below is the gentler version of the same idea.
    */
    level.zp.blackout          = zp_cfg_int( "zp_blackout", 1 );

    /*
        How dark it goes. 1 is fully black; lower leaves the screen
        readable, for when the point is to discourage scouting rather than
        to make it impossible.
    */
    level.zp.blackout_alpha = zp_cfg_float( "zp_blackout_alpha", 0.2 );
    level.zp.blur              = zp_cfg_int( "zp_blur", 1 );
    level.zp.blur_amount       = zp_cfg_float( "zp_blur_amount", 2 );

    /*
        Stock aliases, so the script stays a single drop-in file -- a
        custom sound would have to be installed by every player rather
        than just the host.

        None of the T6 defaults exist here: they are Black Ops 2 aliases,
        and there is no Tombstone perk and no inert system to borrow from.
        These are picked from _zombiemode_perks.gsc and
        _zombiemode_powerups.gsc, which are Common, so they are present on
        every map -- unlike, say, zmb_egg_timer_oneshot, which would have
        been the obvious countdown tick but only exists on Ascension.

        Others worth trying, all Common: zmb_whoosh, zmb_points_loop_off,
        zmb_cha_ching, zmb_perks_packa_ready, evt_perk_deny, deny.
        Set any to "" for silence.
    */
    level.zp.pause_sound       = zp_cfg_str( "zp_pause_sound", "zmb_box_poof" );
    level.zp.countdown_sound   = zp_cfg_str( "zp_countdown_sound", "zmb_bolt" );
    level.zp.resume_sound      = zp_cfg_str( "zp_resume_sound", "zmb_perks_power_on" );

    // Drift guard tolerance, in units squared. 64 = 8 units.
    level.zp.drift_tolerance   = 64;
}

/*
    Black Ops 1 keeps set_dvar_if_unset() in the multiplayer utility only
    (MP/Common/maps/mp/_utility.gsc), where a zombies script cannot reach
    it, so the same behaviour is done by hand.

    Creating the dvar is the point: the console can only assign to one
    that already exists, so a plain read would leave every setting
    unreachable from in game.
*/
/*
    "none" is how a string setting is emptied in game. An empty dvar reads
    as one that was never set and gets the default written straight back,
    so "" typed into the console lasted until the next read, and the
    settings menu has no other way to write nothing.
*/
/*
    Settings saved to a file, which is how a change made anywhere reaches
    everywhere else.

        storage\t5\raw\scriptdata\zpause.cfg

    One store, four ways in: the installer's config editor writes it, the
    in-game menu writes it when it closes, a dedicated server can exec the
    same lines, and it can be edited by hand. Plutonium's file functions
    work on this engine in both directions -- probed in game on 15
    September 2026 -- and this is what they are for.

    The file holds what a setting should be, not what it is: it supplies
    the *default*, so a console dvar still beats it, exactly as T8 does it
    with its JSON. Read once per match rather than on every config pass --
    zp_load_config() runs on every pause request and a file does not
    change underneath a running game -- so an edit lands on the next
    match, which is what rewriting the script does too.
*/
zp_file_read()
{
    level.zp_file_names = [];
    level.zp_file_values = [];

    if ( !fs_testfile( "zpause.cfg" ) )
        return;

    h = fs_fopen( "zpause.cfg", "read" );

    if ( !isdefined( h ) )
        return;

    /*
        Bounded rather than while(1): fs_readline() hands back undefined
        at the end of the file, and a file that never did would otherwise
        hold the script here for good. 300 is well past one line per
        setting.
    */
    for ( i = 0; i < 300; i++ )
    {
        line = fs_readline( h );

        if ( !isdefined( line ) )
            break;

        zp_file_line( line );
    }

    fs_fclose( h );
}

/*
    One line of it: `set zp_name "value"`, with or without the set, with
    or without the quotes -- the installer writes them, a hand-written
    line might not.

    Nothing here checks that a name is one of ours, because nothing needs
    to: zp_file_value() asks for a name it already knows, so a comment or
    a stray line is stored and never matched.
*/
zp_file_line( line )
{
    parts = strtok( line, " " );

    if ( !isdefined( parts ) || parts.size < 2 )
        return;

    at = 0;

    if ( parts[0] == "set" || parts[0] == "seta" )
        at = 1;

    if ( parts.size < at + 2 )
        return;

    value = parts[at + 1];

    // A quoted value is whatever sits between the first pair of quotes,
    // which also keeps the quotes out of the value itself.
    quoted = strtok( line, "\"" );

    if ( isdefined( quoted ) && quoted.size > 1 )
        value = quoted[1];

    level.zp_file_names[level.zp_file_names.size] = parts[at];
    level.zp_file_values[level.zp_file_values.size] = value;
}

/*
    What the file says a setting should be, or the built-in default.
*/
zp_file_value( dvar, def )
{
    if ( !isdefined( level.zp_file_names ) )
        return def;

    for ( i = 0; i < level.zp_file_names.size; i++ )
    {
        if ( level.zp_file_names[i] == dvar )
            return level.zp_file_values[i];
    }

    return def;
}

/*
    The built-in default of a setting, kept as the config is read.

    Taken here rather than from the generated menu table because this is
    where it is true: the same call that declares a setting hands it over,
    before the file gets a say, so the two cannot drift. It also covers
    the handful of settings the menu has no row for, which a table-driven
    version would have dropped from the file the first time it saved.
*/
zp_cfg_remember( dvar, def )
{
    if ( !isdefined( level.zp_def_names ) )
    {
        level.zp_def_names = [];
        level.zp_def_values = [];
    }

    level.zp_def_names[level.zp_def_names.size] = dvar;
    level.zp_def_values[level.zp_def_values.size] = def;
}

/*
    Everything that differs from its built-in default, written as the same
    `set` lines the installer writes and a dedicated server execs.

    Only what differs, for the reason the installer gives: a file that
    pinned all sixty settings would hold a later version to this one's
    defaults for the ones nobody ever touched.

    The whole file is replaced, and it is written from the dvars rather
    than from the menu's rows, so a setting with no row -- and a setting
    changed from the console -- survives the rewrite instead of being
    dropped.
*/
zp_file_write()
{
    if ( !isdefined( level.zp_def_names ) )
        return;

    h = fs_fopen( "zpause.cfg", "write" );

    if ( !isdefined( h ) )
        return;

    fs_writeline( h, "// ZPause settings -- written by the in-game menu." );
    fs_writeline( h, "// Read by the script, the installer and exec on a server." );
    fs_writeline( h, "// Only what differs from the default is listed." );
    fs_writeline( h, "" );

    for ( i = 0; i < level.zp_def_names.size; i++ )
    {
        name = level.zp_def_names[i];
        value = getdvar( name );

        if ( value == "" || value == level.zp_def_values[i] )
            continue;

        fs_writeline( h, "set " + name + " \"" + value + "\"" );
    }

    fs_fclose( h );
}

zp_cfg_str( dvar, def )
{
    zp_cfg_remember( dvar, def );

    def = zp_file_value( dvar, def );

    if ( getdvar( dvar ) == "" )
        setdvar( dvar, def );

    value = zp_cfg_echo( dvar, getdvar( dvar ), def );

    if ( value == "none" )
        return "";

    return value;
}

zp_cfg_int( dvar, def )
{
    return int( zp_cfg_str( dvar, "" + def ) );
}

zp_cfg_float( dvar, def )
{
    return float( zp_cfg_str( dvar, "" + def ) );
}


/* ==================================================================
    INPUT -- CHAT

    Black Ops raises the notify exactly as Black Ops II does:

        level waittill( "say", message, player )

    Nothing in the stock dump listens for it, and nothing in Plutonium's
    own scripts does either, which is why this port shipped documented as
    button-only. That was reasoning from absence: the notify fires anyway,
    and was seen doing it on 15 September 2026. See
    docs/handoff-chat-commands.md.
   ================================================================== */

zp_chat_listener()
{
    level endon( "end_game" );

    for (;;)
    {
        level waittill( "say", message, player );

        if ( !isdefined( message ) || !isdefined( player ) )
            continue;

        msg = tolower( message );

        if ( is_true( level.zp_vote_active ) && zp_is_no_word( msg ) )
            zp_cast_vote( player, 0 );
        else if ( is_true( level.zp_vote_active ) && zp_is_yes_word( msg ) )
            zp_cast_vote( player, 1 );
        else if ( zp_is_pause_word( msg ) )
            level thread zp_request_toggle( player );
        else if ( zp_is_unpause_word( msg ) )
            level thread zp_request_unpause( player );
    }
}

/*
    Every comparison is done twice, once on the raw string and once on the
    string less its first character: Plutonium hands T6 the message behind
    a stray control character, and whether Black Ops does the same is
    untested. Covering both costs nothing.
*/
zp_word_is( msg, token )
{
    if ( msg == token )
        return 1;

    /*
        Only when that first character is not one a word is made of. It
        used to be dropped from anything: with a vote open "my" and "by"
        cast a yes, "on", "in", "an" and "un" cast a no, and "eyes" was a
        yes. A control character or a prefix is what this is for.
    */
    if ( msg.size > 1
         && !issubstr( "abcdefghijklmnopqrstuvwxyz0123456789", getsubstr( msg, 0, 1 ) )
         && getsubstr( msg, 1 ) == token )
        return 1;

    return 0;
}

zp_is_pause_word( msg )
{
    if ( zp_word_is( msg, "!pause" ) )
        return 1;

    if ( zp_word_is( msg, "!p" ) )
        return 1;

    if ( level.zp.allow_short_words )
    {
        if ( zp_word_is( msg, "pause" ) )
            return 1;

        if ( zp_word_is( msg, "p" ) )
            return 1;
    }

    return 0;
}

zp_is_unpause_word( msg )
{
    if ( zp_word_is( msg, "!unpause" ) )
        return 1;

    if ( zp_word_is( msg, "!resume" ) )
        return 1;

    if ( zp_word_is( msg, "!u" ) )
        return 1;

    if ( level.zp.allow_short_words )
    {
        if ( zp_word_is( msg, "unpause" ) )
            return 1;

        if ( zp_word_is( msg, "resume" ) )
            return 1;

        if ( zp_word_is( msg, "u" ) )
            return 1;
    }

    return 0;
}

/*
    Only consulted while a vote is open, so the bare forms cannot cast
    anything during normal conversation.
*/
zp_is_yes_word( msg )
{
    if ( zp_word_is( msg, "!yes" ) )
        return 1;

    if ( zp_word_is( msg, "!y" ) )
        return 1;

    if ( zp_word_is( msg, "yes" ) )
        return 1;

    if ( zp_word_is( msg, "y" ) )
        return 1;

    return 0;
}

zp_is_no_word( msg )
{
    if ( zp_word_is( msg, "!no" ) )
        return 1;

    if ( zp_word_is( msg, "!n" ) )
        return 1;

    if ( zp_word_is( msg, "no" ) )
        return 1;

    if ( zp_word_is( msg, "n" ) )
        return 1;

    return 0;
}


/* ==================================================================
    INPUT -- BUTTON COMBO

    freezecontrols() blocks movement and weapon use but button state
    still reaches the server, so this keeps working while paused. That is
    what lets a frozen player unpause without touching chat.
   ================================================================== */

zp_combo_pressed( combo )
{
    if ( combo == "jump_use" )
        return self jumpbuttonpressed() && self usebuttonpressed();

    if ( combo == "jump_melee" )
        return self jumpbuttonpressed() && self meleebuttonpressed();

    if ( combo == "use_melee" )
        return self usebuttonpressed() && self meleebuttonpressed();

    if ( combo == "ads_melee" )
        return self adsbuttonpressed() && self meleebuttonpressed();

    if ( combo == "ads_use" )
        return self adsbuttonpressed() && self usebuttonpressed();

    /*
        The same pair under the name T6 gives it, and what zp_combo_dead
        defaults to on every port -- and use_attack is what
        zp_vote_no_combo_dead defaults to. Neither was tested here, so both
        fell past every case to the stance test below: a downed player's
        fallback was crouch + melee, the one combo they were moved off
        because they cannot make it, and the menu offered both names as
        choices that quietly did something else.
    */
    if ( combo == "use_ads" )
        return self usebuttonpressed() && self adsbuttonpressed();

    if ( combo == "use_attack" )
        return self usebuttonpressed() && self attackbuttonpressed();

    if ( combo == "throw_use" )
        return self throwbuttonpressed() && self usebuttonpressed();

    /*
        The T6 combo, and the default here too.

        Black Ops 1 has no stancebuttonpressed() to read, but getstance()
        reports the stance the player is actually in -- which turns out to
        be the only workable signal, because Black Ops 1 splits crouching
        across four separate binds:

            GO TO CROUCH   TOGGLE CROUCH   CROUCH   CHANGE STANCE

        A player binds whichever they like, and CHANGE STANCE goes to
        *prone* when held rather than crouch. Watching any single button
        would strand everyone who binds a different one, and watching
        "crouch" alone would strand anyone who reaches a low stance by
        holding CHANGE STANCE.

        So the test is simply "not standing". Every route into a low
        stance satisfies it, which also makes this closer to T6, where
        stancebuttonpressed() covers crouch and prone alike.
    */
    return self getstance() != "stand" && self meleebuttonpressed();
}

/*
    Whether a combo asks for a stance, which matters because
    freezecontrols() locks the stance along with the movement that reaches
    it. The six named above are buttons and keep working while a player is
    held; anything else falls through to the stance test, exactly as
    zp_combo_pressed() does -- the two lists belong together.
*/
zp_combo_needs_stance( combo )
{
    if ( combo == "jump_use" || combo == "jump_melee" || combo == "use_melee" )
        return 0;

    if ( combo == "ads_melee" || combo == "ads_use" || combo == "throw_use" )
        return 0;

    if ( combo == "use_ads" || combo == "use_attack" )
        return 0;

    return 1;
}

/*
    The combo that can actually be pressed to resume, which is what the
    banner names. While players are held the stance half can never be made,
    so everybody is on the fallback -- see zp_active_combo().

    locked is for a player held whatever zp_freeze_players says, which is
    what a personal pause is. The whole-game hold those pauses make counts
    the same way: the only players who can end it are the ones who paused,
    and every one of them is locked.
*/
zp_resume_combo( locked )
{
    if ( !level.zp.freeze_players && !is_true( locked ) && !is_true( level.zp_personal_hold ) )
        return level.zp.combo;

    if ( !zp_combo_needs_stance( level.zp.combo ) )
        return level.zp.combo;

    if ( !isdefined( level.zp.combo_dead ) || level.zp.combo_dead == "" )
        return "";

    return level.zp.combo_dead;
}

/*
    One button, as a bind marker the client swaps for the key or pad glyph
    that player actually has bound.

    Crouch is deliberately the one exception and stays a plain word.
    Black Ops 1 splits crouching across four separate binds -- GO TO
    CROUCH, TOGGLE CROUCH, CROUCH and CHANGE STANCE -- and a player only
    ever binds one or two of them, so any single marker reads "UNBOUND"
    for everyone who chose a different one. [{+stance}] is CHANGE STANCE,
    which is unbound by default; the stock bind is TOGGLE CROUCH.

    It would be the wrong thing to show even when it resolved. The combo
    reads getstance(), not a button -- the player needs to *be* crouched,
    however they got there, so naming one particular key is misleading.
*/
zp_bind( button )
{
    if ( button == "frag" )
        return "[{+frag}]";

    if ( button == "use" )
        return "[{+activate}]";

    if ( button == "ads" )
        return "[{+speed_throw}]";

    if ( button == "attack" )
        return "[{+attack}]";

    if ( button == "jump" )
        return "[{+gostand}]";

    if ( button == "crouch" )
        return "crouch/prone";

    if ( button == "throw" )
        return "[{+frag}]";

    return "[{+melee}]";
}

zp_combo_binds( combo )
{
    if ( combo == "jump_use" )
        return zp_bind( "jump" ) + " + " + zp_bind( "use" );

    if ( combo == "jump_melee" )
        return zp_bind( "jump" ) + " + " + zp_bind( "melee" );

    if ( combo == "use_melee" )
        return zp_bind( "use" ) + " + " + zp_bind( "melee" );

    if ( combo == "ads_melee" )
        return zp_bind( "ads" ) + " + " + zp_bind( "melee" );

    if ( combo == "ads_use" )
        return zp_bind( "ads" ) + " + " + zp_bind( "use" );

    if ( combo == "use_ads" )
        return zp_bind( "use" ) + " + " + zp_bind( "ads" );

    if ( combo == "use_attack" )
        return zp_bind( "use" ) + " + " + zp_bind( "attack" );

    if ( combo == "throw_use" )
        return zp_bind( "throw" ) + " + " + zp_bind( "use" );

    return zp_bind( "crouch" ) + " + " + zp_bind( "melee" );
}

zp_combo_label( combo, binds )
{
    if ( is_true( binds ) )
        return zp_combo_binds( combo );

    if ( combo == "jump_use" )
        return "jump + use";

    if ( combo == "jump_melee" )
        return "jump + melee";

    if ( combo == "use_melee" )
        return "use + melee";

    if ( combo == "ads_melee" )
        return "aim + melee";

    if ( combo == "ads_use" )
        return "aim + use";

    if ( combo == "use_ads" )
        return "use + aim";

    if ( combo == "use_attack" )
        return "use + fire";

    if ( combo == "throw_use" )
        return "grenade + use";

    return "crouch/prone + melee";
}

/*
    Bled out and spectating. This is the electorate question -- who the
    vote maths runs over -- and it is deliberately not the same as the
    input question below: a downed player is still alive and still voting.
*/
zp_player_is_spectating( player )
{
    if ( !isdefined( player ) )
        return 0;

    if ( isdefined( player.sessionstate ) && player.sessionstate == "spectator" )
        return 1;

    return !isalive( player );
}

/*
    Whether the normal combo can still be pressed. You cannot crouch from
    the floor, so anyone downed or spectating is moved onto the fallback.

    Last stand is detected the way the engine's own _laststand.gsc does it:

        player_is_in_laststand()
        {
            return ( IsDefined( self.revivetrigger ) );
        }

    NOT self.laststand, which is the Black Ops II field. It is read in a
    couple of places here but never assigned, so testing it silently
    returns false forever -- and a downed player would be left on a combo
    they cannot physically press, which -- before the chat commands were
    found -- left them no way to act at all. The .laststand test is kept
    after it in case a map sets it.
*/
zp_player_input_limited( player )
{
    if ( !isdefined( player ) )
        return 0;

    if ( isdefined( player.revivetrigger ) )
        return 1;

    if ( is_true( player.laststand ) )
        return 1;

    return zp_player_is_spectating( player );
}

zp_active_combo( up_combo, dead_combo )
{
    if ( !isdefined( dead_combo ) || dead_combo == "" )
        return up_combo;

    if ( zp_player_input_limited( self ) )
        return dead_combo;

    /*
        freezecontrols() locks a player's stance as well as the movement
        that changes it, so while this script holds somebody the stance
        half of a combo can never be made. That left everyone who was
        standing when the pause landed unable to resume at all, and only
        whoever paused -- crouched, by definition -- able to. Their buttons
        still reach the server, so the fallback combo works for all of
        them, the same as it does for a player on the floor.

        A personal pause is a hold on one player with the game still
        running, so nothing about the global pause says they are held --
        zp_personal is read as well as zp_locked, which that pause sets
        too, so the way back cannot hang on the order the two are set in.
        Without it a personally paused player's combo is the stance one
        they are frozen out of, and only chat brings them back.
    */
    if ( ( is_true( self.zp_locked ) || is_true( self.zp_personal ) ) && zp_combo_needs_stance( up_combo ) )
        return dead_combo;

    return up_combo;
}

zp_button_watcher()
{
    self endon( "disconnect" );
    level endon( "end_game" );

    for (;;)
    {
        wait 0.05;

        if ( !level.zp.button_combo )
            continue;

        // The host's menu reads these buttons while it is open.
        if ( is_true( self.zp_menu_open ) )
            continue;

        combo = self zp_active_combo( level.zp.combo, level.zp.combo_dead );

        if ( !( self zp_combo_pressed( combo ) ) || self zp_menu_combo_held() )
            continue;

        // Require a short hold so the combo cannot be hit by accident.
        held = 0;
        while ( ( self zp_combo_pressed( combo ) ) && !( self zp_menu_combo_held() ) && held < level.zp.button_hold_time )
        {
            held = held + 0.05;
            wait 0.05;
        }

        if ( held < level.zp.button_hold_time || self zp_menu_combo_held() )
            continue;

        level thread zp_request_toggle( self );

        // Debounce: wait for release, then a beat.
        while ( self zp_combo_pressed( combo ) )
            wait 0.05;

        wait 0.5;
    }
}


/*
    The no half of the button voting. Idle unless a vote is actually open,
    so the combo is inert during normal play.
*/
zp_vote_no_watcher()
{
    self endon( "disconnect" );
    level endon( "end_game" );

    for (;;)
    {
        wait 0.05;

        if ( !is_true( level.zp_vote_active ) || !level.zp.button_combo )
            continue;

        if ( is_true( self.zp_menu_open ) )
            continue;

        combo = self zp_active_combo( level.zp.vote_no_combo, level.zp.vote_no_combo_dead );

        if ( !( self zp_combo_pressed( combo ) ) )
            continue;

        held = 0;
        while ( is_true( level.zp_vote_active ) && ( self zp_combo_pressed( combo ) ) && held < level.zp.button_hold_time )
        {
            held = held + 0.05;
            wait 0.05;
        }

        if ( held < level.zp.button_hold_time )
            continue;

        zp_cast_vote( self, 0 );

        while ( self zp_combo_pressed( combo ) )
            wait 0.05;

        wait 0.5;
    }
}


/* ==================================================================
    REQUEST GATES
   ================================================================== */

/*
    T6 gates on flag( "initial_blackscreen_passed" ), which does not exist
    on this engine. The nearest stable marker is the existence of
    "begin_spawning" -- _zombiemode.gsc flag_init()s it during setup, so
    once it is there the round system is up.

    Deliberately tests that the flag EXISTS rather than that it is SET:
    the set state tracks the round, and gating on it would refuse to pause
    between rounds.
*/
/*
    Black Ops 1 keeps a player's display name in .playername; .name is the
    T6 field and is not set on a T5 player, which is why every message
    read "requested by someone". Both are tried so either engine's field
    works.
*/
zp_player_name( player )
{
    if ( !isdefined( player ) )
        return "someone";

    if ( isdefined( player.playername ) )
        return player.playername;

    if ( isdefined( player.name ) )
        return player.name;

    return "someone";
}

zp_game_ready()
{
    /*
        level.intermission, not level.gameended: that one is a multiplayer
        field and is set nowhere in the zombies tree, so the test was
        false forever. Black Ops does raise "end_game", which every thread
        here ends on, so nothing got through -- but the guard may as well
        be one. _zombiemode.gsc sets level.intermission as the game ends.
    */
    if ( is_true( level.intermission ) )
        return 0;

    if ( get_players().size < 1 )
        return 0;

    if ( !isdefined( level.flag ) )
        return 0;

    if ( !isdefined( level.flag["begin_spawning"] ) )
        return 0;

    return 1;
}

zp_on_cooldown()
{
    return gettime() - level.zp_last_toggle < level.zp.cooldown * 1000;
}

/*
    The host, or undefined when nobody holds the first player slot.

    Entity number 0 is the test: that is what stock get_host() looks for on
    the engines that ship it, and it is the one check all four share.
    isHost() exists on some of them, but on Black Ops it is an MP-only name
    that a zombies script cannot reach -- audit.py catches that -- and
    Black Ops II has no get_host() at all.
*/
zp_host_player()
{
    players = get_players();

    for ( i = 0; i < players.size; i++ )
    {
        if ( isdefined( players[i] ) && players[i] getentitynumber() == 0 )
            return players[i];
    }

    return undefined;
}

/*
    True when zp_host_only should turn this request away. Says so once
    rather than failing silently, since a combo that does nothing reads as
    a broken mod.
*/
zp_host_blocked( player )
{
    if ( !level.zp.host_only )
        return 0;

    host = zp_host_player();

    // Nobody is the host, so there is nothing to restrict to.
    if ( !isdefined( host ) )
        return 0;

    if ( isdefined( player ) && player == host )
        return 0;

    if ( isdefined( player ) )
        player iprintln( "^1[Pause]^7 only the host can pause" );

    return 1;
}

/*
    Whether this match has spent its zp_max_pauses.
*/
zp_pauses_spent()
{
    return level.zp.max_pauses > 0 && level.zp_pause_count >= level.zp.max_pauses;
}

/*
    Somebody dropping mid-round leaves the rest of the team to be overrun,
    and on these clients they can come back -- so hold the game while they
    do.

    Threaded per player and deliberately outside zp_player_think(), which
    carries endon( "disconnect" ): the whole job of this one is to still be
    running after that has fired.
*/
zp_disconnect_watcher()
{
    level endon( "end_game" );

    self waittill( "disconnect" );

    /*
        The elements go with the player, but level.hudelem_count does not:
        it is counted up as each one is made and down only as each one is
        dropped, and every drop walks get_players(), which this player has
        just left. zp_menu_rows() sizes the host's menu from that count,
        so a few mid-pause dropouts left the host with the four-row floor
        for the rest of the match. Both calls check isdefined first.
    */
    self zp_blackout_off();
    self zp_menu_draw_destroy();
    self.zp_menu_open = undefined;

    // The personal banner is two more of the same, and a player who drops
    // while paused on their own is not coming back to it.
    self notify( "zp_personal_off" );
    self.zp_personal = undefined;
    self zp_personal_hud_off();

    // Read fresh: this waits for the whole match before it decides.
    zp_load_config();

    /*
        One fewer player is one fewer ready press needed, and the tally
        is only ever recounted by somebody pressing ready. Everybody left
        having already pressed it meant the count could never be taken
        again and the game stayed paused for good.
    */
    if ( is_true( level.zp_paused ) && level.zp.ready_check )
        level thread zp_mark_ready( undefined );

    if ( !level.zp.pause_on_disconnect )
        return;

    if ( is_true( level.zp_paused ) || is_true( level.zp_busy ) || !zp_game_ready() )
        return;

    players = get_players();

    // Nobody left to start it again.
    if ( players.size < 1 )
        return;

    zp_msg_all( "^3[Pause]^7 somebody dropped -- paused" );
    level.zp_last_toggle = gettime();
    level thread zp_do_pause( undefined );
}

zp_ready_show( have, needed )
{
    // No sub-line override on this engine, so the element is written
    // straight. Cleared by the HUD being taken down on resume.
    if ( have < 1 && needed < 1 )
        return;

    if ( isdefined( level.zp_hud_sub ) )
        level.zp_hud_sub settext( "READY  " + have + " / " + needed );
}

/*
    Who armed the pause that is waiting for the round to end, for the line
    telling somebody else they cannot call it off.
*/
zp_pending_name()
{
    if ( isdefined( level.zp_pending_by ) )
        return zp_player_name( level.zp_pending_by );

    return "whoever asked";
}

/*
    The last step of a pause request, once whatever had to agree has agreed.
    Either it happens now, or it waits for the round to be over.

    Both the direct path and a vote that passed come through here. A player
    dropping does not: that calls zp_do_pause() itself, since waiting for
    the round to end is the opposite of what is wanted there.
*/
zp_begin_pause( player )
{
    if ( !level.zp.round_pause )
    {
        level thread zp_do_pause( player );
        return;
    }

    level.zp_pending = 1;
    level.zp_pending_by = player;

    zp_msg_all( "^3[Pause]^7 pausing at the end of the round -- ask again to call it off" );
}

/*
    Fires the held pause at the round boundary.
*/
zp_round_watcher()
{
    level endon( "end_game" );

    for (;;)
    {
        level waittill( "end_of_round" );

        if ( !is_true( level.zp_pending ) )
            continue;

        level.zp_pending = 0;
        by = level.zp_pending_by;
        level.zp_pending_by = undefined;

        zp_load_config();

        if ( is_true( level.zp_paused ) || is_true( level.zp_busy ) || !zp_game_ready() )
            continue;

        level.zp_last_toggle = gettime();
        level thread zp_do_pause( by );
    }
}

zp_ready_clear()
{
    players = get_players();

    for ( i = 0; i < players.size; i++ )
    {
        if ( isdefined( players[i] ) )
            players[i].zp_ready = undefined;
    }

    zp_ready_show( 0, 0 );
}

zp_ready_count()
{
    players = get_players();
    c = 0;

    for ( i = 0; i < players.size; i++ )
    {
        if ( isdefined( players[i] ) && is_true( players[i].zp_ready ) )
            c++;
    }

    return c;
}

zp_ready_needed()
{
    players = get_players();
    n = players.size;

    if ( n < 1 )
        return 1;

    needed = int( ceil( n * level.zp.ready_percent / 100 ) );

    // Never ask for more people than are here to answer.
    if ( needed > n )
        needed = n;

    if ( needed < 1 )
        needed = 1;

    return needed;
}

/*
    Somebody saying they are back. The resume input marks instead of
    resuming while zp_ready_check is on, so the last one to press it is
    what starts the game again.
*/
zp_mark_ready( player )
{
    if ( isdefined( player ) )
    {
        if ( is_true( player.zp_ready ) )
            return;

        player.zp_ready = 1;
        player iprintln( "^2[Pause]^7 you are ready" );
    }

    needed = zp_ready_needed();
    have = zp_ready_count();

    if ( have < needed )
    {
        zp_ready_show( have, needed );
        return;
    }

    zp_ready_show( 0, 0 );
    level.zp_last_toggle = gettime();
    level thread zp_do_unpause( player, "everyone ready" );
}

zp_request_toggle( player )
{
    // A player in a personal pause is always asking to come back, whatever
    // the rest of the game is doing.
    if ( is_true( level.zp_paused ) || ( isdefined( player ) && is_true( player.zp_personal ) ) )
        zp_request_unpause( player );
    else
        zp_request_pause( player );
}

zp_request_pause( player )
{
    /*
        Loaded here as well as below so turning zp_host_only on takes
        effect on the next attempt rather than the one after it.
    */
    zp_load_config();

    // Ahead of zp_host_only and the vote: a personal pause holds nobody
    // but the player asking for it.
    if ( level.zp.personal_pause && isdefined( player ) )
    {
        zp_personal_start( player );
        return;
    }

    if ( zp_host_blocked( player ) )
        return;

    if ( is_true( level.zp_busy ) || is_true( level.zp_paused ) )
        return;

    // A vote already running turns any further pause input into a yes.
    if ( is_true( level.zp_vote_active ) )
    {
        zp_cast_vote( player, 1 );
        return;
    }

    if ( !zp_game_ready() )
    {
        if ( isdefined( player ) )
            player iprintln( "^1[Pause]^7 not available yet" );

        return;
    }

    /*
        A second ask calls off a pause that is waiting for the round to end,
        so the same input both sets it and takes it back.

        Whoever armed it, or the host. It sits ahead of the vote and the
        host-approval gates, so anybody being allowed to cancel meant one
        player quietly undoing what the room had just voted for.
    */
    if ( is_true( level.zp_pending ) )
    {
        if ( isdefined( player ) && isdefined( level.zp_pending_by )
             && player != level.zp_pending_by && !zp_player_is_host( player ) )
        {
            player iprintln( "^1[Pause]^7 only ^3" + zp_pending_name()
                             + "^7 or the host can call that off" );
            return;
        }

        level.zp_pending = 0;
        level.zp_pending_by = undefined;
        zp_msg_all( "^3[Pause]^7 the pause at the end of the round is off" );
        return;
    }

    if ( zp_pauses_spent() )
    {
        if ( isdefined( player ) )
            player iprintln( "^1[Pause]^7 no pauses left this match" );

        return;
    }

    if ( zp_on_cooldown() )
        return;

    zp_load_config();

    if ( zp_vote_wanted( player ) )
    {
        if ( zp_vote_locked_out() )
        {
            if ( isdefined( player ) )
                player iprintln( "^1[Pause]^7 a vote just failed -- wait a moment" );

            return;
        }

        level.zp_last_toggle = gettime();
        level thread zp_vote_start( player, "pause" );
        return;
    }

    level.zp_last_toggle = gettime();
    zp_begin_pause( player );
}

zp_request_unpause( player )
{
    /*
        Loaded here as well as below so turning zp_host_only on takes
        effect on the next attempt rather than the one after it.
    */
    zp_load_config();

    /*
        Coming back from a personal pause answers to nobody, and it is read
        whether or not zp_personal_pause is still on, so turning it off
        cannot leave somebody held with no way out.

        While the whole game is held because nobody was left playing, it is
        the players who paused who bring it back -- zp_personal_watcher()
        resumes it the moment one of them returns. Anybody else pressing
        resume is told as much rather than ignored.
    */
    if ( isdefined( player ) && is_true( player.zp_personal ) )
    {
        zp_personal_resume( player );
        return;
    }

    if ( is_true( level.zp_personal_hold ) )
    {
        if ( isdefined( player ) )
            player iprintln( "^3[Pause]^7 the game comes back when somebody who paused does" );

        return;
    }

    if ( zp_host_blocked( player ) )
        return;

    if ( is_true( level.zp_busy ) || !is_true( level.zp_paused ) )
        return;

    // Same as the pause side: with a vote open, the combo is a ballot.
    if ( is_true( level.zp_vote_active ) )
    {
        zp_cast_vote( player, 1 );
        return;
    }

    /*
        "thread" starts running immediately in GSC, so two toggles landing
        in the same frame would otherwise pause and instantly unpause.
    */
    if ( zp_on_cooldown() )
        return;

    zp_load_config();

    if ( level.zp.ready_check )
    {
        zp_mark_ready( player );
        return;
    }

    if ( level.zp.vote && level.zp.vote_unpause && !zp_vote_is_moot( player ) )
    {
        if ( zp_vote_locked_out() )
        {
            if ( isdefined( player ) )
                player iprintln( "^1[Pause]^7 a vote just failed -- wait a moment" );

            return;
        }

        level.zp_last_toggle = gettime();
        level thread zp_vote_start( player, "unpause" );
        return;
    }

    level.zp_last_toggle = gettime();
    level thread zp_do_unpause( player );
}


/* ==================================================================
    PAUSE
   ================================================================== */

zp_do_pause( player, name )
{
    zp_load_config();

    level.zp_busy = 1;
    level.zp_paused = 1;
    level.zp_pause_start = gettime();

    // name is who to credit when nobody pressed anything -- the personal
    // pauses holding the whole game give "the team".
    level.zp_pauser_name = zp_player_name( player );
    if ( !isdefined( player ) && isdefined( name ) )
        level.zp_pauser_name = name;

    /*
        Only a pause somebody asked for counts against zp_max_pauses. An
        automatic one -- a player dropping -- is not theirs to spend.
    */
    if ( isdefined( player ) )
        level.zp_pause_count = level.zp_pause_count + 1;

    zp_ready_clear();

    level.zp_counting_down = undefined;
    level notify( "zp_paused" );

    // 1. Close the spawner gate -- the flag the spawn loop blocks on.
    level.zp_spawn_flag_was_set = 0;
    if ( isdefined( level.flag ) && isdefined( level.flag["spawn_zombies"] ) && flag( "spawn_zombies" ) )
    {
        level.zp_spawn_flag_was_set = 1;
        flag_clear( "spawn_zombies" );
    }

    // 2. Hold every AI in place. With no engine freeze to fall back on,
    //    this thread is the freeze rather than a guard around one.
    level thread zp_ai_enforcer();

    if ( level.zp.stop_anims )
        level thread zp_anim_stopper();

    // 3. Lock the players, and keep them locked.
    players = get_players();
    for ( i = 0; i < players.size; i++ )
        players[i] zp_freeze_player();

    if ( level.zp.control_guard )
        level thread zp_player_enforcer();

    if ( level.zp.freeze_bleedout )
        level thread zp_bleedout_enforcer();

    if ( level.zp.freeze_powerups )
        zp_powerups_hold();

    if ( level.zp.freeze_effects )
    {
        zp_effects_hold();
        level thread zp_effects_enforcer();
    }

    /*
        4. Tell everybody -- unless this is zp_vote_hold's provisional
        pause, where the vote HUD is the one on screen. zp_vote_start()
        takes the pause HUD down for that reason, and putting it straight
        back left the banner naming the resume combo while that same
        combo was a yes vote. zp_vote_finish() gives it back if the vote
        carries.
    */
    if ( !is_true( level.zp_vote_provisional ) )
        level thread zp_hud_show();

    zp_msg_all( "^3[Pause]^7 game paused by ^3" + level.zp_pauser_name );
    level thread zp_sound_all( level.zp.pause_sound );

    /*
        Not for the whole-game hold the personal pauses make: each of
        those has zp_max_pause_time running on its own, and the first to
        run out brings a player back and the game with them. Timing this
        one as well resumed a game with everybody still away, which the
        watcher paused again straight away, over and over.
    */
    if ( level.zp.max_pause_time > 0 && !is_true( level.zp_personal_hold ) )
        level thread zp_auto_unpause();

    level.zp_busy = 0;
}


/* ==================================================================
    UNPAUSE
   ================================================================== */

zp_do_unpause( player, label )
{
    level endon( "end_game" );

    /*
        Nothing resumes a game that is already running. The auto-resume
        and a vote that passes can both arrive after the game came back
        -- a resume vote still open when zp_max_pause_time expires is the
        way in -- and without this the second one runs the whole thing
        again in live play: the chat line, then the countdown with
        everybody held still and the sound on every second of it.
    */
    if ( !is_true( level.zp_paused ) )
        return;

    level.zp_busy = 1;

    name = zp_player_name( player );

    if ( !isdefined( player ) )
    {
        name = "auto-resume";

        if ( isdefined( label ) )
            name = label;
    }

    zp_msg_all( "^2[Pause]^7 resuming -- requested by ^2" + name );

    // Everything stays frozen for the whole countdown, so nobody gets to
    // reposition against held zombies.
    cd = level.zp.countdown;

    // Anyone who was roaming is locked for the countdown, so the game
    // comes back from where everybody stands. See zp_hold_controls.
    level.zp_counting_down = 1;
    zp_hold_everyone();

    if ( isdefined( level.zp_hud_sub ) )
        level.zp_hud_sub settext( "hold still" );

    while ( cd > 0 )
    {
        if ( isdefined( level.zp_hud ) )
            level.zp_hud settext( "RESUMING IN " + cd );

        level thread zp_sound_all( level.zp.countdown_sound );
        wait 1;
        cd = cd - 1;
    }

    // Stop every enforcer thread at once, then reverse the pause.
    level notify( "zp_thaw" );

    zp_ai_thaw();
    zp_bleedout_thaw();
    zp_powerups_thaw();

    // Undo what the pause did, not what the setting says now: the config
    // is re-read when a resume is asked for, so zp_freeze_effects 0 typed
    // mid-pause left the insta-kill and double points time this pause
    // held back gone for good. zp_effects_thaw() returns straight away
    // when nothing was held, the way the two thaws above it do.
    zp_effects_thaw();

    players = get_players();
    for ( i = 0; i < players.size; i++ )
        players[i] zp_unfreeze_player();

    if ( is_true( level.zp_spawn_flag_was_set ) )
    {
        if ( isdefined( level.flag ) && isdefined( level.flag["spawn_zombies"] ) )
            flag_set( "spawn_zombies" );
    }
    level.zp_spawn_flag_was_set = 0;

    zp_hud_destroy();

    // A resume vote still open when the game comes back has nothing left
    // to decide, and leaving it open turns every pause request into a
    // ballot on a question that has already been answered.
    if ( is_true( level.zp_vote_active ) )
        zp_vote_stop();

    level thread zp_sound_all( level.zp.resume_sound );

    level.zp_personal_hold = undefined;
    level.zp_paused = 0;
    level.zp_last_toggle = gettime();
    level.zp_busy = 0;

    level notify( "zp_unpaused" );
}

zp_auto_unpause()
{
    level endon( "zp_thaw" );
    level endon( "end_game" );

    wait( level.zp.max_pause_time );

    level thread zp_do_unpause( undefined );
}


/* ==================================================================
    PERSONAL PAUSE

    zp_personal_pause. One player steps out of a game that carries on
    without them: frozen, protected, and ignored by every zombie -- the
    same hold a pause puts on everybody, put on one. The rest play on.

    ignoreme is what keeps the horde off them, and it is enough here:
    get_closest_valid_player() is how every zombie picks a target, and it
    passes is_player_valid() the flag that makes it read ignoreme. The
    AI enforcer is not involved -- nothing is paused but the one player.

    The whole game pauses by itself once nobody is left playing, which is
    everybody else paused as well, or everybody still in it down -- a team
    that went down around somebody who had stepped away is held for them
    rather than lost. zp_personal_watcher() decides that, and resumes it
    the moment a player who paused comes back.
   ================================================================== */

/*
    Whether a player is in the game right now: on their feet, not
    spectating, and not personally paused. The whole game is held when
    this is nobody. Last stand is .revivetrigger, as _laststand.gsc reads
    it -- see zp_player_input_limited().
*/
zp_playable( p )
{
    if ( !isdefined( p ) || is_true( p.zp_personal ) )
        return 0;

    if ( zp_player_is_spectating( p ) )
        return 0;

    if ( isdefined( p.revivetrigger ) || is_true( p.laststand ) )
        return 0;

    return 1;
}

zp_personal_start( player )
{
    if ( is_true( player.zp_personal ) )
        return;

    if ( !zp_game_ready() )
    {
        player iprintln( "^1[Pause]^7 not available yet" );
        return;
    }

    /*
        Not from the floor. Down, the pause would hold the bleedout while
        the team fought on -- a way to never bleed out rather than a way to
        step away. A team that is all down is held anyway, by the watcher.
    */
    if ( !zp_playable( player ) )
    {
        player iprintln( "^1[Pause]^7 not while you are down" );
        return;
    }

    if ( zp_pauses_spent() )
    {
        player iprintln( "^1[Pause]^7 no pauses left this match" );
        return;
    }

    // One press, one pause: the combo is still held on the next frame.
    if ( isdefined( player.zp_personal_last ) && gettime() - player.zp_personal_last < 1000 )
        return;

    player.zp_personal_last = gettime();
    level.zp_pause_count = level.zp_pause_count + 1;

    // Ends a countdown back in that is still running: they are staying.
    player notify( "zp_personal_on" );

    /*
        Set before the freeze. zp_hold_controls() reads it to lock the
        player whatever zp_freeze_players says, and that lock is what moves
        their combo onto the fallback -- see zp_active_combo().
    */
    player.zp_personal = 1;
    player zp_freeze_player();
    player thread zp_personal_enforcer();

    // Under a whole-game pause the pause banner is the one on screen;
    // zp_personal_watcher() puts this back when it ends.
    if ( !is_true( level.zp_paused ) )
        player zp_personal_hud_on();

    if ( level.zp.max_pause_time > 0 )
        player thread zp_personal_timeout();

    if ( level.zp.pause_sound != "" )
        player playlocalsound( level.zp.pause_sound );

    zp_msg_all( "^3[Pause]^7 ^3" + zp_player_name( player ) + "^7 has stepped away -- zombies will leave them be" );
}

/*
    Back from a personal pause. With the game running, they are counted
    in on their own, the same countdown a pause gives everybody. With the
    whole game held, they simply stop being away -- and that is what the
    watcher is waiting for, so the game comes back with them.
*/
zp_personal_resume( player, why )
{
    if ( !is_true( player.zp_personal ) )
        return;

    player.zp_personal_last = gettime();
    player notify( "zp_personal_off" );
    player.zp_personal = undefined;
    player zp_personal_hud_off();

    if ( isdefined( why ) )
        player iprintln( "^3[Pause]^7 " + why );

    if ( is_true( level.zp_paused ) )
    {
        level.zp_personal_back = player;
        return;
    }

    zp_msg_all( "^2[Pause]^7 ^2" + zp_player_name( player ) + "^7 is back" );
    player thread zp_personal_countdown();
}

/*
    iprintlnbold() rather than a HUD element: a bold print is not a
    configstring, so a count per player costs nothing from the pool, and
    it is a live builtin here -- _hud_message.gsc calls it outside any
    devblock.
*/
zp_personal_countdown()
{
    self endon( "disconnect" );
    self endon( "zp_personal_on" );
    level endon( "end_game" );

    for ( i = level.zp.countdown; i > 0; i-- )
    {
        self iprintlnbold( "^2RESUMING IN " + i );

        if ( level.zp.countdown_sound != "" )
            self playlocalsound( level.zp.countdown_sound );

        wait 1;
    }

    // A whole-game pause that began during the count owns them now, and
    // lets them go with everybody else.
    if ( is_true( level.zp_paused ) || is_true( self.zp_personal ) )
        return;

    if ( level.zp.resume_sound != "" )
        self playlocalsound( level.zp.resume_sound );

    self zp_unfreeze_player();
}

/*
    zp_player_enforcer() for one player, for as long as their pause lasts:
    it runs only while the whole game is paused, and a map script that
    lets go of a player mid-pause would otherwise let go of this one too.
*/
zp_personal_enforcer()
{
    self endon( "disconnect" );
    self endon( "zp_personal_off" );
    level endon( "end_game" );

    for (;;)
    {
        self zp_hold_controls();
        self.ignoreme = 1;

        if ( level.zp.godmode )
            self zp_invulnerable();

        wait 0.1;
    }
}

zp_personal_timeout()
{
    self endon( "disconnect" );
    self endon( "zp_personal_off" );
    level endon( "end_game" );

    wait( level.zp.max_pause_time );

    zp_personal_resume( self, "time's up -- you're back in" );
}

/*
    What a personally paused player sees, over their own blackout: that
    they are paused and how to come back. Client elements made through
    zp_menu_text(), so both are counted into level.hudelem_count as they
    are made, and dropped through zp_hud_drop() -- the host's menu sizes
    itself from that count. The strings are fixed, one pair per combo
    setting, which keeps them to a handful of configstrings however many
    players use them.

    The combo named is the one a locked player can press, which on the
    default is the use + aim fallback: a frozen player cannot change
    stance, and a personal pause is always frozen.
*/
zp_personal_hud_on()
{
    self zp_personal_hud_off();

    title = self zp_menu_text( "default", 2.5, "center", 0, -20 );
    title.color = ( 1, 1, 1 );
    title.sort = 1000;
    zp_hud_text( title, "YOU ARE PAUSED" );
    self.zp_personal_title = title;

    hint = self zp_menu_text( "default", 1.25, "center", 0, 12 );
    hint.sort = 1000;

    resume = zp_resume_combo( 1 );

    if ( level.zp.button_combo && resume != "" )
        zp_hud_text( hint, "!unpause  or  " + zp_combo_label( resume, level.zp.hud_binds ) + "  to come back" );
    else
        zp_hud_text( hint, "type !unpause to come back" );

    self.zp_personal_hint = hint;
}

zp_personal_hud_off()
{
    zp_hud_drop( self.zp_personal_title );
    zp_hud_drop( self.zp_personal_hint );
    self.zp_personal_title = undefined;
    self.zp_personal_hint = undefined;
}

/*
    The whole game, held while nobody is left playing and let go the
    moment somebody is. Runs all match; it only ever acts on a pause it
    made itself, which zp_personal_hold marks, so a player dropping or
    anything else that pauses the game is left to end the usual way.
*/
zp_personal_watcher()
{
    level endon( "end_game" );

    for (;;)
    {
        wait 0.25;

        players = get_players();

        /*
            A personally paused player's own banner stands down while the
            whole game is paused -- the pause banner sits in the same
            place and says the same thing -- and comes back after. Only on
            a change, so nothing is made or destroyed on a tick.
        */
        for ( i = 0; i < players.size; i++ )
        {
            p = players[i];

            if ( !isdefined( p ) )
                continue;

            show = is_true( p.zp_personal ) && !is_true( level.zp_paused );

            if ( show && !isdefined( p.zp_personal_title ) )
                p zp_personal_hud_on();
            else if ( !show && isdefined( p.zp_personal_title ) )
                p zp_personal_hud_off();
        }

        if ( is_true( level.zp_busy ) )
            continue;

        away = 0;
        playing = 0;

        for ( i = 0; i < players.size; i++ )
        {
            if ( !isdefined( players[i] ) )
                continue;

            if ( is_true( players[i].zp_personal ) )
                away++;
            else if ( zp_playable( players[i] ) )
                playing++;
        }

        if ( !is_true( level.zp_paused ) )
        {
            if ( away > 0 && playing == 0 && zp_game_ready() )
            {
                // A return recorded under some other pause is not this one's.
                level.zp_personal_back = undefined;
                level.zp_personal_hold = 1;
                level.zp_last_toggle = gettime();
                zp_msg_all( "^3[Pause]^7 nobody is left playing -- the game waits for whoever comes back first" );
                level thread zp_do_pause( undefined, "the team" );
            }

            continue;
        }

        if ( is_true( level.zp_personal_hold ) && ( playing > 0 || away == 0 ) )
        {
            back = level.zp_personal_back;
            level.zp_personal_back = undefined;
            level.zp_personal_hold = undefined;
            level.zp_last_toggle = gettime();

            if ( isdefined( back ) )
                level thread zp_do_unpause( back );
            else
                level thread zp_do_unpause( undefined, "nobody left away" );
        }
    }
}


/* ==================================================================
    AI

    No disablezombies() on this engine, so everything below runs every
    tick for the whole pause rather than backing up an engine freeze.
   ================================================================== */

zp_get_ai()
{
    return getaiarray();
}

zp_ai_enforcer()
{
    level endon( "zp_thaw" );
    level endon( "end_game" );

    for (;;)
    {
        ai = zp_get_ai();

        for ( i = 0; i < ai.size; i++ )
        {
            z = ai[i];

            if ( !isdefined( z ) || !isalive( z ) )
                continue;

            /*
                Stop the game culling zombies for standing still.

                _zombiemode.gsc::round_spawn_failsafe() kills any zombie
                that has not moved 24 units in 30 seconds, assuming it is
                stuck outside the playspace, and a paused zombie trips it
                every time. It skips the kill for anything that tore a
                barrier chunk in the last 8 seconds, so keeping that stamp
                fresh makes the watchdog loop around harmlessly instead of
                firing.

                Deliberately NOT ignore_round_spawn_failsafe, and not
                level.zombie_vars["zombie_use_failsafe"]: either makes the
                watchdog thread return for good, so a zombie that got
                genuinely stuck later would hang the round forever.
            */
            z.lastchunk_destroy_time = gettime();

            // No flag to gate vocals with on this engine -- see
            // zp_silence_zombies in the config. Cut them as they start.
            if ( level.zp.silence_zombies )
                z stopsounds();

            if ( !isdefined( z.zp_anchor ) )
            {
                // First time we have seen this one.
                z.zp_anchor = z.origin;
                z.zp_had_ignoreall = is_true( z.ignoreall );
                z.ignoreall = 1;
                z setgoalpos( z.origin );
                continue;
            }

            if ( !is_true( z.ignoreall ) )
                z.ignoreall = 1;

            if ( level.zp.drift_guard && distancesquared( z.origin, z.zp_anchor ) > level.zp.drift_tolerance )
            {
                z setorigin( z.zp_anchor );
                z setgoalpos( z.zp_anchor );
            }
        }

        wait 0.05;
    }
}

/*
    Deliberately calls the stopanimscripted() builtin on the zombie rather
    than maps\_utility::anim_stopanimscripted(), which routes through
    get_anim_ent() -- that wrapper is for scene animations hung off an anim
    node, which a zombie is not.

    The wrapper does one more thing that does matter though, and skipping
    it is what left zombies stopped for good after the first resume: it
    fires the notifies that release whatever was waiting on the animation
    to finish.

        anim_ent notify( "single anim", "end" );
        anim_ent notify( "looping anim", "end" );

    Without those the zombie's think loop sits waiting for an animation
    that was cancelled and will never report back. They are fired on the
    way out instead of here, in zp_anim_release() -- during the pause the
    whole point is that nothing moves on.
*/
zp_anim_stopper()
{
    level endon( "zp_thaw" );
    level endon( "end_game" );

    for (;;)
    {
        ai = zp_get_ai();

        for ( i = 0; i < ai.size; i++ )
        {
            z = ai[i];

            if ( !isdefined( z ) || !isalive( z ) )
                continue;

            z stopanimscripted();
            z.zp_anim_stopped = 1;
        }

        wait 0.1;
    }
}

/*
    Every notify name a zombies script starts a scripted animation with,
    harvested from AnimScripted( "..." ) across the whole ZM tree.

    They have to be enumerated because there is no generic release: the
    thread that started an animation waits on that animation's own name,
    and stopanimscripted() sends nothing. Covering only the two obvious
    ones is not enough -- window_melee, attack and taunt_anim are all more
    common than tear_anim, so a zombie caught mid-swing would stall exactly
    the way the barrier ones did.
*/
zp_anim_names()
{
    names = [];
    names[ names.size ] = "attack";
    names[ names.size ] = "chestbeat_anim";
    names[ names.size ] = "door_anim";
    names[ names.size ] = "down";
    names[ names.size ] = "emerge_anim";
    names[ names.size ] = "fall";
    names[ names.size ] = "fall_emerge";
    names[ names.size ] = "fall_loop";
    names[ names.size ] = "groundhit_anim";
    names[ names.size ] = "headbutt_anim";
    names[ names.size ] = "jump_anim";
    names[ names.size ] = "land";
    names[ names.size ] = "meleeanim";
    names[ names.size ] = "monkey_steal_exit";
    names[ names.size ] = "napalm_explode";
    names[ names.size ] = "napalm_spawn";
    names[ names.size ] = "nukereact_anim";
    names[ names.size ] = "perk_attack_anim";
    names[ names.size ] = "pulled_in_complete";
    names[ names.size ] = "reactanim";
    names[ names.size ] = "release_anim";
    names[ names.size ] = "return_anim";
    names[ names.size ] = "revive";
    names[ names.size ] = "rise";
    names[ names.size ] = "rollback_anim";
    names[ names.size ] = "setup_done";
    names[ names.size ] = "shrunk_taunt_end";
    names[ names.size ] = "sonic_spawn";
    names[ names.size ] = "sonic_zombie_scream";
    names[ names.size ] = "spear_pain_anim";
    names[ names.size ] = "taunt_anim";
    names[ names.size ] = "tear_anim";
    names[ names.size ] = "tgunreact_anim";
    names[ names.size ] = "throw_back_anim";
    names[ names.size ] = "up";
    names[ names.size ] = "window_melee";
    names[ names.size ] = "zombie_react";
    names[ names.size ] = "zombie_taunt";

    return names;
}

/*
    Hand back every animation the stopper cancelled.

    Cancelling the animation is what freezes the zombie; the thread that
    started it is then left waiting for an end that stopanimscripted()
    never sends, and it waits forever. These notifies release it.

    The notetrack has to ride along as the notify *parameter*, not just be
    the name -- _zombiemode_spawner.gsc's zombie_tear_notetracks() sits in

        self waittill( msg, notetrack );
        if ( notetrack == "end" ) return;

    so a bare notify( "tear_anim" ) simply sends it round the loop again.

    "single anim" and "looping anim" are what maps\_utility's own
    anim_stopanimscripted() fires. Those belong to the _anim scene system,
    which a barrier teardown is not part of -- kept for anything that is.
*/
zp_anim_release()
{
    ai = zp_get_ai();
    names = zp_anim_names();

    // First, every board a held zombie had claimed goes back on the pile --
    // before any zombie is let go, since a released one claims its next
    // board on the spot and that claim has to stand. See zp_drop_claims.
    for ( i = 0; i < ai.size; i++ )
    {
        if ( isdefined( ai[i] ) && is_true( ai[i].zp_anim_stopped ) && zp_at_barrier( ai[i] ) )
            zp_drop_claims( ai[i].first_node.barrier_chunks );
    }

    for ( i = 0; i < ai.size; i++ )
    {
        z = ai[i];

        if ( !isdefined( z ) || !is_true( z.zp_anim_stopped ) )
            continue;

        z.zp_anim_stopped = undefined;

        barrier = zp_at_barrier( z );

        // A zombie taken mid-walk to a window keeps its tear wait: it is
        // released from the barrier, not from here. See zp_walk_back_wanted.
        walk = barrier && zp_walk_back_wanted( z );

        if ( !walk )
        {
            // At its spot. The goal, with the barrier's angles, is what a
            // loop the pause caught still facing up is waiting on; the "end"
            // is what a parked one is waiting on; only one of them has a
            // listener. The "end" goes ahead of every other name: a reach-in
            // through the boards, released by its own name below, starts a
            // fresh tear the moment it returns, and an "end" arriving after
            // that would cut it.
            if ( barrier )
            {
                z.goalradius = 2;
                z setgoalpos( z.attacking_spot, z.first_node.angles );
            }

            z notify( "tear_anim", "end" );
        }

        for ( n = 0; n < names.size; n++ )
        {
            if ( names[n] == "tear_anim" )
                continue;

            z notify( names[n], "end" );
        }

        z notify( "single anim", "end" );
        z notify( "looping anim", "end" );

        if ( isdefined( z.anim_loop_ender ) )
            z notify( z.anim_loop_ender );

        if ( walk )
            z thread zp_walk_back_to_barrier();
    }
}

/*
    Is the pause holding this zombie at a window it has not come through?

    attacking_spot and first_node are set on the way to a barrier and never
    cleared, so on their own they also describe every zombie inside the
    map -- and a window somebody repaired would call one of those back to
    it. find_flesh() names a favourite enemy the moment it starts, which is
    the moment the tear loop returns, and nothing unsets it: a zombie with
    none is still on the outside.
*/
zp_at_barrier( z )
{
    if ( !isdefined( z.attacking_spot ) || !isdefined( z.first_node ) )
        return false;

    if ( !isdefined( z.first_node.barrier_chunks ) || isdefined( z.favoriteenemy ) )
        return false;

    // Through getFunction(), like the powerups. Named directly, the call has
    // to resolve when the script is compiled, and at boot there is no
    // zombiemode tree to resolve it in -- the game stops there.
    destroyed_fn = getfunction( "maps/_zombiemode_utility", "all_chunks_destroyed" );
    if ( !isdefined( destroyed_fn ) )
        return false;

    destroyed = [[ destroyed_fn ]]( z.first_node.barrier_chunks );
    return !destroyed;
}

/*
    Was it still short of its spot when the pause took it?

    The enforcer holds AI by pinning every goal to the spot, and that is the
    only stop lever this engine gives a script. But tear_into_building() in
    _zombiemode_spawner.gsc is sitting in

        self SetGoalPos( self.attacking_spot, self.first_node.angles );
        self waittill( "goal" );

    for every zombie walking to a barrier, and a goal at the zombie's own
    feet satisfies that wait at once. By the time play resumes the tear
    loop is already running, its animation cancelled by the stopper, and
    the "end" sent on the way out is exactly what it is waiting for -- so
    the next AnimScripted() tears wherever the zombie happens to stand.

    Twenty-four units: well past the goal radius the spawner uses, and
    within a single step of the spot, so a zombie that had arrived is left
    alone and one still walking is not.
*/
zp_walk_back_wanted( z )
{
    return distancesquared( z.origin, z.attacking_spot ) > 576;
}

/*
    The board a zombie claims before each tear.

    tear_into_building() puts its chunk into the target_by_zombie state
    before the animation; the "board" notetrack moves it on, and
    check_for_zombie_death() puts it back to repaired 2.5 seconds after the
    tear began if nothing else has. The stopper cancels the animation ahead
    of that notetrack, so a held zombie's board sits in that state until
    the reset -- and the picker only takes a repaired board. This engine's
    loop looks at the barrier again when there is nothing to pick, so a
    stale claim costs a wait at the window rather than the early climb it
    costs on World at War; dropping the claims on the way out skips the
    wait.

    Every zombie at a window is held by the pause, so every claim still on
    a barrier on the way out is from a tear that was cancelled.
*/
zp_drop_claims( chunks )
{
    update_fn = getfunction( "maps/_zombiemode_blockers", "update_states" );
    if ( !isdefined( update_fn ) )
        return;

    for ( c = 0; c < chunks.size; c++ )
    {
        if ( !isdefined( chunks[c] ) || !isdefined( chunks[c].state ) || chunks[c].state != "target_by_zombie" )
            continue;

        chunks[c] [[ update_fn ]]( "repaired" );
    }
}

/*
    Send it the rest of the way, then let the tear loop go round.

    The loop is parked inside zombie_tear_notetracks(), waiting for the
    "end" of a tear the stopper cancelled: this engine's one spawner gives
    the loop's facing wait a one-second timeout, so it is past that and
    into the tear by the time any pause ends. (World at War's three older
    maps wait with no timeout, and that port reads the loop's state off the
    barrier; here there is one answer.) The goal carries the barrier's
    angles, and the "end" is sent once the zombie's own "goal" fires.

    Ends on a new pause: the enforcer would pin the goal again and the
    "goal" that fired would be the wrong one. The next resume looks at the
    zombie afresh and starts this over from wherever it got to.
*/
zp_walk_back_to_barrier()
{
    self endon( "death" );
    level endon( "end_game" );
    level endon( "zp_paused" );

    self.goalradius = 2;
    self setgoalpos( self.attacking_spot, self.first_node.angles );
    self waittill( "goal" );
    wait 0.2;

    self notify( "tear_anim", "end" );
}

zp_ai_thaw()
{
    zp_anim_release();

    ai = zp_get_ai();

    for ( i = 0; i < ai.size; i++ )
    {
        z = ai[i];

        if ( !isdefined( z ) || !isdefined( z.zp_anchor ) )
            continue;

        z.zp_anchor = undefined;

        // Only clear ignoreall if we were the ones who set it.
        if ( !is_true( z.zp_had_ignoreall ) )
            z.ignoreall = 0;

        z.zp_had_ignoreall = undefined;
    }
}


/* ==================================================================
    PLAYERS
   ================================================================== */

zp_connect_watcher()
{
    level endon( "end_game" );

    // Catch anybody who was already in before this script initialised.
    players = get_players();
    for ( i = 0; i < players.size; i++ )
        players[i] thread zp_player_think();

    for (;;)
    {
        level waittill( "connected", player );
        player thread zp_player_think();
    }
}

zp_player_think()
{
    self endon( "disconnect" );
    level endon( "end_game" );

    if ( is_true( self.zp_thinking ) )
        return;

    self.zp_thinking = 1;
    self thread zp_disconnect_watcher();
    self thread zp_button_watcher();
    self thread zp_vote_no_watcher();
    self thread zp_menu_watcher();

    for (;;)
    {
        self waittill( "spawned_player" );

        if ( is_true( level.zp_paused ) )
        {
            // Joined or respawned into a paused game -- freeze them too.
            self zp_freeze_player();
        }
        else if ( level.zp.show_hint && !is_true( self.zp_hinted ) )
        {
            self.zp_hinted = 1;
            self thread zp_hint();
        }
    }
}

zp_hint()
{
    self endon( "disconnect" );
    wait 8;

    if ( level.zp.personal_pause )
    {
        if ( level.zp.button_combo )
            self iprintln( "^3[Pause]^7 type ^3!pause^7 or hold ^3" + zp_combo_label( level.zp.combo )
                           + "^7 to pause yourself -- the game stops once everybody has" );
        else
            self iprintln( "^3[Pause]^7 type ^3!pause^7 to pause yourself -- the game stops once everybody has" );

        return;
    }

    if ( level.zp.button_combo )
        self iprintln( "^3[Pause]^7 hold ^3" + zp_combo_label( level.zp.combo ) + "^7 to pause or resume" );
}

zp_freeze_player()
{
    if ( is_true( self.zp_frozen ) )
        return;

    self.zp_frozen = 1;
    self.zp_had_ignoreme = is_true( self.ignoreme );
    self.ignoreme = 1;
    self zp_hold_controls();

    if ( level.zp.godmode )
        self zp_invulnerable();

    if ( level.zp.blackout )
        self zp_blackout_on();

    if ( level.zp.blur )
        self zp_blur_on();
}

/*
    A per-client element rather than a server one: it covers that player's
    screen, and a spectator following someone else should see what they
    see. "fullscreen" alignment is how T6 does it; no stock T5 script sets
    horzalign at all, so if this engine ignores the value the element falls
    back to a centred 640x480 black rectangle, which still covers most of
    the screen rather than breaking.
*/
zp_blackout_on()
{
    if ( isdefined( self.zp_black ) )
        return;

    self.zp_black = newclienthudelem( self );

    if ( isdefined( level.hudelem_count ) )
        level.hudelem_count++;

    self.zp_black.horzalign = "fullscreen";
    self.zp_black.vertalign = "fullscreen";
    self.zp_black.sort = 50;
    self.zp_black.foreground = 0;
    self.zp_black setshader( "black", 640, 480 );
    self.zp_black.alpha = 0;
    self.zp_black fadeovertime( 0.4 );
    self.zp_black.alpha = level.zp.blackout_alpha;
}

zp_blackout_off()
{
    if ( !isdefined( self.zp_black ) )
        return;

    zp_hud_drop( self.zp_black );
    self.zp_black = undefined;
}

/*
    Same post-process the game runs when you buy a perk, which uses 4.
    1.5 reads as "the game has stepped back" without hiding it. There is
    nothing to destroy on the way out -- it has to be zeroed.
*/
zp_blur_on()
{
    if ( is_true( self.zp_blurred ) || level.zp.blur_amount <= 0 )
        return;

    self.zp_blurred = 1;
    self setblur( level.zp.blur_amount, 0.4 );
}

zp_blur_off()
{
    if ( !is_true( self.zp_blurred ) )
        return;

    self.zp_blurred = undefined;
    self setblur( 0, 0.25 );
}

/*
    What the pause does to a player's controls. Locked in place -- unless
    zp_freeze_players is off, and then they keep moving and looking and
    only their weapons go down, so nobody fights a held zombie. Everybody
    is locked again for the countdown, so the game comes back from where
    they all stand, and the host is locked while the settings menu is open.

    zp_locked records a lock this set, so switching to roaming lets go of
    that and nothing else: a map script's own freezecontrols() -- a ride,
    a cutscene -- is left where it was.
*/
zp_hold_controls()
{
    /*
        A personal pause is always locked, whatever zp_freeze_players says:
        roaming a game that is still running, protected and ignored by
        every zombie, is a way to walk through a round rather than a pause.
    */
    if ( level.zp.freeze_players || is_true( level.zp_counting_down ) || is_true( self.zp_menu_open )
         || is_true( self.zp_personal ) )
    {
        self freezecontrols( 1 );
        self.zp_locked = 1;
        return;
    }

    if ( is_true( self.zp_locked ) )
    {
        self freezecontrols( 0 );
        self.zp_locked = undefined;
    }

    self disableweapons();
    self.zp_weapons_down = 1;
}

zp_release_weapons()
{
    self.zp_locked = undefined;

    if ( !is_true( self.zp_weapons_down ) )
        return;

    self.zp_weapons_down = undefined;
    self enableweapons();
}

zp_hold_everyone()
{
    players = get_players();

    for ( i = 0; i < players.size; i++ )
    {
        if ( isdefined( players[i] ) && is_true( players[i].zp_frozen ) )
            players[i] zp_hold_controls();
    }
}

zp_unfreeze_player()
{
    if ( !is_true( self.zp_frozen ) )
        return;

    // A whole-game resume thaws everybody, and somebody still in a personal
    // pause is not coming back with them. zp_personal_resume() clears the
    // flag before it lets them go.
    if ( is_true( self.zp_personal ) )
        return;

    self.zp_frozen = undefined;
    self freezecontrols( 0 );
    self zp_release_weapons();

    if ( !is_true( self.zp_had_ignoreme ) )
        self.ignoreme = 0;

    self.zp_had_ignoreme = undefined;
    self zp_blackout_off();
    self zp_blur_off();

    // By what the pause did: zp_godmode can be changed in between.
    if ( is_true( self.zp_invulnerable ) )
        self thread zp_grace();
}

zp_grace()
{
    self endon( "disconnect" );

    if ( level.zp.grace > 0 )
        wait( level.zp.grace );

    // If the game was paused again while we were waiting out the grace
    // period, leave the player invulnerable -- the new pause owns them.
    if ( is_true( level.zp_paused ) || is_true( self.zp_frozen ) )
        return;

    self.zp_invulnerable = undefined;
    self disableinvulnerability();
}

/*
    Invulnerability the pause gave, recorded on the player, so that taking
    it away again goes by what was done rather than by zp_godmode.
*/
zp_invulnerable()
{
    self.zp_invulnerable = 1;
    self enableinvulnerability();
}

/*
    The players' half of the AI enforcer. Map scripts that carry a player
    somewhere release their controls when the ride ends, which lands
    mid-pause and hands that player a walk around a frozen game.
    freezecontrols() has no getter, so this re-asserts rather than tests.
*/
zp_player_enforcer()
{
    level endon( "zp_thaw" );
    level endon( "end_game" );

    for (;;)
    {
        players = get_players();

        for ( i = 0; i < players.size; i++ )
        {
            p = players[i];

            if ( !isdefined( p ) || !is_true( p.zp_frozen ) )
                continue;

            p zp_hold_controls();
            p.ignoreme = 1;

            if ( level.zp.godmode )
                p zp_invulnerable();
        }

        wait 0.1;
    }
}


/* ==================================================================
    GROUND POWERUPS

    powerup_timeout() is a plain wait chain -- 15 seconds, then a 40 step
    blink -- so it cannot be held. The thread is cut and restarted on
    resume, which costs a powerup its exact remaining time but never loses
    one to a pause.

    Cutting it means firing its endon, "powerup_grabbed", which also kills
    powerup_grab() and powerup_wobble() on the same entity. All three are
    re-threaded together.

    Skipped for zombie_grabbable powerups: that same notify is waited on by
    powerup_zombie_grab_trigger_cleanup(), which deletes the grab trigger.
    Those keep their original timer rather than risk it.

    The powerups are reached through getFunction() rather than a qualified
    maps\_zombiemode_powerups:: call -- that tree cannot be named at
    compile time from a raw script, the same reason it cannot be included.
   ================================================================== */

/*
    No stock registry of live powerups exists, but every drop announces
    itself, so the list is kept here. Grabbed and timed-out powerups delete
    their entity, so stale slots simply go undefined and are compacted out.
*/
zp_powerup_tracker()
{
    level endon( "end_game" );

    if ( !isdefined( level.zp_powerups ) )
        level.zp_powerups = [];

    for (;;)
    {
        level waittill( "powerup_dropped", powerup );

        live = [];

        for ( i = 0; i < level.zp_powerups.size; i++ )
        {
            if ( isdefined( level.zp_powerups[i] ) )
                live[ live.size ] = level.zp_powerups[i];
        }

        if ( isdefined( powerup ) )
            live[ live.size ] = powerup;

        level.zp_powerups = live;
    }
}

zp_powerups_hold()
{
    if ( !isdefined( level.zp_powerups ) )
        return;

    for ( i = 0; i < level.zp_powerups.size; i++ )
    {
        p = level.zp_powerups[i];

        if ( !isdefined( p ) || is_true( p.zombie_grabbable ) )
            continue;

        p.zp_held = 1;
        p notify( "powerup_grabbed" );
    }
}

zp_powerups_thaw()
{
    if ( !isdefined( level.zp_powerups ) )
        return;

    timeout_fn = getfunction( "maps/_zombiemode_powerups", "powerup_timeout" );
    grab_fn = getfunction( "maps/_zombiemode_powerups", "powerup_grab" );
    wobble_fn = getfunction( "maps/_zombiemode_powerups", "powerup_wobble" );

    for ( i = 0; i < level.zp_powerups.size; i++ )
    {
        p = level.zp_powerups[i];

        if ( !isdefined( p ) || !is_true( p.zp_held ) )
            continue;

        p.zp_held = undefined;

        // The blink loop may have left it mid-hide.
        p show();

        if ( isdefined( timeout_fn ) )
            p thread [[ timeout_fn ]]();

        if ( isdefined( grab_fn ) )
            p thread [[ grab_fn ]]();

        if ( isdefined( wobble_fn ) )
            p thread [[ wobble_fn ]]();
    }
}


/* ==================================================================
    POWERUP EFFECTS

    Every timed powerup keeps a pair of zombie_vars: an "_on" flag and a
    "_time" countdown that Power_up_hud() decrements by 0.1 every 0.1s.
    Pinning the countdowns holds all six on-screen timers at once -- insta
    kill, double points, fire sale, bonfire sale, tesla and minigun --
    without needing to know anything about the effects themselves.

    Holding the HUD is only half of it for the two that change the rules.
    insta_kill_powerup() and double_points_powerup() set a level var, run a
    plain wait( 30 ) and clear it, and that wait keeps running underneath a
    pause. So on resume a bounded thread holds the effect on for whatever
    the frozen countdown says is left, then puts it down -- otherwise the
    effect would expire early, mid-pause, while its timer still read 20
    seconds.
   ================================================================== */

zp_zvar( key )
{
    if ( !isdefined( level.zombie_vars ) )
        return 0;

    if ( !isdefined( level.zombie_vars[ key ] ) )
        return 0;

    return level.zombie_vars[ key ];
}

zp_effect_keys()
{
    keys = [];
    keys[ keys.size ] = "zombie_powerup_insta_kill_time";
    keys[ keys.size ] = "zombie_powerup_point_doubler_time";
    keys[ keys.size ] = "zombie_powerup_fire_sale_time";
    keys[ keys.size ] = "zombie_powerup_bonfire_sale_time";
    keys[ keys.size ] = "zombie_powerup_tesla_time";
    keys[ keys.size ] = "zombie_powerup_minigun_time";

    return keys;
}

/*
    Snapshot each countdown once, then keep writing it back. Whatever is
    decrementing them carries on; it just never gets to keep the result.
*/
zp_effects_enforcer()
{
    level endon( "zp_thaw" );
    level endon( "end_game" );

    if ( !isdefined( level.zombie_vars ) )
        return;

    keys = zp_effect_keys();
    held = [];

    for ( i = 0; i < keys.size; i++ )
    {
        if ( isdefined( level.zombie_vars[ keys[i] ] ) )
            held[ keys[i] ] = level.zombie_vars[ keys[i] ];
    }

    for (;;)
    {
        for ( i = 0; i < keys.size; i++ )
        {
            if ( isdefined( held[ keys[i] ] ) )
                level.zombie_vars[ keys[i] ] = held[ keys[i] ];
        }

        wait 0.05;
    }
}

zp_effects_hold()
{
    level.zp_instakill_left = 0;
    level.zp_points_left = 0;

    if ( zp_zvar( "zombie_insta_kill" ) == 1 )
        level.zp_instakill_left = zp_zvar( "zombie_powerup_insta_kill_time" );

    if ( zp_zvar( "zombie_point_scalar" ) == 2 )
        level.zp_points_left = zp_zvar( "zombie_powerup_point_doubler_time" );
}

zp_effects_thaw()
{
    if ( !isdefined( level.zp_instakill_left ) )
        return;

    if ( level.zp_instakill_left > 0 )
        level thread zp_instakill_extend( level.zp_instakill_left );

    if ( level.zp_points_left > 0 )
        level thread zp_points_extend( level.zp_points_left );

    level.zp_instakill_left = 0;
    level.zp_points_left = 0;
}

/*
    Both extenders end on the same notify the stock thread does, so picking
    a fresh powerup up takes over cleanly instead of fighting them.
*/
zp_instakill_extend( secs )
{
    level endon( "end_game" );
    level endon( "powerup instakill" );

    end = gettime() + int( secs * 1000 );

    while ( gettime() < end )
    {
        level.zombie_vars[ "zombie_insta_kill" ] = 1;
        wait 0.1;
    }

    level.zombie_vars[ "zombie_insta_kill" ] = 0;

    // Same send-off insta_kill_powerup() gives it.
    players = get_players();

    for ( i = 0; i < players.size; i++ )
    {
        if ( isdefined( players[i] ) )
            players[i] notify( "insta_kill_over" );
    }
}

zp_points_extend( secs )
{
    level endon( "end_game" );
    level endon( "powerup points scaled" );

    end = gettime() + int( secs * 1000 );

    while ( gettime() < end )
    {
        level.zombie_vars[ "zombie_point_scalar" ] = 2;
        wait 0.1;
    }

    level.zombie_vars[ "zombie_point_scalar" ] = 1;
}


/* ==================================================================
    BLEEDOUT

    _laststand.gsc::laststand_bleedout() counts self.bleedout_time down
    once a second, so holding the field still holds the countdown. Neater
    than the T6 equivalent, which has no such field to pin.
   ================================================================== */

zp_bleedout_enforcer()
{
    level endon( "zp_thaw" );
    level endon( "end_game" );

    for (;;)
    {
        players = get_players();

        for ( i = 0; i < players.size; i++ )
        {
            p = players[i];

            if ( !isdefined( p ) || !isdefined( p.bleedout_time ) )
                continue;

            /*
                Only somebody actually down. Laststand_Bleedout() sets
                the field once on the way in and nothing clears it
                afterwards, so a player who has been down before is back
                on their feet carrying whatever it counted to -- 0 after
                a full bleedout. Snapshotting that meant going down
                during a pause pinned them at the old number, and at 0
                they bled out the moment the countdown ended. Last stand
                is read the way _laststand.gsc reads it,
                self.revivetrigger, with self.laststand after it in case
                a map sets it, the same as zp_player_input_limited().
            */
            if ( !isdefined( p.revivetrigger ) && !is_true( p.laststand ) )
                continue;

            if ( !isdefined( p.zp_bleedout_held ) )
                p.zp_bleedout_held = p.bleedout_time;

            p.bleedout_time = p.zp_bleedout_held;
        }

        wait 0.05;
    }
}

zp_bleedout_thaw()
{
    players = get_players();

    for ( i = 0; i < players.size; i++ )
    {
        if ( isdefined( players[i] ) )
            players[i].zp_bleedout_held = undefined;
    }
}


/* ==================================================================
    HUD

    Positioned by hand. maps\_hud_util::setPoint() is what the stock
    zombies scripts reach for, but that tree cannot be named from a raw
    script any more than _zombiemode_utility can, so the element's own
    alignment fields do the work instead.

    create_simple_hud() does no parent bookkeeping, which means a plain
    destroy() releases an element properly -- the detach-before-destroy
    dance the T6 build needs is not required here. It does keep a tally,
    though; see zp_hud_drop().
   ================================================================== */

/*
    create_simple_hud() would be the idiomatic call, but it lives in
    maps\_zombiemode_utility, which cannot be included. It is only a thin
    wrapper over the newhudelem() builtin that sets foreground and sort --
    both set below anyway -- so the builtin is used directly and the
    dependency disappears.
*/
/*
    Positioning by hand, since there is no setpoint(). alignx / aligny are
    the element's own anchor -- which doubles as the text alignment, so the
    left and right slots sit flush against their edge -- and horzalign /
    vertalign pick the corner of the screen the offsets are measured from.
*/
zp_hud_place( elem, position, yoff )
{
    if ( !isdefined( elem ) )
        return;

    elem.alignx = "center";
    elem.aligny = "middle";
    elem.horzalign = "center";

    if ( position == "top" )
    {
        elem.vertalign = "top";
        elem.x = 0;
        elem.y = 12 + yoff;
        return;
    }

    if ( position == "middle" )
    {
        elem.vertalign = "middle";
        elem.x = 0;
        elem.y = -40 + yoff;
        return;
    }

    if ( position == "bottom" )
    {
        elem.vertalign = "bottom";
        elem.x = 0;
        elem.y = -124 + yoff;
        return;
    }

    if ( position == "left" )
    {
        elem.alignx = "left";
        elem.horzalign = "left";
        elem.vertalign = "middle";
        elem.x = 24;
        elem.y = -46 + yoff;
        return;
    }

    if ( position == "right" )
    {
        elem.alignx = "right";
        elem.horzalign = "right";
        elem.vertalign = "middle";
        elem.x = -24;
        elem.y = -46 + yoff;
        return;
    }

    // center -- the classic banner spot.
    elem.vertalign = "top";
    elem.x = 0;
    elem.y = 56 + yoff;
}

zp_hud_line( position, yoff, scale, colour )
{
    e = newhudelem();

    // Keep the stock tally honest; _zombiemode_utility counts its own.
    if ( isdefined( level.hudelem_count ) )
        level.hudelem_count++;

    zp_hud_place( e, position, yoff );

    e.fontscale = scale;
    e.color = colour;
    e.sort = 1000;
    e.foreground = 1;
    e.alpha = 1;

    if ( level.zp.hud_glow )
    {
        e.glowcolor = ( 0, 0, 0 );
        e.glowalpha = 0.55;
    }

    return e;
}

/*
    The other half of that tally. _zombiemode_utility counts up in
    create_simple_hud() and back down in destroy_hud(); counting one way
    only would walk the stock readout up by a handful every pause.
*/
zp_hud_drop( elem )
{
    if ( !isdefined( elem ) )
        return;

    if ( isdefined( level.hudelem_count ) )
        level.hudelem_count--;

    elem destroy();
}

/*
    Optional slab behind a block, sorted under the text. Rebuilt rather
    than resized when the block grows, because a shader element is sized
    when it is made.
*/
zp_panel_show( position, height )
{
    if ( !level.zp.hud_panel || height <= 0 )
    {
        zp_panel_destroy();
        return;
    }

    if ( isdefined( level.zp_panel ) && level.zp_panel.zp_h == height )
        return;

    zp_panel_destroy();

    // A line's offset is to its middle, not its top, so the slab needs
    // more clearance above the block than below it.
    pad_top = 20;
    pad_bottom = 10;

    level.zp_panel = newhudelem();

    if ( isdefined( level.hudelem_count ) )
        level.hudelem_count++;

    zp_hud_place( level.zp_panel, position, 0 - pad_top );

    level.zp_panel.aligny = "top";
    level.zp_panel setshader( "black", level.zp.hud_panel_width, int( height + pad_top + pad_bottom ) );

    // Under the text, which sorts at 1000.
    level.zp_panel.sort = 999;
    level.zp_panel.foreground = 1;
    level.zp_panel.zp_h = height;
    level.zp_panel.alpha = level.zp.hud_panel_alpha;
}

zp_panel_destroy()
{
    if ( isdefined( level.zp_panel ) )
    {
        zp_hud_drop( level.zp_panel );
        level.zp_panel = undefined;
    }
}

/*
    A player who is down is on zp_combo_dead, not the combo everybody else
    is reading off the screen, and being told the wrong buttons leaves
    them nothing but the chat commands to act through.

    T6 solves this with a per-client hint line. That does not help here:
    a spectating client draws the HUD of the player it is watching, never
    its own, so the one player who most needs the line is the one who
    cannot be sent it. A shared line everybody sees is what actually
    reaches them, and it only appears while somebody is down.
*/
zp_anyone_down()
{
    players = get_players();

    for ( i = 0; i < players.size; i++ )
    {
        if ( isdefined( players[i] ) && zp_player_input_limited( players[i] ) )
            return 1;
    }

    return 0;
}

zp_down_hint_text( kind )
{
    yes_combo = level.zp.combo_dead;
    no_combo = level.zp.vote_no_combo_dead;

    if ( kind == "vote" )
    {
        if ( yes_combo == "" && no_combo == "" )
            return "while down:  ^2!yes^7  /  ^1!no";

        if ( yes_combo == "" )
            return "while down:  ^2!yes^7  /  ^1" + zp_combo_label( no_combo, level.zp.hud_binds ) + "^7 = no";

        if ( no_combo == "" )
            return "while down:  ^2" + zp_combo_label( yes_combo, level.zp.hud_binds ) + "^7 = yes  /  ^1!no";

        return "while down:  ^2" + zp_combo_label( yes_combo, level.zp.hud_binds ) + "^7 = yes  /  ^1" + zp_combo_label( no_combo, level.zp.hud_binds ) + "^7 = no";
    }

    if ( yes_combo == "" )
        return "while down:  type !unpause";

    return "while down:  !unpause  or  " + zp_combo_label( yes_combo, level.zp.hud_binds );
}

zp_down_line_show( position, yoff, kind )
{
    if ( !level.zp.button_combo || !zp_anyone_down() )
    {
        zp_down_line_destroy();
        return;
    }

    txt = zp_down_hint_text( kind );

    if ( txt == "" )
    {
        zp_down_line_destroy();
        return;
    }

    if ( !isdefined( level.zp_down_line ) )
        level.zp_down_line = zp_hud_line( position, yoff, 1.0, ( 0.85, 0.85, 0.85 ) );

    zp_hud_text( level.zp_down_line, txt );
}

zp_down_line_destroy()
{
    if ( isdefined( level.zp_down_line ) )
    {
        zp_hud_drop( level.zp_down_line );
        level.zp_down_line = undefined;
    }
}

/*
    Picks up players going down or being revived mid-pause, which the
    banner is otherwise too static to notice.
*/
zp_hud_updater()
{
    level endon( "zp_hud_stop" );
    level endon( "zp_thaw" );
    level endon( "end_game" );

    for (;;)
    {
        if ( isdefined( level.zp_hud_clock ) )
            zp_hud_text( level.zp_hud_clock, zp_elapsed_text() );

        zp_down_line_show( level.zp.hud_position, zp_pause_yoff( "down" ), "pause" );

        h = zp_pause_yoff( "sub" ) + 14;

        if ( isdefined( level.zp_down_line ) )
            h = zp_pause_yoff( "down" ) + 10;

        zp_panel_show( level.zp.hud_position, h );

        wait 0.25;
    }
}

/*
    Where each line of the banner sits. The lines below the clock shift up
    when zp_hud_timer is off rather than leaving a hole.
*/
zp_pause_yoff( line )
{
    if ( line == "clock" )
        return 32;

    if ( line == "name" )
        return 54;

    if ( line == "sub" )
    {
        if ( level.zp.hud_timer )
            return 76;

        return 30;
    }

    // "down"
    if ( level.zp.hud_timer )
        return 98;

    return 52;
}

/*
    Minutes, capped. See zp_hud_timer in the config for why it is not
    seconds.
*/
zp_elapsed_text()
{
    secs = int( ( gettime() - level.zp_pause_start ) / 1000 );

    if ( level.zp.max_pause_time > 0 )
        secs = level.zp.max_pause_time - secs;

    if ( secs < 0 )
        secs = 0;

    mins = int( secs / 60 );

    if ( level.zp.max_pause_time > 0 )
    {
        if ( mins > 60 )
            return "over an hour left";

        if ( mins < 1 )
            return "under a minute left";

        if ( mins == 1 )
            return "1 minute left";

        return mins + " minutes left";
    }

    if ( mins > 60 )
        return "over an hour";

    if ( mins < 1 )
        return "under a minute";

    if ( mins == 1 )
        return "1 minute";

    return mins + " minutes";
}

/*
    The pause HUD, a line at a time and each on its own thread.

    One thread for all of it was fine while ZPause was the only mod drawing
    on screen. It is not fine beside others: these elements come out of
    pools the whole server shares -- hudelems and the 488 configstrings a
    distinct settext() costs -- and a game that has run dry does not hand
    back an element, it stops the thread asking for one. Everything after
    that line then never ran, which is how a pause banner came to stand
    there with no clock, no name and no hint under it.

    A line of its own means one that cannot be made costs that line and
    nothing else.
*/
zp_hud_show()
{
    if ( !level.zp.hud )
        return;

    zp_hud_destroy();

    level thread zp_hud_banner_show();

    if ( level.zp.hud_timer )
    {
        level thread zp_hud_clock_show();
        level thread zp_hud_meta_show();
    }

    level thread zp_hud_subline_show();
    level thread zp_hud_updater();
}

zp_hud_banner_show()
{
    level.zp_hud = zp_hud_line( level.zp.hud_position, 0, 2.0, ( 1, 0.82, 0.15 ) );

    if ( !isdefined( level.zp_hud ) )
    {
        zp_hud_missing( "the pause banner" );
        return;
    }

    zp_hud_text( level.zp_hud, "GAME PAUSED" );
}

zp_hud_clock_show()
{
    level.zp_hud_clock = zp_hud_line( level.zp.hud_position, zp_pause_yoff( "clock" ), 1.2, ( 0.85, 0.85, 0.85 ) );

    if ( !isdefined( level.zp_hud_clock ) )
        zp_hud_missing( "the pause clock" );
}

zp_hud_meta_show()
{
    level.zp_hud_meta = zp_hud_line( level.zp.hud_position, zp_pause_yoff( "name" ), 1.0, ( 0.7, 0.7, 0.7 ) );

    if ( !isdefined( level.zp_hud_meta ) )
    {
        zp_hud_missing( "the pause name line" );
        return;
    }

    // One string per person who has ever paused, rather than one a minute.
    zp_hud_text( level.zp_hud_meta, "paused by " + level.zp_pauser_name );
}

zp_hud_subline_show()
{
    level.zp_hud_sub = zp_hud_line( level.zp.hud_position, zp_pause_yoff( "sub" ), 1.4, ( 0.85, 0.85, 0.85 ) );

    if ( !isdefined( level.zp_hud_sub ) )
    {
        zp_hud_missing( "the pause hint" );
        return;
    }

    resume = zp_resume_combo();

    if ( level.zp.button_combo && resume != "" )
        zp_hud_text( level.zp_hud_sub, "!unpause  or  " + zp_combo_label( resume, level.zp.hud_binds ) );
    else
        zp_hud_text( level.zp_hud_sub, "type !unpause to resume" );
}

zp_hud_destroy()
{
    level notify( "zp_hud_stop" );
    zp_down_line_destroy();

    if ( isdefined( level.zp_hud ) )
    {
        zp_hud_drop( level.zp_hud );
        level.zp_hud = undefined;
    }

    if ( isdefined( level.zp_hud_sub ) )
    {
        zp_hud_drop( level.zp_hud_sub );
        level.zp_hud_sub = undefined;
    }

    if ( isdefined( level.zp_hud_clock ) )
    {
        zp_hud_drop( level.zp_hud_clock );
        level.zp_hud_clock = undefined;
    }

    if ( isdefined( level.zp_hud_meta ) )
    {
        zp_hud_drop( level.zp_hud_meta );
        level.zp_hud_meta = undefined;
    }

    zp_panel_destroy();
}

/*
    Threaded at every call site. An alias the map does not carry would
    otherwise take the calling thread down with it, and the unpause path is
    the last thing that should be able to die halfway -- it leaves
    level.zp_busy set and the game paused for good.
*/
zp_sound_all( alias )
{
    if ( !isdefined( alias ) || alias == "" )
        return;

    players = get_players();

    for ( i = 0; i < players.size; i++ )
    {
        if ( isdefined( players[i] ) )
            players[i] playlocalsound( alias );
    }
}

zp_msg_all( txt )
{
    players = get_players();

    for ( i = 0; i < players.size; i++ )
    {
        if ( isdefined( players[i] ) )
            players[i] iprintln( txt );
    }
}


/* ==================================================================
    VOTING

    Ballots live on the players as .zp_vote -- 1 yes, 0 no, undefined for
    not voted yet -- so a disconnect takes its vote with it and every tally
    is recomputed from whoever is actually in the game.

    The watcher owns the lifecycle. It is keyed on a serial rather than an
    endon, because zp_vote_finish() runs inside it and ending the vote from
    in there would kill the thread halfway through its own cleanup.

    Both routes, the same as the T6 build: the combos cast a vote, and so
    do !yes and !no, which is what a player whose combo is not reaching
    the server falls back on.
   ================================================================== */

/*
    Approval mode, and somebody is actually holding the host slot. With no
    host there is nobody to ask, so it stays out of the way rather than
    opening a request that nothing can answer.
*/
zp_host_approving()
{
    return level.zp.host_approve && isdefined( zp_host_player() );
}

zp_player_is_host( player )
{
    host = zp_host_player();

    return isdefined( host ) && isdefined( player ) && player == host;
}

/*
    Whether a pause has to be put to somebody rather than simply done. In
    approval mode everybody but the host is put to the host, whatever
    zp_vote says, and the host's own pause never waits on anyone.
*/
zp_vote_wanted( player )
{
    if ( zp_host_approving() )
        return !zp_player_is_host( player );

    return level.zp.vote && !zp_vote_is_moot( player );
}

zp_vote_eligible( player )
{
    if ( !isdefined( player ) )
        return 0;

    // An approval is a vote of one. See zp_host_approve.
    if ( is_true( level.zp_vote_approval ) )
        return zp_player_is_host( player );

    if ( !level.zp.vote_alive_only )
        return 1;

    return !zp_player_is_spectating( player );
}

zp_vote_electorate()
{
    players = get_players();
    n = 0;

    for ( i = 0; i < players.size; i++ )
    {
        if ( zp_vote_eligible( players[i] ) )
            n++;
    }

    return n;
}

zp_vote_needed()
{
    n = zp_vote_electorate();

    if ( n < 1 )
        return 1;

    needed = level.zp.vote_min;
    pct = int( ceil( n * level.zp.vote_percent / 100 ) );

    if ( pct > needed )
        needed = pct;

    // Never ask for more votes than there are people to cast them.
    if ( needed > n )
        needed = n;

    if ( needed < 1 )
        needed = 1;

    return needed;
}

/*
    A vote the initiator alone already carries is a pause with extra steps
    -- solo play, or any lobby whose threshold lands on one.
*/
zp_vote_is_moot( player )
{
    /*
        With zp_host_only on the host is the only player who can act on a
        pause, so there is nobody to put it to.
    */
    if ( level.zp.host_only && isdefined( zp_host_player() ) )
        return 1;

    if ( !level.zp.vote_initiator_yes )
        return 0;

    // A spectator's automatic yes does not count, so it cannot carry a
    // vote on its own however small the room is.
    if ( !zp_vote_eligible( player ) )
        return 0;

    return zp_vote_needed() <= 1;
}

zp_vote_locked_out()
{
    if ( level.zp.vote_lockout <= 0 )
        return 0;

    if ( level.zp_vote_last_fail == 0 )
        return 0;

    return gettime() - level.zp_vote_last_fail < level.zp.vote_lockout * 1000;
}

zp_vote_count( want )
{
    players = get_players();
    c = 0;

    for ( i = 0; i < players.size; i++ )
    {
        p = players[i];

        if ( isdefined( p ) && isdefined( p.zp_vote ) && p.zp_vote == want && zp_vote_eligible( p ) )
            c++;
    }

    return c;
}

zp_vote_clear_ballots()
{
    players = get_players();

    for ( i = 0; i < players.size; i++ )
    {
        if ( isdefined( players[i] ) )
            players[i].zp_vote = undefined;
    }
}

zp_cast_vote( player, want )
{
    if ( !is_true( level.zp_vote_active ) || !isdefined( player ) )
        return;

    if ( isdefined( player.zp_vote ) && player.zp_vote == want )
        return;

    player.zp_vote = want;

    if ( want )
        player iprintln( "^2[Pause]^7 your vote: ^2yes" );
    else
        player iprintln( "^1[Pause]^7 your vote: ^1no" );
}

zp_vote_start( player, kind )
{
    level.zp_vote_serial = level.zp_vote_serial + 1;
    level.zp_vote_active = 1;
    level.zp_vote_kind = kind;

    /*
        Recorded on the vote rather than read from the dvar while it runs,
        so an ordinary vote opened later cannot inherit an electorate of
        one. Cleared again in zp_vote_stop().
    */
    level.zp_vote_approval = 0;

    if ( kind == "pause" && zp_host_approving() && !zp_player_is_host( player ) )
        level.zp_vote_approval = 1;
    level.zp_vote_end_time = gettime() + int( level.zp.vote_time * 1000 );
    level.zp_vote_initiator = player;
    level.zp_vote_provisional = 0;
    level.zp_vote_name = zp_player_name( player );

    zp_vote_clear_ballots();

    /*
        The vote HUD stands in for the pause HUD while it is open. They
        would otherwise overlap, and the pause HUD's "hold X to resume"
        contradicts the vote, where that same combo is a yes.
    */
    zp_vote_outcome_clear();
    zp_hud_destroy();

    if ( level.zp.vote_initiator_yes && isdefined( player ) )
        player.zp_vote = 1;

    verb = "pause";
    if ( kind == "unpause" )
        verb = "resume";

    if ( is_true( level.zp_vote_approval ) )
        zp_msg_all( "^3[Pause]^7 ^3" + level.zp_vote_name + "^7 is asking the host to pause" );
    else
        zp_msg_all( "^3[Pause]^7 ^3" + level.zp_vote_name + "^7 called a vote to " + verb );

    /*
        Not with zp_round_pause: holding the game the moment the vote
        opens is the one thing that setting exists to prevent, and the
        pause the vote is asking for is meant to land at the round
        boundary. The vote runs without the hold and arms it on the way
        out, the same as a pause nobody voted on.
    */
    if ( level.zp.vote_hold && kind == "pause" && !level.zp.round_pause
         && !is_true( level.zp_paused ) )
    {
        level.zp_vote_provisional = 1;
        level thread zp_do_pause( player );
    }

    level thread zp_vote_watcher( level.zp_vote_serial );
}

zp_vote_watcher( serial )
{
    level endon( "end_game" );

    for (;;)
    {
        if ( !is_true( level.zp_vote_active ) || level.zp_vote_serial != serial )
            return;

        needed = zp_vote_needed();
        yes = zp_vote_count( 1 );
        no = zp_vote_count( 0 );
        n = zp_vote_electorate();

        left = level.zp_vote_end_time - gettime();
        secs = int( left / 1000 );

        if ( secs < 0 )
            secs = 0;

        zp_vote_hud_update( yes, needed, secs );

        if ( yes >= needed )
        {
            zp_vote_finish( 1, yes, needed );
            return;
        }

        // Enough noes that everyone left saying yes still would not carry it.
        if ( n - no < needed )
        {
            zp_vote_finish( 0, yes, needed );
            return;
        }

        if ( left <= 0 )
        {
            zp_vote_finish( 0, yes, needed );
            return;
        }

        wait 0.1;
    }
}

zp_vote_finish( passed, yes, needed )
{
    kind = level.zp_vote_kind;
    initiator = level.zp_vote_initiator;
    provisional = is_true( level.zp_vote_provisional );

    zp_vote_stop( 1 );

    if ( passed )
    {
        zp_msg_all( "^2[Pause]^7 vote passed ^2" + yes + "^7/" + needed );
        zp_vote_outcome( "^2VOTE PASSED   " + yes + "^7 / " + needed );

        if ( kind == "unpause" )
        {
            level.zp_last_toggle = gettime();
            level thread zp_do_unpause( initiator );
        }
        else if ( !is_true( level.zp_paused ) )
        {
            level.zp_last_toggle = gettime();
            zp_begin_pause( initiator );
        }
        else
        {
            // zp_vote_hold already paused us on the way in; all that is
            // left is to give the pause HUD back.
            level thread zp_hud_show();
        }

        return;
    }

    level.zp_vote_last_fail = gettime();
    zp_msg_all( "^1[Pause]^7 vote failed ^1" + yes + "^7/" + needed );
    zp_vote_outcome( "^1VOTE FAILED   " + yes + "^7 / " + needed );

    // zp_vote_hold pauses on the way in, so a failed vote hands it back
    // -- and hands back the allowance it spent with it. The room voted
    // the pause down; it never had one.
    if ( provisional && is_true( level.zp_paused ) )
    {
        if ( level.zp_pause_count > 0 )
            level.zp_pause_count = level.zp_pause_count - 1;

        level.zp_last_toggle = gettime();
        level thread zp_do_unpause( undefined, "vote failed" );
        return;
    }

    // A resume vote that failed leaves the game paused.
    if ( is_true( level.zp_paused ) )
        level thread zp_hud_show();
}

zp_vote_stop( keep_title )
{
    level.zp_vote_approval = 0;
    level.zp_vote_serial = level.zp_vote_serial + 1;
    level.zp_vote_active = 0;
    level.zp_vote_provisional = 0;
    level.zp_vote_initiator = undefined;

    zp_vote_clear_ballots();

    // Keeping the title lets zp_vote_finish() leave the result standing on
    // it for a moment. Everything under it goes either way.
    if ( is_true( keep_title ) )
    {
        zp_vote_sub_destroy();
        zp_vote_rows_destroy();
        return;
    }

    zp_vote_hud_destroy();
}

/*
    A vote that just vanishes leaves the result in the chat feed, which is
    the one place nobody is looking mid-round.
*/
zp_vote_outcome( txt )
{
    if ( !isdefined( level.zp_vote_hud ) || level.zp.vote_result_time <= 0 )
    {
        zp_vote_hud_destroy();
        return;
    }

    zp_hud_text( level.zp_vote_hud, txt );
    level thread zp_vote_outcome_hold();
}

zp_vote_outcome_hold()
{
    level endon( "end_game" );
    level endon( "zp_vote_outcome_clear" );

    wait( level.zp.vote_result_time );

    zp_vote_hud_destroy();
}

zp_vote_outcome_clear()
{
    level notify( "zp_vote_outcome_clear" );
    zp_vote_hud_destroy();
}


/* ==================================================================
    SETTINGS MENU

    The host changes settings while the game is paused, without a console.
    Only while paused, and not while a vote is open -- the host needs these
    buttons back to vote. The host is held in place while it is open, so
    none of them does anything in the game at the same time.

    Hold fire + melee to open it. Aim and fire move through the list,
    grenade changes the setting, melee closes it.

    Never use. Use is how a player buys, opens and picks up, and World at
    War has no script call that keeps it off a trigger; the same menu on
    every port means none of them reads it. Fire + melee is the one pair of
    what is left that no port offers as a pause combo. With one button to
    change a setting, every change goes forward and wraps: a switch flips,
    a list moves on, a number steps up through a few common values and back
    round to the lowest. Exact values are the console's.

    A change is a setdvar(), the same as typing it into the console, and
    it lands the same way: when play resumes. The pause is built from the
    settings it started with -- the HUD, what is frozen -- and nothing
    rebuilds those in place.

    The rows come from zp_menu_table(), which tools/mk_menu_table.py writes
    from this script's own zp_cfg calls.

    Text costs configstrings (see the HUD notes): every setting name shown
    is one, for the rest of the match. Numbers go through setvalue(), which
    costs none, so the bill is the names and a handful of words -- bounded,
    and paid once. The elements are the host's own and go through the same
    hudelem_count tally as the rest of the HUD.
   ================================================================== */

zp_menu_watcher()
{
    self endon( "disconnect" );
    level endon( "end_game" );

    for (;;)
    {
        wait 0.05;

        if ( is_true( self.zp_menu_open ) || !zp_menu_allowed() || !zp_player_is_host( self ) )
            continue;

        if ( !( self attackbuttonpressed() && self meleebuttonpressed() ) )
            continue;

        held = 0;
        while ( self attackbuttonpressed() && self meleebuttonpressed() && held < level.zp.button_hold_time )
        {
            held = held + 0.05;
            wait 0.05;
        }

        if ( held < level.zp.button_hold_time || !zp_menu_allowed() )
            continue;

        self zp_menu_run();
    }
}

zp_menu_allowed()
{
    if ( !level.zp.menu || !is_true( level.zp_paused ) || is_true( level.zp_busy ) )
        return 0;

    return !is_true( level.zp_vote_active );
}

/*
    Fire + melee, held by the host where the menu could open. The pause
    combo gives way to it: the default combo here is melee while crouched,
    read from the stance rather than a button, so a crouched host opening
    the menu would resume the game at the same time.
*/
zp_menu_combo_held()
{
    if ( !zp_menu_allowed() || !zp_player_is_host( self ) )
        return 0;

    return self attackbuttonpressed() && self meleebuttonpressed();
}

zp_menu_run()
{
    zp_menu_table();

    if ( level.zp_menu_names.size == 0 )
        return;

    self.zp_menu_open = 1;

    // Nothing happens until the buttons that opened it are let go.
    self.zp_menu_last = "held";

    // Roaming or not, the host stands still while it is open.
    if ( is_true( self.zp_frozen ) )
        self zp_hold_controls();

    if ( !isdefined( self.zp_menu_row ) || self.zp_menu_row >= level.zp_menu_names.size )
        self.zp_menu_row = 0;

    self zp_menu_draw_create();
    self zp_menu_draw();

    for (;;)
    {
        wait 0.05;

        if ( !zp_menu_allowed() )
            break;

        input = self zp_menu_input();

        if ( input == "close" )
            break;

        if ( input == "up" )
            self zp_menu_move( -1 );
        else if ( input == "down" )
            self zp_menu_move( 1 );
        else if ( input == "change" )
        {
            self zp_menu_change();
            self.zp_menu_dirty = 1;
        }
    }

    self zp_menu_draw_destroy();

    /*
        On the way out, once, and only when something actually changed --
        so opening the menu to look at it does not quietly adopt whatever
        is currently set into the saved file.
    */
    if ( is_true( self.zp_menu_dirty ) )
    {
        zp_file_write();
        self.zp_menu_dirty = undefined;
    }

    // Melee is half of the default combo: everything the menu reads is let
    // go before the combos are read again.
    while ( self zp_menu_button() != "" )
        wait 0.05;

    self.zp_menu_open = undefined;

    if ( is_true( self.zp_frozen ) )
        self zp_hold_controls();
}

/*
    One action per press. Moving repeats while the button is held, so a
    long list can be run through without tapping; changing and closing
    never repeat.
*/
zp_menu_input()
{
    b = self zp_menu_button();

    if ( b == "" )
    {
        self.zp_menu_last = "";
        return "";
    }

    if ( self.zp_menu_last == "held" )
        return "";

    now = gettime();

    if ( self.zp_menu_last != b )
    {
        self.zp_menu_last = b;
        self.zp_menu_repeat = now + 400;
        return b;
    }

    if ( b != "up" && b != "down" )
        return "";

    if ( now < self.zp_menu_repeat )
        return "";

    self.zp_menu_repeat = now + 120;
    return b;
}

zp_menu_button()
{
    if ( self meleebuttonpressed() )
        return "close";

    if ( self fragbuttonpressed() )
        return "change";

    if ( self adsbuttonpressed() )
        return "up";

    if ( self attackbuttonpressed() )
        return "down";

    return "";
}

zp_menu_move( dir )
{
    n = level.zp_menu_names.size;
    self.zp_menu_row = self.zp_menu_row + dir;

    if ( self.zp_menu_row < 0 )
        self.zp_menu_row = n - 1;

    if ( self.zp_menu_row >= n )
        self.zp_menu_row = 0;

    self zp_menu_draw();
}

/*
    Forwards, and round again. A number goes to the next value up from
    wherever it is now, so one set by hand to something in between still
    moves the right way.
*/
zp_menu_change()
{
    i = self.zp_menu_row;
    name = level.zp_menu_names[i];
    kind = level.zp_menu_kinds[i];

    if ( kind == "flag" )
    {
        value = "1";

        if ( getdvarint( name ) != 0 )
            value = "0";
    }
    else if ( kind == "choice" )
    {
        list = strtok( level.zp_menu_values[i], "|" );
        current = zp_menu_word( getdvar( name ) );
        value = list[0];

        for ( c = 0; c < list.size - 1; c++ )
        {
            if ( list[c] == current )
                value = list[c + 1];
        }
    }
    else
    {
        // Literals in the table, not text to parse: World at War has no
        // float(), and the menu is the same on every port.
        current = getdvarfloat( name );
        first = level.zp_menu_firsts[i];
        value = level.zp_menu_nums[first];

        for ( c = first + level.zp_menu_counts[i] - 1; c >= first; c-- )
        {
            if ( level.zp_menu_nums[c] > current + 0.001 )
                value = level.zp_menu_nums[c];
        }

        value = "" + value;
    }

    setdvar( name, value );
    self zp_menu_draw();
}

// Nothing is "none", which zp_cfg_str() reads back as nothing.
zp_menu_word( value )
{
    if ( value == "" )
        return "none";

    return value;
}

/*
    How many rows the element allowance leaves room for.

    A player is sent only so many HUD elements at once, and past that the
    newest are silently not drawn. Nothing asks the engine how many are
    left, so the stock tally is the nearest thing there is:
    level.hudelem_count is what create_simple_hud() keeps, and this script,
    stock and anything else well behaved all count into it. Read before the
    menu builds anything, it is what is already on screen -- the pause HUD,
    the blackout, a build stamp, another mod's elements.

    What is left goes two elements at a time, a name and a value, once the
    panel, title, section, description and hint line have taken their five.
    Never more than the seven the T6 build shows, and never fewer than the
    four that were still drawing here with a second mod loaded.

    The menu drew seven regardless before this, so with anything else on
    screen the bottom rows were built and never appeared -- and the cursor
    walked onto them, which is how a setting could be changed while the
    description line named it and nothing else did.
*/
zp_menu_rows()
{
    used = 0;

    if ( isdefined( level.hudelem_count ) )
        used = level.hudelem_count;

    rows = int( ( 20 - used - 5 ) / 2 );

    if ( rows > 7 )
        rows = 7;

    if ( rows < 4 )
        rows = 4;

    return rows;
}

zp_menu_draw_create()
{
    self zp_menu_draw_destroy();

    // Worked out before any element of the menu's own exists, so the tally
    // reads what is already on screen and none of this.
    self.zp_menu_rows_n = zp_menu_rows();

    bg = newclienthudelem( self );

    if ( isdefined( level.hudelem_count ) )
        level.hudelem_count++;

    bg.alignx = "center";
    bg.aligny = "middle";
    bg.horzalign = "center";
    bg.vertalign = "middle";
    bg.x = 0;
    bg.y = 5;

    // Over the pause HUD, whose text sorts at 1000.
    bg.sort = 1001;
    bg.foreground = 1;
    bg setshader( "black", 470, 290 );
    bg.alpha = 0.8;
    self.zp_menu_bg = bg;

    self.zp_menu_title = self zp_menu_text( "objective", 1.5, "center", 0, -120 );
    self.zp_menu_title.color = ( 1, 0.82, 0.15 );
    zp_hud_text( self.zp_menu_title, "ZPAUSE SETTINGS" );

    self.zp_menu_section = self zp_menu_text( "default", 1.2, "center", 0, -95 );

    // What the setting under the cursor does, in the README's own words --
    // the menu table carries the line, cut to the width of the panel.
    self.zp_menu_desc = self zp_menu_text( "default", 1, "center", 0, 100 );
    self.zp_menu_desc.color = ( 0.72, 0.72, 0.72 );

    self.zp_menu_hint = self zp_menu_text( "default", 1.1, "center", 0, 130 );

    self.zp_menu_names_e = [];
    self.zp_menu_values_e = [];

    /*
        Seven rows at most, fewer where the allowance is tight -- see
        zp_menu_rows() above. Moving the menu to the unarchived list
        (archived = false) only made it worse on Black Ops II: four rows
        rather than eight.
    */
    for ( j = 0; j < self.zp_menu_rows_n; j++ )
    {
        self.zp_menu_names_e[j] = self zp_menu_text( "default", 1.2, "left", -215, -65 + j * 22 );
        self.zp_menu_values_e[j] = self zp_menu_text( "default", 1.2, "right", 215, -65 + j * 22 );
    }
}

zp_menu_text( font, scale, alignx, x, y )
{
    e = newclienthudelem( self );

    if ( isdefined( level.hudelem_count ) )
        level.hudelem_count++;

    e.font = font;
    e.fontscale = scale;
    e.alignx = alignx;
    e.aligny = "middle";
    e.horzalign = "center";
    e.vertalign = "middle";
    e.x = x;
    e.y = y;
    e.color = ( 0.85, 0.85, 0.85 );

    // Above the menu's backing, which is over the pause HUD.
    e.sort = 1002;
    e.foreground = 1;
    e.alpha = 1;

    if ( level.zp.hud_glow )
    {
        e.glowcolor = ( 0, 0, 0 );
        e.glowalpha = 0.55;
    }

    return e;
}

zp_menu_draw()
{
    if ( !isdefined( self.zp_menu_names_e ) )
        return;

    n = level.zp_menu_names.size;
    row = self.zp_menu_row;

    // What was actually built, which is the allowance's answer rather than
    // a number written here. The cursor is kept inside it, so it can never
    // reach a row the engine declined to draw.
    shown = self.zp_menu_names_e.size;

    // Keep the chosen row on screen.
    if ( !isdefined( self.zp_menu_top ) )
        self.zp_menu_top = 0;

    if ( row < self.zp_menu_top )
        self.zp_menu_top = row;

    if ( row > self.zp_menu_top + shown - 1 )
        self.zp_menu_top = row - ( shown - 1 );

    zp_hud_text( self.zp_menu_section, level.zp_menu_sections[row] );
    zp_hud_text( self.zp_menu_desc, level.zp_menu_descs[row] );

    if ( level.zp.hud_binds )
        zp_hud_text( self.zp_menu_hint, zp_bind( "ads" ) + " " + zp_bind( "attack" ) + "  move     " + zp_bind( "frag" ) + "  change     " + zp_bind( "melee" ) + "  close" );
    else
        zp_hud_text( self.zp_menu_hint, "aim / fire  move     grenade  change     melee  close" );

    for ( j = 0; j < shown; j++ )
    {
        i = self.zp_menu_top + j;
        name_e = self.zp_menu_names_e[j];
        value_e = self.zp_menu_values_e[j];

        if ( i >= n )
        {
            zp_hud_text( name_e, "" );
            zp_hud_text( value_e, "" );
            continue;
        }

        colour = ( 0.85, 0.85, 0.85 );

        if ( i == row )
            colour = ( 1, 0.82, 0.15 );

        name_e.color = colour;
        value_e.color = colour;

        zp_hud_text( name_e, level.zp_menu_names[i] );
        zp_menu_value( value_e, i );
    }
}

zp_menu_value( e, i )
{
    name = level.zp_menu_names[i];
    kind = level.zp_menu_kinds[i];

    if ( kind == "number" )
    {
        // A number costs no configstring. The text cache has to forget, or
        // the next word written to this element would look unchanged.
        e.zp_txt = undefined;
        e setvalue( getdvarfloat( name ) );
        return;
    }

    if ( kind == "choice" )
    {
        zp_hud_text( e, zp_menu_word( getdvar( name ) ) );
        return;
    }

    if ( getdvarint( name ) != 0 )
        zp_hud_text( e, "on" );
    else
        zp_hud_text( e, "off" );
}

zp_menu_draw_destroy()
{
    zp_hud_drop( self.zp_menu_bg );
    zp_hud_drop( self.zp_menu_title );
    zp_hud_drop( self.zp_menu_section );
    zp_hud_drop( self.zp_menu_desc );
    zp_hud_drop( self.zp_menu_hint );
    self.zp_menu_bg = undefined;
    self.zp_menu_title = undefined;
    self.zp_menu_section = undefined;
    self.zp_menu_desc = undefined;
    self.zp_menu_hint = undefined;

    if ( isdefined( self.zp_menu_names_e ) )
    {
        for ( j = 0; j < self.zp_menu_names_e.size; j++ )
        {
            zp_hud_drop( self.zp_menu_names_e[j] );
            zp_hud_drop( self.zp_menu_values_e[j] );
        }
    }

    self.zp_menu_names_e = undefined;
    self.zp_menu_values_e = undefined;
    self.zp_menu_top = undefined;
    self.zp_menu_rows_n = undefined;
}

// ZP_MENU_BEGIN
/*
    Generated by tools/mk_menu_table.py from this script's zp_cfg calls.
    Never edit by hand. One row per setting the host's menu offers: how
    it changes -- flag, number or choice -- and what it steps through.
*/
zp_menu_table()
{
    if ( isdefined( level.zp_menu_names ) )
        return;

    level.zp_menu_names = [];
    level.zp_menu_kinds = [];
    level.zp_menu_values = [];
    level.zp_menu_sections = [];
    level.zp_menu_descs = [];
    level.zp_menu_firsts = [];
    level.zp_menu_counts = [];
    level.zp_menu_nums = [];

    zp_menu_row( "zp_host_only", "flag", "", "input", "Only the host can pause or resume. Everyone else's chat command and combo are ignored, and a pause never goes..." );
    zp_menu_row( "zp_personal_pause", "flag", "", "input", "The pause input pauses only you, and the game carries on for everyone else; it pauses in full once nobody is..." );
    zp_menu_row( "zp_allow_short_words", "flag", "", "input", "Also accept bare p / u / pause in chat. Off by default so normal conversation can't pause the game." );
    zp_menu_row( "zp_button_combo", "flag", "", "input", "Enable the button combos." );
    zp_menu_row( "zp_combo", "choice", "crouch_melee|jump_use|jump_melee|use_melee|ads_melee|ads_use|throw_use|use_ads|use_attack", "input", "Pause combo." );
    zp_menu_row( "zp_button_hold_time", "number", "", "input", "How long a combo must be held." );
    zp_menu_num( 0.1 ); zp_menu_num( 0.2 ); zp_menu_num( 0.3 ); zp_menu_num( 0.5 ); zp_menu_num( 0.75 ); zp_menu_num( 1 ); zp_menu_num( 1.5 ); zp_menu_num( 2 );
    zp_menu_row( "zp_combo_dead", "choice", "use_ads|none|jump_use|jump_melee|use_melee|ads_melee|ads_use|use_attack|throw_use", "input", "Combo used while downed or spectating. none = chat only." );
    zp_menu_row( "zp_vote_no_combo_dead", "choice", "use_attack|jump_use|jump_melee|use_melee|ads_melee|ads_use|use_ads|throw_use", "input", "The same, for a no vote." );
    zp_menu_row( "zp_ready_check", "flag", "", "voting", "Resuming waits for the players to say they're back. Not a vote - nobody says no and it can't fail, so it..." );
    zp_menu_row( "zp_ready_percent", "number", "", "voting", "How much of the room has to be ready. 100 is everybody." );
    zp_menu_num( 25 ); zp_menu_num( 50 ); zp_menu_num( 75 ); zp_menu_num( 100 );
    zp_menu_row( "zp_host_approve", "flag", "", "voting", "The host pauses at once; anyone else has to ask and the host answers yes or no. It runs as a vote only the..." );
    zp_menu_row( "zp_vote", "flag", "", "voting", "Put pauses to a vote." );
    zp_menu_row( "zp_vote_min", "number", "", "voting", "Minimum yes votes, whatever the player count." );
    zp_menu_num( 1 ); zp_menu_num( 2 ); zp_menu_num( 3 ); zp_menu_num( 4 ); zp_menu_num( 6 ); zp_menu_num( 8 );
    zp_menu_row( "zp_vote_percent", "number", "", "voting", "Percent of players who must vote yes." );
    zp_menu_num( 25 ); zp_menu_num( 34 ); zp_menu_num( 50 ); zp_menu_num( 51 ); zp_menu_num( 67 ); zp_menu_num( 75 ); zp_menu_num( 100 );
    zp_menu_row( "zp_vote_time", "number", "", "voting", "Seconds a vote stays open." );
    zp_menu_num( 10 ); zp_menu_num( 15 ); zp_menu_num( 20 ); zp_menu_num( 30 ); zp_menu_num( 45 ); zp_menu_num( 60 ); zp_menu_num( 90 ); zp_menu_num( 120 );
    zp_menu_row( "zp_vote_unpause", "flag", "", "voting", "Resuming needs a vote too." );
    zp_menu_row( "zp_vote_hold", "flag", "", "voting", "Freeze the game while the vote runs, and resume if it fails." );
    zp_menu_row( "zp_vote_initiator_yes", "flag", "", "voting", "Whoever called the vote counts as a yes." );
    zp_menu_row( "zp_vote_lockout", "number", "", "voting", "Seconds before another vote can be called after one fails." );
    zp_menu_num( 0 ); zp_menu_num( 5 ); zp_menu_num( 10 ); zp_menu_num( 20 ); zp_menu_num( 30 ); zp_menu_num( 60 ); zp_menu_num( 120 );
    zp_menu_row( "zp_vote_alive_only", "flag", "", "voting", "Leave bled-out spectators out of the threshold and the count." );
    zp_menu_row( "zp_vote_hud", "flag", "", "voting", "Show the vote tally on screen." );
    zp_menu_row( "zp_vote_show_voters", "flag", "", "voting", "List each player and how they voted." );
    zp_menu_row( "zp_vote_result_time", "number", "", "voting", "Seconds the result stands on the tally afterwards." );
    zp_menu_num( 0 ); zp_menu_num( 1 ); zp_menu_num( 2 ); zp_menu_num( 3 ); zp_menu_num( 5 ); zp_menu_num( 10 );
    zp_menu_row( "zp_vote_no_combo", "choice", "jump_melee|jump_use|use_melee|ads_melee|ads_use|use_ads|use_attack|throw_use", "voting", "Combo for a no vote." );
    zp_menu_row( "zp_round_pause", "flag", "", "timing", "Hold a pause until the round is over instead of freezing the game mid-horde. Asking again calls it off." );
    zp_menu_row( "zp_max_pauses", "number", "", "timing", "How many times one match can be paused. 0 is no cap. Only a pause somebody asked for spends one - an..." );
    zp_menu_num( 0 ); zp_menu_num( 1 ); zp_menu_num( 2 ); zp_menu_num( 3 ); zp_menu_num( 5 ); zp_menu_num( 10 ); zp_menu_num( 20 );
    zp_menu_row( "zp_pause_on_disconnect", "flag", "", "timing", "Pause when somebody drops, so whoever is left isn't overrun while they rejoin. Nothing un-pauses on its own..." );
    zp_menu_row( "zp_ease", "flag", "", "timing", "No effect on this engine. See below." );
    zp_menu_row( "zp_ease_time", "number", "", "timing", "The same." );
    zp_menu_num( 0 ); zp_menu_num( 0.1 ); zp_menu_num( 0.2 ); zp_menu_num( 0.35 ); zp_menu_num( 0.5 ); zp_menu_num( 0.75 ); zp_menu_num( 1 );
    zp_menu_row( "zp_countdown", "number", "", "timing", "Seconds of 3-2-1 before play resumes." );
    zp_menu_num( 0 ); zp_menu_num( 1 ); zp_menu_num( 2 ); zp_menu_num( 3 ); zp_menu_num( 5 ); zp_menu_num( 10 );
    zp_menu_row( "zp_grace", "number", "", "timing", "Seconds of invulnerability after resuming." );
    zp_menu_num( 0 ); zp_menu_num( 1 ); zp_menu_num( 2 ); zp_menu_num( 3 ); zp_menu_num( 5 ); zp_menu_num( 10 );
    zp_menu_row( "zp_cooldown", "number", "", "timing", "Minimum seconds between toggles." );
    zp_menu_num( 0 ); zp_menu_num( 1 ); zp_menu_num( 2 ); zp_menu_num( 3 ); zp_menu_num( 5 ); zp_menu_num( 10 ); zp_menu_num( 30 );
    zp_menu_row( "zp_max_pause_time", "number", "", "timing", "Auto-resume after N seconds. 0 = unlimited." );
    zp_menu_num( 0 ); zp_menu_num( 60 ); zp_menu_num( 120 ); zp_menu_num( 300 ); zp_menu_num( 600 ); zp_menu_num( 900 ); zp_menu_num( 1800 ); zp_menu_num( 3600 );
    zp_menu_row( "zp_drift_guard", "flag", "", "what gets frozen", "Snap back any AI that still manages to move." );
    zp_menu_row( "zp_stop_anims", "flag", "", "what gets frozen", "Cut scripted animations, so zombies can't finish tearing a barrier through the pause." );
    zp_menu_row( "zp_godmode", "flag", "", "what gets frozen", "Make players invulnerable while paused." );
    zp_menu_row( "zp_freeze_players", "flag", "", "what gets frozen", "Lock players in place while paused. 0 lets them walk around with their weapons down, locked again for the..." );
    zp_menu_row( "zp_control_guard", "flag", "", "what gets frozen", "Re-apply the player freeze every tick." );
    zp_menu_row( "zp_freeze_bleedout", "flag", "", "what gets frozen", "Stop downed players bleeding out." );
    zp_menu_row( "zp_freeze_powerups", "flag", "", "what gets frozen", "Stop ground powerups timing out." );
    zp_menu_row( "zp_freeze_effects", "flag", "", "what gets frozen", "Hold the insta-kill, double points, fire sale, bonfire, tesla and minigun timers." );
    zp_menu_row( "zp_silence_zombies", "flag", "", "what gets frozen", "Stop zombies growling while paused." );
    zp_menu_row( "zp_hud", "flag", "", "presentation", "Draw the pause block at all. The vote HUD is separate and still draws." );
    zp_menu_row( "zp_show_hint", "flag", "", "presentation", "Tell players how to pause when they spawn." );
    zp_menu_row( "zp_hud_timer", "flag", "", "presentation", "Show who paused and how long it's been." );
    zp_menu_row( "zp_hud_position", "choice", "center|top|middle|bottom|left|right", "presentation", "Where the pause banner sits." );
    zp_menu_row( "zp_vote_hud_position", "choice", "top|middle|bottom|left|right|center", "presentation", "Where the vote tally sits." );
    zp_menu_row( "zp_hud_glow", "flag", "", "presentation", "Black glow behind the HUD text." );
    zp_menu_row( "zp_hud_binds", "flag", "", "presentation", "Draw combos as each player's bound buttons instead of words." );
    zp_menu_row( "zp_hud_panel", "flag", "", "presentation", "Black slab behind the whole block." );
    zp_menu_row( "zp_hud_panel_alpha", "number", "", "presentation", "How opaque that slab is." );
    zp_menu_num( 0.2 ); zp_menu_num( 0.35 ); zp_menu_num( 0.45 ); zp_menu_num( 0.6 ); zp_menu_num( 0.8 ); zp_menu_num( 1 );
    zp_menu_row( "zp_hud_panel_width", "number", "", "presentation", "How wide it is, in HUD units." );
    zp_menu_num( 240 ); zp_menu_num( 300 ); zp_menu_num( 340 ); zp_menu_num( 400 ); zp_menu_num( 480 ); zp_menu_num( 560 ); zp_menu_num( 640 );
    zp_menu_row( "zp_blackout", "flag", "", "presentation", "Dim everyone's screen while paused, which keeps the pause text readable over a bright skybox. Raise..." );
    zp_menu_row( "zp_blackout_alpha", "number", "", "presentation", "How far it dims. 0.2 is a light darkening; 1 is fully black." );
    zp_menu_num( 0.1 ); zp_menu_num( 0.2 ); zp_menu_num( 0.35 ); zp_menu_num( 0.5 ); zp_menu_num( 0.65 ); zp_menu_num( 0.8 ); zp_menu_num( 1 );
    zp_menu_row( "zp_blur", "flag", "", "presentation", "Blur everyone's screen while paused." );
    zp_menu_row( "zp_blur_amount", "number", "", "presentation", "Blur strength. 4 is the blur the game runs when you buy a perk." );
    zp_menu_num( 0.5 ); zp_menu_num( 1 ); zp_menu_num( 1.5 ); zp_menu_num( 2 ); zp_menu_num( 3 ); zp_menu_num( 4 ); zp_menu_num( 6 );
    zp_menu_row( "zp_pause_sound", "choice", "zmb_box_poof|none", "presentation", "Played when the game is paused. none = silent." );
}

zp_menu_row( name, kind, values, section, desc )
{
    i = level.zp_menu_names.size;

    level.zp_menu_names[i] = name;
    level.zp_menu_kinds[i] = kind;
    level.zp_menu_values[i] = values;
    level.zp_menu_sections[i] = section;
    level.zp_menu_descs[i] = desc;
    level.zp_menu_firsts[i] = level.zp_menu_nums.size;
    level.zp_menu_counts[i] = 0;
}

// One of the values the row just added steps through.
zp_menu_num( value )
{
    i = level.zp_menu_names.size - 1;

    level.zp_menu_nums[level.zp_menu_nums.size] = value;
    level.zp_menu_counts[i] = level.zp_menu_counts[i] + 1;
}
// ZP_MENU_END

/* ==================================================================
    VOTE HUD

    No timer elements on this engine, so the seconds are part of the text.
    That is bounded -- one string per second value per combo variant, all
    reused -- unlike a clock counting up, which is what exhausts the
    configstring pool.
   ================================================================== */

/*
    A HUD element the engine would not make, said once a match.

    Nothing of ours can fix it: these come out of pools the whole server
    shares, and several mods drawing at once is how one runs dry. What the
    line is for is turning a pause banner with half its text missing into
    something the console says out loud, because every other symptom of
    this looks exactly like a mod that forgot to draw.
*/
zp_hud_missing( what )
{
    if ( is_true( level.zp_hud_warned ) )
        return;

    level.zp_hud_warned = 1;

    /*
        No brackets after a word in the text: audit.py reads a call out of
        a string that has them, and a message is not a call.
    */
    println( "ZPause: the game would not make a HUD element -- " + what + "."
             + " Some of the pause HUD will be missing. This is the server's"
             + " own HUD pool, shared with every other mod drawing on screen." );
}

zp_hud_text( elem, txt )
{
    if ( !isdefined( elem ) )
        return;

    // settext every tick would be pointless network traffic, and every
    // distinct string costs a configstring.
    if ( isdefined( elem.zp_txt ) && elem.zp_txt == txt )
        return;

    elem.zp_txt = txt;
    elem settext( txt );
}

zp_vote_hint_text( secs )
{
    if ( !level.zp.button_combo )
        return "" + secs + "s";

    return "^2" + zp_combo_label( level.zp.combo, level.zp.hud_binds ) + "^7 = yes     ^1" + zp_combo_label( level.zp.vote_no_combo, level.zp.hud_binds ) + "^7 = no     " + secs + "s";
}

zp_vote_hud_update( yes, needed, secs )
{
    if ( !level.zp.vote_hud )
        return;

    if ( !isdefined( level.zp_vote_hud ) )
    {
        level.zp_vote_hud = zp_hud_line( level.zp.vote_hud_position, 0, 1.6, ( 1, 0.82, 0.15 ) );
        level.zp_vote_sub = zp_hud_line( level.zp.vote_hud_position, 26, 1.2, ( 0.85, 0.85, 0.85 ) );
    }

    if ( is_true( level.zp_vote_approval ) )
        title = "PAUSE REQUEST";
    else if ( level.zp_vote_kind == "unpause" )
        title = "RESUME VOTE   ^2" + yes + "^7 / " + needed;
    else
        title = "PAUSE VOTE   ^2" + yes + "^7 / " + needed;

    zp_hud_text( level.zp_vote_hud, title );
    zp_hud_text( level.zp_vote_sub, zp_vote_hint_text( secs ) );

    zp_down_line_show( level.zp.vote_hud_position, 46, "vote" );
    zp_vote_hud_rows();

    h = 40;

    if ( isdefined( level.zp_down_line ) )
        h = 60;

    if ( level.zp.vote_show_voters && get_players().size > 0 )
        h = 66 + get_players().size * 15;

    zp_panel_show( level.zp.vote_hud_position, h );
}

zp_vote_hud_rows()
{
    if ( !isdefined( level.zp_vote_rows ) )
        level.zp_vote_rows = [];

    if ( !level.zp.vote_show_voters )
    {
        zp_vote_rows_destroy();
        return;
    }

    players = get_players();

    // Somebody left: rebuild rather than leave a stale row on screen.
    if ( level.zp_vote_rows.size > players.size )
        zp_vote_rows_destroy();

    for ( i = 0; i < players.size; i++ )
    {
        p = players[i];

        if ( !isdefined( p ) )
            continue;

        if ( !isdefined( level.zp_vote_rows[i] ) )
            level.zp_vote_rows[i] = zp_hud_line( level.zp.vote_hud_position, 66 + i * 15, 1.0, ( 0.85, 0.85, 0.85 ) );

        name = zp_player_name( p );

        if ( !zp_vote_eligible( p ) )
            txt = "^7" + name + "   ^3spectating";
        else if ( !isdefined( p.zp_vote ) )
            txt = "^7" + name + "   ^3-";
        else if ( p.zp_vote == 1 )
            txt = "^7" + name + "   ^2yes";
        else
            txt = "^7" + name + "   ^1no";

        zp_hud_text( level.zp_vote_rows[i], txt );
    }
}

zp_vote_rows_destroy()
{
    if ( !isdefined( level.zp_vote_rows ) )
    {
        level.zp_vote_rows = [];
        return;
    }

    if ( level.zp_vote_rows.size == 0 )
        return;

    for ( i = 0; i < level.zp_vote_rows.size; i++ )
    {
        if ( isdefined( level.zp_vote_rows[i] ) )
            zp_hud_drop( level.zp_vote_rows[i] );
    }

    level.zp_vote_rows = [];
}

zp_vote_sub_destroy()
{
    if ( isdefined( level.zp_vote_sub ) )
    {
        zp_hud_drop( level.zp_vote_sub );
        level.zp_vote_sub = undefined;
    }
}

zp_vote_hud_destroy()
{
    if ( isdefined( level.zp_vote_hud ) )
    {
        zp_hud_drop( level.zp_vote_hud );
        level.zp_vote_hud = undefined;
    }

    zp_vote_sub_destroy();
    zp_vote_rows_destroy();
    zp_down_line_destroy();
    zp_panel_destroy();
}


/* ==================================================================
    THE SHARED MOD API

    Xep's mods find each other on level.zmods: an array keyed by mod id,
    each key a struct saying what that mod is and handing over the few
    things another mod may ask it to do. ZPause's goes up as the script
    finishes loading, and again -- saying enabled 0 -- when zp_enabled is
    off, since "not installed" and "installed and switched off" are
    different answers.

    Nothing outside calls zp_do_pause() or zp_do_unpause(). The requests
    below go in at the same door the chat words and the button combo use, so a pause
    another mod asks for still answers to zp_host_only, the vote, the
    cooldown and zp_max_pauses, and cannot arrive while the game is
    already busy putting one up or taking one down.

    ZPause's public API handoff is the contract. api_version 1 is this.
   ================================================================== */

/*
    The descriptor. Written into whatever registry is already there --
    another mod may have made it first, and replacing the array would be
    that mod's entry gone.
*/
zp_api_register( benabled )
{
    if ( !isdefined( level.zmods ) )
        level.zmods = [];

    if ( !isdefined( level.zmods[ "zpause" ] ) )
        level.zmods[ "zpause" ] = spawnstruct();

    mod = level.zmods[ "zpause" ];

    mod.id = "zpause";
    mod.display_name = "ZPause";
    mod.version = zp_version();
    mod.api_version = 1;
    mod.settings_manifest_version = 1;
    mod.enabled = benabled;

    mod.reload_config = ::zp_api_reload_config;
    mod.request_toggle = ::zp_api_request_toggle;
    mod.request_pause = ::zp_api_request_pause;
    mod.request_unpause = ::zp_api_request_unpause;
    mod.is_paused = ::zp_api_is_paused;
}

/*
    Read the settings again -- for a mod that has just written one of
    ZPause's dvars and wants it to count now rather than at the next
    pause. 1 when there was something to read.
*/
zp_api_reload_config()
{
    if ( !is_true( level.zp_loaded ) || !isdefined( level.zp ) || !level.zp.enabled )
        return 0;

    zp_load_config();
    return 1;
}

/*
    Whether the game is paused. level.zp_paused is ZPause's own field and
    not the contract: this is.
*/
zp_api_is_paused()
{
    if ( is_true( level.zp_paused ) )
        return 1;

    return 0;
}

zp_api_request_toggle( player )
{
    return zp_api_request( player, "toggle" );
}

zp_api_request_pause( player )
{
    return zp_api_request( player, "pause" );
}

zp_api_request_unpause( player )
{
    return zp_api_request( player, "unpause" );
}

/*
    One door for the three above. An undefined initiator is the host
    asking, which is what a press on a menu row is.
*/
zp_api_request( player, what )
{
    if ( !is_true( level.zp_loaded ) || !isdefined( level.zp ) || !level.zp.enabled )
        return 0;

    if ( !isdefined( player ) )
        player = zp_host_player();

    if ( !isdefined( player ) )
        return 0;

    /*
        Threaded, the same as the chat word and the button combo: a request can end up
        waiting on a vote, and a caller is not made to wait with it.
    */
    if ( what == "pause" )
        level thread zp_request_pause( player );
    else if ( what == "unpause" )
        level thread zp_request_unpause( player );
    else
        level thread zp_request_toggle( player );

    return 1;
}


/* ==================================================================
    SAFETY

    If the game ends while paused, tear everything down so nobody is
    left frozen or staring at a stale HUD element.
   ================================================================== */

/* ==================================================================
    BUILD STAMP

    A development build says so on screen: its version and the time it was
    built, top right, under Plutonium's own watermark. Two hours into a
    test session that is the difference between knowing which build you
    are looking at and guessing.

    Release builds carry an empty stamp and draw nothing, so this costs a
    released mod one function call at startup and no HUD element.
   ================================================================== */

/*
    Written by tools/build.py. The line between the markers is generated --
    a version and a build time on a development build, an empty string on
    a release. Do not edit it by hand; the next build will overwrite it.
*/
/*
    The version on its own, without the build time or the word ZPause:
    what level.zmods says ZPause is. Written by tools/build.py between the
    markers, the same as the stamp below, and never by hand.
*/
zp_version()
{
    // ZP_VERSION_BEGIN
    return "1.6";
    // ZP_VERSION_END
}

zp_build()
{
    // ZP_BUILD_BEGIN
    return "";
    // ZP_BUILD_END
}

/*
    Hands the value straight back, so it can wrap a return. Silent unless
    zp_config_printer() has the echo on.
*/
zp_cfg_echo( dvar, value, def )
{
    if ( !is_true( level.zp_cfg_echo ) )
        return value;

    println( "  " + dvar + "  " + value );

    // On screen, only what somebody actually changed. All fifty would
    // scroll off, and the defaults are in the README.
    if ( isdefined( level.zp_cfg_host ) && value != ( "" + def ) )
        level.zp_cfg_host iprintln( "^3" + dvar + "^7  " + value );

    return value;
}

/*
    "set zp_config_print 1" in the console prints every setting and the
    value it is currently holding.

    Black Ops III completes the dvars its engine registered and not the
    ones a script creates, so the zp_ names never show up in its console
    suggestions and there is no GSC call that would add them. This is the
    part that is in reach, and it is worth having on every port.

    The echo rides on zp_cfg_int/float/str rather than a list kept here,
    so a setting added later prints without anyone having to remember it.
*/
/*
    Picks up a dvar changed mid-game.

    zp_load_config() runs on every pause request already, so pausing has
    always used current settings. This is for the ones the input watchers
    read continuously -- zp_combo above all, which without the chat
    commands could not be changed by hand at all, because changing it
    needed a pause and the combo is what asks for one.

    Not while paused or busy: the HUD is built from these when the pause
    starts and nothing rebuilds it in place, so moving them underneath
    would leave elements where the old values put them. It lands as soon
    as play resumes.

    A few dozen dvar reads every five seconds, and no writes once they all
    exist. The tick is only for a setting changed by hand mid-game --
    pausing and resuming both re-read the config themselves, so neither
    ever waits on it.
*/
zp_config_watcher()
{
    level endon( "end_game" );

    for (;;)
    {
        wait 5;

        if ( is_true( level.zp_paused ) || is_true( level.zp_busy ) )
            continue;

        zp_load_config();
    }
}

zp_config_printer()
{
    level endon( "end_game" );

    // Create it, so there is something to set.
    if ( getdvar( "zp_config_print" ) == "" )
        setdvar( "zp_config_print", "0" );

    for ( ;; )
    {
        wait 1;

        if ( getdvar( "zp_config_print" ) != "1" )
            continue;

        setdvar( "zp_config_print", "0" );

        println( "---- ZPause settings ----" );
        /*
            The header and footer are unconditional: they are what
            says the switch was read at all, which is the question
            being asked when somebody reaches for this.
        */
        level.zp_cfg_host = zp_host_player();

        /*
            Any player will do if there is no host to be found. A
            dump nobody can see is the same as no dump, and this is
            reached for precisely when something is already unclear.
        */
        if ( !isdefined( level.zp_cfg_host ) )
        {
            zp_cfg_players = get_players();

            if ( zp_cfg_players.size > 0 )
                level.zp_cfg_host = zp_cfg_players[0];
        }

        if ( isdefined( level.zp_cfg_host ) )
            level.zp_cfg_host iprintln( "^3[ZPause]^7 settings changed from default:" );

        level.zp_cfg_echo = 1;
        zp_load_config();
        level.zp_cfg_echo = 0;

        if ( isdefined( level.zp_cfg_host ) )
            level.zp_cfg_host iprintln( "^3[ZPause]^7 end of settings" );

        level.zp_cfg_host = undefined;
        println( "---- end ----" );
    }
}

zp_build_watermark()
{
    level endon( "end_game" );

    stamp = zp_build();

    if ( stamp == "" )
        return;

    // Nothing can be drawn before the game is actually up.
    while ( !zp_game_ready() )
        wait 0.5;

    if ( isdefined( level.zp_build_hud ) )
        return;

    /*
        Scale 1.1, and not the 0.9 a watermark looks like it wants: a font
        scale below 1 does not shrink the text on any of these engines, it
        falls back to something several times larger. Every other element
        here asks for 1.0 or more, and release_check.py enforces it.

        Offsets are measured from inside the safe area and anything past it
        is clipped, by a different amount per engine and per aspect ratio
        -- which is how this went off screen on three ports and not the
        fourth. 0, 8 is the corner itself.
    */
    e = zp_hud_line( "top", 0, 1.1, ( 1, 0.82, 0.15 ) );
    e.horzalign = "right";
    e.alignx = "right";
    e.aligny = "top";
    e.x = 0;
    e.y = 8;
    e.alpha = 0.7;
    e settext( stamp );

    level.zp_build_hud = e;
}

zp_endgame_safety()
{
    level waittill( "end_game" );

    level notify( "zp_thaw" );

    zp_vote_stop();
    zp_hud_destroy();
    zp_ai_thaw();
    zp_bleedout_thaw();

    players = get_players();
    for ( i = 0; i < players.size; i++ )
    {
        p = players[i];

        if ( !isdefined( p ) )
            continue;

        p zp_blackout_off();
        p zp_blur_off();
        p zp_menu_draw_destroy();
        p.zp_menu_open = undefined;

        // Personal pauses end with the game, the same as the rest of it.
        p notify( "zp_personal_off" );
        p.zp_personal = undefined;
        p zp_personal_hud_off();

        if ( is_true( p.zp_frozen ) )
        {
            p.zp_frozen = undefined;
            p freezecontrols( 0 );
            p zp_release_weapons();

            if ( is_true( p.zp_invulnerable ) )
            {
                p.zp_invulnerable = undefined;
                p disableinvulnerability();
            }
        }
    }

    level.zp_paused = 0;
    level.zp_busy = 0;
}
