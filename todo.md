# @todo
- Disable sorting for the debug view

- "contextless" should be minimized
- Font Rendering Robustness
    - Kerning
- Types
    - :CutsceneEpisodes
        + 330 36:50-43:50
    - :PlatformArena
    - :DisjointArray
    - :PointerArithmetic
        - change the types to a less c-mindset
        - or if necessary make utilities to these operations

- Z ! :ZHandling
    - debug drawing of Z levels and inclusion of Z to make sure that there are no bugs
    - make sure flying things can go over walls
    - how is going "up" and "down" rendered?
    - Straighten out all coordinate systems!
        - Screen
        - World
        - Texture
        
- Particle Systems

- Transition to "real" artwork
        
- Lighting
    
- Collision detection
    - Clean up predicate proliferation! Can we make a nice clean set of flags/rules so that it's easy to understand how things work in terms of special handling? This may involve making the iteration handle everything instead of handling overlap outside and so on.
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
    - AI "storage"    

## Production
- Rudimentary worldgen (no quality just "what sorts of things" we do
    - Map displays
    - Placement of background things
    - Connectivity?
      - Large-scale AI Pathfinding?
    - Non-overlapping?
 
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
    