/*
======================================================================
    ZPAUSE T5 v1.4  --  Synced co-op pause for Black Ops Zombies
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
    getFunction( "maps/_zombiemode_utility", ... ) with a string path.
    Nothing here needs to -- see zp_hud_line().
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

    level thread zp_connect_watcher();
    level thread zp_powerup_tracker();
    level thread zp_endgame_safety();
    level thread zp_round_watcher();
    level thread zp_config_watcher();
    level thread zp_config_printer();
    level thread zp_build_watermark();
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
    level.zp.button_combo      = zp_cfg_int( "zp_button_combo", 1 );
    level.zp.combo             = zp_cfg_str( "zp_combo", "crouch_melee" );
    level.zp.button_hold_time  = zp_cfg_float( "zp_button_hold_time", 0.3 );

    /*
        Down on the floor or spectating, you cannot crouch, so the default
        combo goes dead exactly when a player most wants to say something.
        These are the combos used in that state instead, built from use,
        aim and fire, which stay reachable. Set either to "" to leave that
        state with no button at all -- and note there is no chat on this
        engine to fall back on.
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
        same timeout -- which is also what makes it work on the engines
        with no chat. Narrowing eligibility to the host is what stops the
        asker's own automatic yes from carrying it.

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

        Black Ops 1 has no chat callback, so this is button-only: the
        pause combo votes yes, zp_vote_no_combo votes no, and there is no
        !yes / !no to fall back on.
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
zp_cfg_str( dvar, def )
{
    if ( getdvar( dvar ) == "" )
    {
        setdvar( dvar, def );
        return zp_cfg_echo( dvar, def, def );
    }

    return zp_cfg_echo( dvar, getdvar( dvar ), def );
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
    INPUT

    freezecontrols() blocks movement and weapon use but button state
    still reaches the server, so this keeps working while paused. That is
    what lets a frozen player unpause without any chat command -- which
    matters more here than on T6, because Black Ops 1 has no "say"
    callback to bind chat commands to at all.
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
    they cannot physically press, with no chat to fall back on. The
    .laststand test is kept after it in case a map sets it.
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

    if ( !zp_player_input_limited( self ) )
        return up_combo;

    return dead_combo;
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

        combo = self zp_active_combo( level.zp.combo, level.zp.combo_dead );

        if ( !( self zp_combo_pressed( combo ) ) )
            continue;

        // Require a short hold so the combo cannot be hit by accident.
        held = 0;
        while ( ( self zp_combo_pressed( combo ) ) && held < level.zp.button_hold_time )
        {
            held = held + 0.05;
            wait 0.05;
        }

        if ( held < level.zp.button_hold_time )
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
    if ( is_true( level.gameended ) )
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

    // Read fresh: this waits for the whole match before it decides.
    zp_load_config();

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
    if ( is_true( level.zp_paused ) )
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
    */
    if ( is_true( level.zp_pending ) )
    {
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

zp_do_pause( player )
{
    zp_load_config();

    level.zp_busy = 1;
    level.zp_paused = 1;
    level.zp_pause_start = gettime();

    level.zp_pauser_name = zp_player_name( player );

    /*
        Only a pause somebody asked for counts against zp_max_pauses. An
        automatic one -- a player dropping -- is not theirs to spend.
    */
    if ( isdefined( player ) )
        level.zp_pause_count = level.zp_pause_count + 1;

    zp_ready_clear();

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

    // 4. Tell everybody.
    level thread zp_hud_show();
    zp_msg_all( "^3[Pause]^7 game paused by ^3" + level.zp_pauser_name );
    level thread zp_sound_all( level.zp.pause_sound );

    if ( level.zp.max_pause_time > 0 )
        level thread zp_auto_unpause();

    level.zp_busy = 0;
}


/* ==================================================================
    UNPAUSE
   ================================================================== */

zp_do_unpause( player, label )
{
    level endon( "end_game" );

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

    if ( level.zp.freeze_effects )
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
    level thread zp_sound_all( level.zp.resume_sound );

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

    return !maps\_zombiemode_utility::all_chunks_destroyed( z.first_node.barrier_chunks );
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
    for ( c = 0; c < chunks.size; c++ )
    {
        if ( !isdefined( chunks[c] ) || !isdefined( chunks[c].state ) || chunks[c].state != "target_by_zombie" )
            continue;

        chunks[c] maps\_zombiemode_blockers::update_states( "repaired" );
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
    self freezecontrols( 1 );

    if ( level.zp.godmode )
        self enableinvulnerability();

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

zp_unfreeze_player()
{
    if ( !is_true( self.zp_frozen ) )
        return;

    self.zp_frozen = undefined;
    self freezecontrols( 0 );

    if ( !is_true( self.zp_had_ignoreme ) )
        self.ignoreme = 0;

    self.zp_had_ignoreme = undefined;
    self zp_blackout_off();
    self zp_blur_off();

    if ( level.zp.godmode )
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

    self disableinvulnerability();
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

            p freezecontrols( 1 );
            p.ignoreme = 1;

            if ( level.zp.godmode )
                p enableinvulnerability();
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
    is reading off the screen -- and with no chat on this engine, being
    told the wrong buttons leaves them with no way to act at all.

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
            return "";

        if ( no_combo == "" )
            return "while down:  ^2" + zp_combo_label( yes_combo, level.zp.hud_binds ) + "^7 = yes";

        if ( yes_combo == "" )
            return "while down:  ^1" + zp_combo_label( no_combo, level.zp.hud_binds ) + "^7 = no";

        return "while down:  ^2" + zp_combo_label( yes_combo, level.zp.hud_binds ) + "^7 = yes  /  ^1" + zp_combo_label( no_combo, level.zp.hud_binds ) + "^7 = no";
    }

    if ( yes_combo == "" )
        return "";

    return "while down:  " + zp_combo_label( yes_combo, level.zp.hud_binds );
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

zp_hud_show()
{
    if ( !level.zp.hud )
        return;

    zp_hud_destroy();

    level.zp_hud = zp_hud_line( level.zp.hud_position, 0, 2.0, ( 1, 0.82, 0.15 ) );
    level.zp_hud settext( "GAME PAUSED" );

    if ( level.zp.hud_timer )
    {
        level.zp_hud_clock = zp_hud_line( level.zp.hud_position, zp_pause_yoff( "clock" ), 1.2, ( 0.85, 0.85, 0.85 ) );

        // One string per person who has ever paused, rather than one a minute.
        level.zp_hud_meta = zp_hud_line( level.zp.hud_position, zp_pause_yoff( "name" ), 1.0, ( 0.7, 0.7, 0.7 ) );
        level.zp_hud_meta settext( "paused by " + level.zp_pauser_name );
    }

    level.zp_hud_sub = zp_hud_line( level.zp.hud_position, zp_pause_yoff( "sub" ), 1.4, ( 0.85, 0.85, 0.85 ) );

    level thread zp_hud_updater();

    if ( level.zp.button_combo )
        level.zp_hud_sub settext( "hold " + zp_combo_label( level.zp.combo, level.zp.hud_binds ) + " to resume" );
    else
        level.zp_hud_sub settext( "paused" );
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

    Button-only, unlike the T6 build: Black Ops 1 has no chat callback, so
    there is no !yes / !no and no fallback for a player whose combo is not
    reaching the server.
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

    if ( level.zp.vote_hold && kind == "pause" && !is_true( level.zp_paused ) )
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

    // zp_vote_hold pauses on the way in, so a failed vote hands it back.
    if ( provisional && is_true( level.zp_paused ) )
    {
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
    VOTE HUD

    No timer elements on this engine, so the seconds are part of the text.
    That is bounded -- one string per second value per combo variant, all
    reused -- unlike a clock counting up, which is what exhausts the
    configstring pool.
   ================================================================== */

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
    read continuously -- zp_combo above all, which could not be changed by
    hand at all where there is no chat command, because changing it needed
    a pause and the combo is what asks for one.

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

        if ( is_true( p.zp_frozen ) )
        {
            p.zp_frozen = undefined;
            p freezecontrols( 0 );

            if ( level.zp.godmode )
                p disableinvulnerability();
        }
    }

    level.zp_paused = 0;
    level.zp_busy = 0;
}
