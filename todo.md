# @todo
- Types
    - more :PlatformArena for files
    - less :PointerArithmetic
- Debug UI
    - make better and hopefully unique colors
    - Color per unit/file, Game, Debug, Renderer, Platform
    - Top clocks select a parent to see its children top clocks
    - Frame bars & threads view - add guide lines for ms and frame target ms
    
### Graphics Upgrade
    - Particle Systems
    - Transition to "real" artwork
    - Lighting
    - Font Rendering Robustness - Kerning
    
### Collision detection
    - Clean up predicate proliferation! Can we make a nice clean set of flags/rules so that it's easy to understand how things work in terms of special handling? This may involve making the iteration handle everything instead of handling overlap outside and so on.+-
    - transient collision rules
        - allow non-transient rules to override transient once
        - Entry/Exit
    - Whats the plan for robustness / shape definition ?
    - "Things pushing other things"

### Animation
    - Skeletal animation
### Implement multiple sim regions per frame
    - per-entity clocking
    - sim region merging?  for multiple players?
### AI
    - AI "storage"

## Production
    - Rudimentary worldgen (no quality just "what sorts of things" we do
        - Map displays
        - Placement of background things
        - Connectivity?
            - Large-scale AI Pathfinding?
        - Non-overlapping?
    - Rigorous definition of how things move, when things trigger, etc.
     
    - Metagame / save game?
        - how do you enter a "save slot"?
        - persistent unlocks/etc.
        - Do we allow saved games? Probably yes, just only for "pausing"
        - continuous save for crash recovery?

## Clean up
    - Debug code
        - Diagramming
        - Draw tile chunks so we can verify that things are aligned / in the chunks we want them to be in / etc
    
    - Audio
        - Fix clicking Bug at the end of samples
    
    - Hardware Rendering
        - Shaders?
        - Pixel Buffer Objects for texture downloads?

## Extra Credit
    - Serious Optimization of the software renderer
    