Pistonware public changelog

Commits covered:
b0f34c0508fbc2d394269c8668ae86655239ea22
4da133a43acee06d9d3347977440744ef7c84880
df8071bd881d9e05c40e912f9bcef2a7186ab1c6

Added public main, beta, and nightly release channel documentation and publishing workflow.
Added staging branch documentation for pistonware-patches and upstream promotion.
Added upstream channel selection and validated public projection publishing.
Added MotionBlur with configurable strength and cleanup of owned blur effects.
Added PromptChanger for proximity prompt range, hold duration, signal mode, and property mode changes.
Added ProjectileHitbox with configurable projectile hitbox expansion.
Added NoFall support.
Added target priority controls to target-based modules.
Added AFK checking to target-based combat actions.
Added inventory display options to name tags.
Added place range and place block controls to reach functionality.
Added FFlags profile management with add, import, export, paste, and reset actions.
Added profile import and export actions with profile name validation.
Added profile synchronization and profile migration support in the GUI.
Added runtime diagnostics and safer module execution error handling.
Added safer queued teleport reinjection with channel, key, profile, and developer state handoff.
Added compatibility fallbacks for session information and pathfinding services.
Added remote observation support for public game integrations.

Fixed public source delivery by replacing Codeberg URLs with GitHub raw URLs.
Fixed release source selection so main, beta, and nightly metadata follows the selected channel.
Fixed queued developer reinjection authorization by restoring the developer loader before main.lua.
Fixed legacy proximity prompt profile settings by migrating them into PromptChanger.
Fixed invalid profile names by falling back to a usable profile name.
Fixed public export safety by validating the complete allowlist before publishing.
Fixed staging synchronization with themagicpiston/pistonware through the upstream merge commit.

Removed the temporary test.txt file from the public projection.
Removed InteractExtender because it was consolidated into PromptChanger.
Removed FastProxPrompt because it was consolidated into PromptChanger.
Removed Codeberg delivery references because public files now use GitHub delivery.

Public script execution:

Main:
getgenv().PistonwareChannel = 'main'
loadstring(game:HttpGet("https://raw.githubusercontent.com/themagicpiston/pistonware/refs/heads/main/loader.lua", true))()

Beta:
getgenv().PistonwareChannel = 'beta'
loadstring(game:HttpGet("https://raw.githubusercontent.com/themagicpiston/pistonware/refs/heads/beta/loader.lua", true))()

Nightly:
getgenv().PistonwareChannel = 'nightly'
loadstring(game:HttpGet("https://raw.githubusercontent.com/themagicpiston/pistonware/refs/heads/nightly/loader.lua", true))()
