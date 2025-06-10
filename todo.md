# @todo
- "contextless" is annoying
- Since the correction to unproject_with_transform the sim region bounds are too small
    - Still relevant?
- Font Rendering Robustness
    - Kerning
- Types
    - Whatever Brain.parts is supposed to be
    - :CutsceneEpisodes
    - :PlatformArena
    - :DisjointArray
    - :PointerArithmetic
        - change the types to a less c-mindset
        - or if necessary make utilities to these operations

- Entity System
    - What to do about geografical disperate entities that might only partially get streamed in to a sim region. but which need to move together as a unit?

- Debug code
    - Diagramming
    - Draw tile chunks so we can verify that things are aligned / in the chunks we want them to be in / etc

- Audio
    - Fix clicking Bug at the end of samples

- Rendering
    - Whats the deal with 18000 DrawRectangle calls?!
    - Real projections with solid concept of project/unproject
    - Straighten out all coordinate systems!
        - Screen
        - World
        - Texture
    - Lighting
    - Final Optimization
    - Hardware Rendering
        - Shaders?
        - Render-to-Texture?
    - Pixel Buffer Objects for texture downloads?
    
## Architecture Exploration

- Z ! :ZHandling
    - debug drawing of Z levels and inclusion of Z to make sure
        that there are no bugs
    - Concept of ground in the collision loop so it can handle 
        collisions coming onto and off of stairs, for example
    - make sure flying things can go over walls
    - how is going "up" and "down" rendered?

- Collision detection
    - Clean up predicate proliferation! Can we make a nice clean
        set of flags/rules so that it's easy to understand how
        things work in terms of special handling? This may involve
        making the iteration handle everything instead of handling 
        overlap outside and so on.
    - transient collision rules
        - allow non-transient rules to override transient once
        - Entry/Exit
    - Whats the plan for robustness / shape definition ?
    - "Things pushing other things"

- Animation
    - Skeletal animation
- Implement multiple sim regions per frame
    - per-entity clocking
    - sim region merging?  for multiple players?
    - simple zoomed out view for testing
- AI
    - Pathfinding
    - AI "storage"    

## Production

- Rudimentary worldgen (no quality just "what sorts of things" we do
    - Map displays
    - Placement of background things
    - Connectivity?
    - Non-overlapping?
 
- Metagame / save game?
    - how do you enter a "save slot"?
    - persistent unlocks/etc.
    - Do we allow saved games? Probably yes, just only for "pausing"
    - continuous save for crash recovery?