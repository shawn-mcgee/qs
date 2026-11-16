# Third language: objectives (draft)

A new language, separate from Quicksilver and from the language in PROPOSALS.md. It starts from zero: nothing from those two documents carries over unless it is restated here.

The language comes with a game engine shipped as a JavaScript library. A page loads the engine with a script tag and creates one or more engine instances. Games are programs run by an instance, written in the language or in js. So is the editor: it is an ordinary application, running live in its own instance, and it can be changed while it runs.

This document records objectives first. Design follows from them. A direction is listed under [Exploring](#exploring) until it is decided, and decisions move to [Decided](#decided). Anything not covered is undecided: do not guess.

## Objectives

### 1. A game engine, shipped as a library

The engine is an application framework for making games. A developer adds it to a page with a script tag and creates instances from js. An instance is a running engine with its own code, state and output. A page can hold several instances, and an error in one does not stop the others.

The editor is a live environment written in the engine's own language and run by the engine. It is not built into the engine: it is an application like any other, and the engine ships nothing that exists only for the editor.

Illustrative only; no names here are decided:

```html
<script src="engine.js"></script>
<script>
  const game   = await Engine.create({ canvas: "#game",   source: "./game/" })
  const editor = await Engine.create({ canvas: "#editor", source: "./editor/" })

  game.state.player.hp = 100                // state is plain data
  const hit = Engine.hitTest(game, 120, 40) // a js tool using the same api as the editor
</script>
```

### 2. Everything is live

Any part of a running program can be changed without restarting it, and that includes the editor.

A change takes effect in the running program, and the program's state survives it unless the change makes that state invalid.

### 3. A broken edit must be survivable

Since the editor can edit itself, an edit can break the tool being used to fix it. The engine must guarantee a way back: a bad edit to the editor must never lock the user out of the editor.

### 4. The bundled language is the best way in, not the only way

The engine comes with a language that covers structure, style, behaviour and GPU code in one place, standing in for HTML, CSS, JS and WGSL. It compiles to js for the host and wgsl for the GPU. It is the best way to write a program for the engine, and it makes common operations and patterns extremely easy.

It is not required. Anything a program can do in the language, it can also do from js, with hand-written wgsl for the GPU. Someone could ignore the language entirely and build a game, or an editor, in js alone. Js only has to make things possible, and may be a little awkward.

The engine itself is written in js or ts.

### 5. Reflection is a public API

Tools can inspect and interact with everything in an instance: its code, its state, what it puts on screen, its time and its input. The editor and the game it edits run in separate instances, and the editor works on the game only through this api.

Tools can be written in js on the host page, or in the language from inside another instance. Both forms offer the same operations.

The editor uses no private api. Anything the editor does, a third-party tool can do.

### 6. Simple and fast, without gotchas

The core api is aggressively simple, and simple code performs well by default, with no hidden traps.

Performance is measured in frames. The cost of a feature should be predictable from the code, and work that happens every frame is never hidden behind something that looks cheap. State is backed by plain js objects, without wrapping or boxing values in the implementation.

### 7. Deterministic on the same device

The same game or scene, run on the same device, always produces the same results. Two different devices are not guaranteed to agree, but one device always agrees with itself.

Nothing in the engine may depend on wall-clock timing, scheduling or other conditions that change from run to run.

### 8. Bring your own pattern

The engine provides primitives, and access to everything it does. It does not impose a way to structure a program. There is no scene tree, entity component system or object model at its core. Out of the box, data is just data.

Patterns such as scene trees and entity component systems can come later as plugins. A plugin is just a library of functions, written in js or in the language, built on the same primitives and public api as any program. Nothing in the engine's core representation depends on one.

### 9. GPU rendering, with a hidden DOM where it helps

What is visible is drawn with WebGPU. The DOM is not a render target.

Where real HTML and CSS are needed, the engine uses a hidden or offscreen DOM: to emulate DOM elements, and to get the browser's help with things like text and scrolling. Other candidates are text input and IME, the clipboard and accessibility.

The editor's code view is the hardest text case the engine has to handle, so text support is measured against it.

### 10. Shaders are written like any other code

Writing a shader looks and feels the same as writing host code: the same syntax, the same functions, the same way of thinking.

The behaviour is not the same, and is not made the same. Host code has js semantics and GPU code has wgsl semantics. Emulating one machine's behaviour on the other makes js slow and hides errors, such as a division by zero that quietly produces a value or an out-of-bounds index that quietly clamps. Guaranteeing identical behaviour on both machines is an anti-pattern.

## Decided

### Layout

The engine has its own layout engine. For layout, the DOM is used only to measure text. Layout never depends on DOM layout, so it can be deterministic and cheap. The layout api itself is not designed yet.

### The compiler is fixed

The compiler is part of the engine. A running program cannot change it. Code it compiles can be edited live, but the compiler itself changes only when the engine is rebuilt.

### Editor and game are separate instances

The editor runs in one engine instance and the game it edits runs in another. The editor reaches the game only through reflection.

### One thread, one GPU device

All instances run on the main thread, in one js realm, and share one GPU device.

- Reflection between instances is ordinary, synchronous access to plain data and library functions.
- The game can draw directly into a texture the editor owns, with no copy.
- Text can be measured through the DOM synchronously.
- An error thrown by one instance's code is caught by the engine and does not stop the others.

Since all js shares one realm, the engine cannot enforce boundaries between instances: any js code can reach any object. The language can still restrict what its own code can name.

### The clock

Rendering is tied to the browser: the engine renders once per `requestAnimationFrame` callback, never more or less often.

Updating runs at a configurable rate with a fixed timestep. On each frame, the engine runs the update zero or more times, as many fixed steps as the elapsed time calls for, and then renders once.

The browser's timestamps are used only to decide how many steps to run. Update code never sees them: it sees the step count and the fixed step length. So what an update computes does not depend on frame timing (objective 7).

- **The update rate is set per instance.** The editor and the game can update at different rates.
- **Determinism comes before real time.** There is a cap on update steps per frame. When an update cannot keep up, the game slows down instead of skipping steps, so results stay the same and only the pace relative to real time changes.
- **Render should not change simulation state.** It may still keep temporary state of its own, including information it records from one frame to the next. The engine does not enforce this.
- **Interpolation belongs to the developer.** The engine has no scene tree ([objective 8](#8-bring-your-own-pattern)), so it cannot interpolate on its own. It gives render the fraction of a step that has elapsed since the last update, and a developer's render pipeline can use it to blend between states it keeps itself.

### Engine callbacks may be generators

Any engine callback may be a generator function, and none has to be. The engine calls the callback, and if it returns a generator, the engine drives it.

Inside an engine-driven generator, `yield` is a **checkpoint**. It means "you may suspend me here", not "suspend now". At each checkpoint the engine either continues straight away or suspends.

The engine decides by **count**: it suspends after a fixed number of checkpoints, never by the clock. Where a frame suspends is therefore the same on every run (objective 7). The cost is that the escape chord's response time depends on how much work each loop step does.

When the engine suspends, it ends the current task and resumes the generator in a new task, within the same frame. The new task is only a wake-up, such as an empty `MessageChannel` message: nothing is copied or serialized, and the suspended generator stays where it is. Suspending happens only when a slice runs long, never in an ordinary frame. Between the two tasks the browser dispatches queued input, so the kernel's key handler can set a panic flag. The engine checks the flag before resuming. If it is set, the engine aborts the generator and opens the rescue screen. This is how the escape chord interrupts a long-running loop on a single thread.

- **Language.** The compiler turns a function into a generator only when it contains an unbounded loop or calls a function that does. It emits a checkpoint every N iterations of such a loop, and `yield*` at each call to such a function. Bounded loops and all other functions compile to plain js.
- **Js.** A developer writes `function*` and `yield` directly. Calling a generator helper without `yield*` silently does nothing. The language cannot make this mistake.
- **Frames.** A frame that suspends is drawn only once all of its update steps and its render have finished. Code after a long loop still runs in the same frame. Other instances keep running and drawing while one is suspended.

### State is plain data, separate from behaviour

State is plain js data: objects, arrays, numbers, strings, booleans and `null`. There are no classes, prototypes, proxies or wrapper objects, and no functions in state. State can always be copied with `structuredClone`, so snapshots and saving need no serialization layer.

Behaviour is entirely separate from state. Every operation is a library function that takes plain data. Objects never refer to code, so live reload never has to migrate them. This holds for the js api as much as for the language.

When a value needs a kind, it carries a `__type__` field naming it, such as `{ __type__: "enemy", ... }`. Library functions and tools such as the inspector use it to decide how to treat the value.

There is no table type in the first version.

## Exploring

### Surviving broken edits (objective 3)

The editor and the game are separate instances, so an error in the game does not stop the editor, and a long loop in language code can be interrupted at a checkpoint. The hard cases are edits the editor makes to itself, edits to libraries the editor shares with the game, and js code that loops without checkpoints.

Ways a self-edit can break the editor:

| failure | example |
| --- | --- |
| compile error | a typo in the inspector |
| fault on load | new init code throws |
| delayed fault | the save command throws, but only when save is pressed |
| hang | a loop never ends; language code reaches checkpoints, a js `while (true)` does not |
| GPU hang | a runaway shader loop loses the WebGPU device |
| wrong but not crashing | paint is transparent, a keybinding is gone, input is misrouted |
| bad state | new code writes garbage into state, and reverting the code does not revert it |
| shared dependency | editing a library the game and the editor both use breaks the editor |
| persisted breakage | the broken version is saved and loads on the next launch |

Candidate defences, in layers:

- **The engine is the kernel.** The js library that runs instances cannot be edited by any program. It owns input, the panic flag, the version store and the rescue screen.
- **Every accepted edit is a version, saved immediately.** Each unit of code keeps a last-known-good version, and rolling back moves a pointer. Saving at acceptance means a reload never loses an edit.
- **State is snapshotted with code.** A rollback restores code and state to the same point.
- **The escape chord.** Handled by the kernel before any program sees it, on a responsive page or at the next checkpoint. It opens a rescue screen: versions, revert, safe-mode boot. The rescue screen can be plain, visible DOM, so it works even when GPU rendering is broken.
- **Safe-mode boot.** Load last-known-good versions. A URL flag such as `?safe` always works, and is the backstop for js that loops without checkpoints.

Two ways to edit the editor:

- **In place, with probation.** The edit applies immediately, and the previous version stays pinned until the new one has proved itself.
- **Through a second instance.** Load the edited editor into a new instance next to the current one, and switch over once it works.

### Suspending safely

Suspending in the middle of a frame lets other tasks run, so the engine needs rules for what may happen in that gap:

- **Engine input handlers only record input.** Input is queued for each instance's next update step. Nothing outside an engine callback touches state, and the core has no events or promises of its own.
- **No overlapping frames.** If the browser asks for a new frame while an instance is suspended, that instance's last finished frame is drawn again. A new frame never starts on top of an unfinished one.
- **The kernel's key handler comes first.** It is registered in the capture phase on `window` before any program code, so no program can stop the chord reaching it.
- **Other instances may see a half-finished frame.** While the game is suspended, the editor can run and read the game's state partway through a frame.
- **No promises in callbacks.** Loading a resource returns a plain handle straight away. Generators are the only way to suspend. What a program sees while a resource is still loading must not depend on how long loading takes (see [Determinism](#determinism-objective-7)).

### Reflection and the public API (objectives 4 and 5)

**The compiler is a client of the public api.** Compiled code uses only the public js api. If the compiler needs a private hook, that is a gap in the api, not a feature of the language. This makes objective 4 true by construction. It also means the api must offer the same fast paths the compiler uses.

**The language's value is at compile time.** Generators and checkpoints, stable object shapes, generated shader bindings and concise syntax: things js could do by hand but nobody would want to.

**The instance api and the reflection api are one api.** Every library function takes the instance it acts on. Calling it on another instance is reflection. Reading another instance's state is reading a plain object.

**Writes land between frames.** Instances run one after another within a frame, so a write from the editor never lands partway through the game's frame, unless the game is suspended at a checkpoint.

**The data model is the contract.** Everything the engine itself holds for an instance is data the api can address. Candidate nouns:

| noun | contents |
| --- | --- |
| modules | source (language or js), compiled output, versions |
| state | plain data, structured however the program likes |
| layout | whatever the layout api produces; it is not designed yet |
| shaders | wgsl plus an interface descriptor |
| resources | textures, fonts, images, sounds |
| clock | step count, step length, update rate, paused |
| input, log, faults | bounded buffers of entries, read with a cursor ("entries since #1042") |

Each of these could have a uniform address, such as `state:/player/hp`, `layout:42` or `module:ui/button`, so a generic inspector can show anything without knowing what it is.

**A published paint contract.** Someone who ignores the language writes wgsl by hand, so the engine publishes the structs it provides to a shader, how uniforms are bound, and the function signature it calls. Compiled wgsl follows exactly the same contract.

**Ownership by module.** Everything a module registers with the engine, such as callbacks and resources, is owned by it. Replacing the module removes what it registered and runs the new version, and state survives because it is plain data outside the module. This makes live reload work for js modules. The language can do finer-grained reload, per definition, because the compiler can see the code's structure.

### Showing one instance inside another

The editor creates a render target, a texture on the shared device, and makes it the game's output. The game draws into it exactly as it would draw to its own canvas, so game code is the same standalone and inside the editor. The editor paints the target like any other texture.

Input in the viewport is mapped to the game's coordinates and given to the game. Overlays such as selection outlines can be drawn by the editor from the game's layout for the same frame, so they never drift from the image.

### Determinism (objective 7)

Sources of run-to-run differences, and candidate answers:

| source | candidate answer |
| --- | --- |
| frame timing: `requestAnimationFrame` timestamps vary | decided: [fixed update steps](#the-clock); the step count, not the clock, is time |
| how many steps run in a frame | varies with timing, so render should not write simulation state, and update should never read what render keeps; otherwise results would depend on the number of frames drawn. A candidate: render keeps its own state, separate from simulation state, which the language could stop update code from reading |
| input timing | input is delivered at step boundaries, and the input for each step is recorded; a live run depends on when a person presses keys, but a replay of recorded input is exact |
| randomness | no `Math.random`; random generators are seeded and their state lives in plain data |
| resource loading | load completion is delivered at a step boundary like input, or a program starts only once its resources have loaded |
| writes from other instances | a write from the editor into the game is treated as input to the game's next step, and recorded |
| suspension | decided by count, so it falls at the same point on every run |
| floating point | the same device, browser and engine version give the same results; nothing more is promised |

Recorded input makes replay possible: the same starting state plus the same recorded input gives the same run. That would also help objective 3, since a bug report could be a replay.

### Layout api

Not designed yet. Earlier sketches of a box primitive and immediate-mode boxes are set aside until the layout api is explored. It has to work without assuming a scene tree (objective 8).

### Observing state (objective 6)

[State is plain data](#state-is-plain-data-separate-from-behaviour). Most of the cost in reactive and reflective systems comes from tracking writes, and if writes are not tracked, plain js objects are both the simplest and the fastest representation.

- **Writes are not tracked.** An assignment compiles to a plain assignment. A game with no tools attached runs at plain js speed.
- **Observers pull.** There is no watch primitive. A tool that shows live values reads them again at a rate it chooses and compares them itself. Whoever observes pays, and only for what they observe.
- **Method syntax, if any, is sugar.** The language could offer `player.heal(10)`, resolved statically to the library call `heal(player, 10)`.
- **Stable shapes.** Objects of one kind always have the same fields, created in the same order, and fields are never deleted. `__type__`, when present, comes first. The language guarantees this for its record types. Js code gets the same speed by following the same rule.
- **Snapshots on demand.** A snapshot is a `structuredClone` of state at a frame boundary, taken before a risky edit, during probation, or when a tool asks.

Costs: observers see a change up to one read late, and miss a change that is undone between two reads; mutation in place means an observer must compare values rather than references, so reads should be narrow; and immutable state is ruled out, since its allocation is worse for games than occasional comparison.

## Open questions

- What is the language called?
- Is code stored in files, in a store, or both?
- What is the text model: plain strings, a document primitive, or both?
- How much of CSS's styling model does the layout api borrow, given that everything must be drawn on the GPU?
- How is text rasterized: a glyph atlas from canvas text, SDF glyphs, or HTML-in-Canvas if it ships?
- Are compute shaders in scope?
- How static is the type system, on the host and on the GPU?
- What is the unit of rollback: an instance or a module?
- How is state addressed: by path from a root, which breaks when arrays reorder, or by stable ids on objects that need identity?
- How does plain state refer to things the engine owns and cannot copy, such as GPU textures, fonts and sounds? Probably a plain handle like `{ __type__: "texture", id: "..." }` that library functions resolve.
- Are typed arrays allowed as state values, for example a mesh's vertices?
- Is `__type__` a free-form string, or drawn from a registry the engine and tools know about?
- Which instances can language code name? Js can reach everything, but the language could prevent a game from naming the editor.
- How often does the compiler emit a checkpoint in an unbounded loop, and how many checkpoints make one slice?
- How is recursion handled? Runaway recursion in js throws a stack overflow rather than hanging, and wgsl forbids recursion.
- What does the layout api look like?
- Is render's own state kept separate from simulation state, and does the language stop update code from reading it?
- What is the cap on update steps per frame, and is it configurable per instance?
- What exactly counts as "the same device": the same hardware, browser version and engine version?
- Who owns the escape chord on a page that embeds the engine for a game, with no editor?
- May programs use the DOM directly, beyond what the engine does with its hidden DOM?
