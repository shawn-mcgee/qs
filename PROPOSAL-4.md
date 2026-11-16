# Merged proposal (draft)

One idea, merged from three sources:

- **The language** comes from [PROPOSALS.md](PROPOSALS.md): static types, values that are copied unless `ref` says to share, composites, options and results, and shaders written as functions.
- **The runtime** comes from [PROPOSAL-3.md](PROPOSAL-3.md): an engine shipped as a js library, instances, state as plain data, reflection as a public api, a deterministic clock, and generators for suspension.
- **What code looks like** comes from [example.qs](example.qs), which is newer than both.

How to read this document:

- Where the sources disagree about how code is written, example.qs wins.
- Where they disagree about how a program runs, PROPOSAL-3.md wins.
- A language rule that is not restated here carries over from PROPOSALS.md, rewritten in the new syntax. A runtime rule that is not restated here carries over from PROPOSAL-3.md. [What carries over](#what-carries-over) lists both.
- **Proposed** marks a resolution this document suggests where the sources conflict or are silent. It is not decided.
- Anything else is undecided: do not guess, and check [Open questions](#open-questions).

## The idea

A game engine shipped as a JavaScript library. A page loads it with a script tag and creates one or more engine instances. Each instance runs a program, and the editor is one such program, running live and able to edit itself.

Programs are best written in the bundled language, which covers structure, style, behaviour and GPU code in one place, and compiles to js for the host and wgsl for the GPU. The language is statically typed. Its values are plain data at runtime, so everything the engine promises about state (snapshots, reflection, live reload) holds for language code without a translation layer. Everything the language can do is also possible from js through the same public api.

## Objectives

These are the ten objectives of PROPOSAL-3.md, unchanged in meaning.

1. **A game engine, shipped as a library.** A developer adds it with a script tag and creates instances from js. A page can hold several, and an error in one does not stop the others. The editor is an application like any other, and the engine ships nothing that exists only for it.
2. **Everything is live.** Any part of a running program can be changed without restarting it, including the editor. State survives a change unless the change makes that state invalid.
3. **A broken edit must be survivable.** A bad edit to the editor must never lock the user out of the editor.
4. **The bundled language is the best way in, not the only way.** Anything a program can do in the language, it can do from js with hand-written wgsl. Js only has to make things possible, and may be a little awkward. The engine itself is written in js or ts.
5. **Reflection is a public api.** Tools can inspect and change everything in an instance, from js on the page or from the language inside another instance. The editor uses no private api.
6. **Simple and fast, without gotchas.** The core api is aggressively simple. State is backed by plain js objects, without wrapping or boxing. Work that happens every frame is never hidden behind something that looks cheap.
7. **Deterministic on the same device.** The same game on the same device always produces the same results. Nothing depends on wall-clock timing or scheduling.
8. **Bring your own pattern.** No scene tree, entity component system or object model in the core. Out of the box, data is just data. A plugin is a library of functions, in js or in the language.
9. **GPU rendering, with a hidden DOM where it helps.** What is visible is drawn with WebGPU. A hidden or offscreen DOM emulates DOM elements and helps with text and scrolling.
10. **Shaders are written like any other code.** The same syntax and the same functions. Host code has js semantics and GPU code has wgsl semantics. Guaranteeing identical behaviour on both machines is an anti-pattern.

## What code looks like

This is [example.qs](example.qs), the target for the surface syntax.

```
# this is an example of a "composite"
def Frame {
  atlas: ref tex2d

  # source coordinates
  xy: vec2
  wh: vec2
}

def Sprite {
  frames: [Frame]
  mut frame : num
  mut speed : num

  # destination coordinates
  mut xy: vec2 = <0, 0>
  mut wh: vec2

  # flip across the y axis
  mut flip: bool = false
  # flop across the x axis
  mut flop: bool = false

  fun update(mut self, context: UpdateContext) {
    self.frame += 1
    # ...
  }

  gpu render(self, context: RenderContext) {
    # ...
  }

  fun from_atlas(atlas: ref tex2d, wh: vec2): Sprite {
    # ...
  }
}

# this is an example function
fun say_hello() {
  print("Say Hello")
}

# this is an example function namespace
fun greet {
  () { print("Hello") }
  (name: str) { print("Hello", name) }
}

player_atlas := await load("path/to/atlas")!
mut player := Sprite.from_atlas(player_atlas)

on update (context: UpdateContext) {
  player.update(context)
  # or Sprite.update(player, context)
}

on render (context: RenderContext) {
  player.render(context)
  # or Sprite.render(player, context)
}
```

(Every parameter is typed here, following [the rule](#every-parameter-has-a-type). In example.qs itself, `update`'s and `render`'s `context` and `greet`'s `name` are still untyped.)

What it shows, and where each part comes from:

| in the example | meaning | source |
| --- | --- | --- |
| `def Sprite { ... }` | a composite: named fields, with functions in its namespace | PROPOSALS.md composites, new keyword |
| `mut frame : num`, `mut xy: vec2 = <0, 0>` | immutable by default, `mut` on places, field defaults, vector literals | PROPOSALS.md, unchanged |
| `atlas: ref tex2d` | a texture is shared, never copied, and the field's type says so | PROPOSALS.md, unchanged |
| `fun update(mut self, ...)` | a method that changes its receiver, so the receiver must be mutable | new rule; see [`mut` parameters](#mut-parameters) |
| `gpu render(self, ...)` | a function that runs on the GPU, written like any other, reading a composite that holds a texture | objective 10; replaces `sh`; see [GPU compatibility](#gpu-compatibility-follows-what-a-shader-reads) |
| `player.update(context)` or `Sprite.update(player, context)` | a method call is sugar for a call to a plain function | both documents agree |
| `fun greet { (...) { } (...) { } }` | a function namespace: overloads resolved at compile time | PROPOSALS.md, new keyword |
| `await load("...")!` | loading suspends until the resource is ready, and `!` passes a failure up | `!` from PROPOSALS.md; `await` is new |
| `mut player := ...` at the top level | program state is top-level bindings, holding plain data. With no `@`, it is computed again on every reload | both; see [State](#state-is-the-programs-top-level-bindings) |
| `on update (context: UpdateContext) { ... }` | an engine callback, run at a fixed step | both; new form without `fn` |

## Syntax changes from PROPOSALS.md

The example changes how definitions are written. Everything else in PROPOSALS.md's syntax is unchanged.

| PROPOSALS.md | now | notes |
| --- | --- | --- |
| `Point := type { ... }` | `def Point { ... }` | a composite is a definition, not a binding |
| `add := fn (a: num, b: num) { ... }` | `fun add(a: num, b: num) { ... }` | a named function is a definition |
| `greet := fn { (...) { } }` | `fun greet { (...) { } }` | a function namespace |
| `hypot(self) { ... }` inside a composite | `fun hypot(self) { ... }` | functions in a composite take `fun`, as everywhere else |
| `tint := sh (ctx: Context, ...) { ... }` | `gpu tint(ctx: RenderContext, ...) { ... }` | `gpu` takes the place of `fun` for code that runs on the GPU |
| `move(self: ref mut Point, ...)` | `fun move(mut self, ...)` | see [`mut` parameters](#mut-parameters) |
| `on render fn (ctx: Context) { ... }` | `on render (context: RenderContext) { ... }` | a handler is a parameter list and a body |

Two things follow that the example does not show, and which are [open](#raised-by-exampleqs):

- **Function values.** With `fun` as a definition, a function value written inline needs a form of its own. PROPOSALS.md's `fn (...) { ... }` could stay for that.
- **The `gpu` tag.** PROPOSALS.md used `gpu` as an optional tag asserting that a function or composite is GPU compatible. That word now declares a shader, so the assertion needs another spelling, or is dropped.

## Rule changes from PROPOSALS.md

### Every parameter has a type

Decided, and unchanged from PROPOSALS.md: every parameter is written `name: Type`. The one exception is a method's receiver, `self`, whose type is the composite it is written in.

The two frame callbacks receive different types: `update` an `UpdateContext`, and `render` a `RenderContext`.

### `mut` parameters

Decided. **A parameter marked `mut` can change the caller's value, and the argument must be a mutable place.** Passing anything else is a compile error.

```
fun bump(mut x: num) { x += 1 }

mut n := 0
bump(n)        # n is now 1
k := 0
bump(k)        # error: k is not mut
```

The same rule covers receivers: `fun update(mut self, ...)` can change the value it is called on, and `player.update(context)` needs `player` to be mutable.

What this changes in PROPOSALS.md:

- It takes the place of the `x: ref mut T` parameter, and of `self: ref mut T`.
- `mut` on a parameter no longer means a mutable local copy. A function that wants one makes it in its body: `mut y := x`.
- Nothing at the call marks an argument that may change. The signal is that the argument is `mut` where it is declared: a value that is not `mut` can never be changed by a call.

### Sharing at a call

Decided. **A plain value can be passed to a `ref` parameter without writing `ref`.** The parameter's type decides whether the argument is shared or copied, so `Sprite.update(player, context)` and `Sprite.from_atlas(player_atlas)` are written as they are in the example.

The rest of PROPOSALS.md's "no hidden refs" rule is still under consideration.

**Proposed: `ref` is written only where there is a choice.**

| situation | is there a choice? | written at the use |
| --- | --- | --- |
| an argument to a `ref` parameter | no: the parameter's type says to share | nothing |
| an argument to a `mut` parameter | no: it is shared, and must be a mutable place | nothing |
| a binding or field of an inherently shared type, such as a texture or a ref composite | no: it cannot be copied | nothing |
| a binding or field that shares a value type | yes: copying is the default | `ref`, as in `q := ref p` |

This makes the example valid as written, including `player_atlas := await load("path/to/atlas")!`, where PROPOSALS.md would need `ref` before the value. A type still says whether it is shared: `atlas: ref tex2d`.

### GPU compatibility follows what a shader reads

**Proposed.** PROPOSALS.md made a composite host-only if any field was host-only or a ref, which would rule out `gpu render(self, ...)` on a `Sprite`. Instead, a `gpu` function can take any composite, and the compiler works from the fields the function actually reads:

- **Plain fields it reads** are packed into the shader's uniform data. Fields it never reads are not uploaded, and may be host-only: a `Sprite` could have a `name: str` and still be drawn.
- **Resources it reads** are attached automatically. A texture reached through a field, such as a frame's `atlas`, becomes a texture binding of the shader. Nothing is declared by hand.
- **Reading a host-only field** in a `gpu` function is a compile error, at that read.

**Choosing a resource happens on the host.** WebGPU cannot index a list of textures inside a shader. So an expression that picks a resource, such as `self.frames.(self.frame).atlas`, must not depend on anything that varies per pixel. The compiler evaluates it on the host before the draw, and binds the one texture it picks. Picking a texture per pixel is a compile error.

Costs, under objective 6: what a `gpu` call uploads is exactly what its body reads, so the cost can be read from the code. The part evaluated on the host runs with js semantics, which for choosing an item from a list makes no difference.

## How the language runs on the engine

This is the part neither source covers: what each language construct is at runtime, so that the language keeps PROPOSAL-3.md's promises.

### Values are plain data

A language value is the plain js value it looks like. There are no classes, prototypes, proxies or wrapper objects behind any of them.

| language | at runtime |
| --- | --- |
| `num`, `bool`, `str` | a js number, boolean, string |
| `nil` | `null` |
| a list `[T]`, an array `[T, N]` | a js array |
| a dict `{T}` | a plain object |
| a composite, named or anonymous | a plain object. Its fields are created in their written order, and are never added or deleted, which gives it a stable shape |
| an `Error` | a plain object with a `message` |
| a `ref` to a composite, list or dict | the js object itself. Sharing is an ordinary js reference, and `structuredClone` keeps sharing and cycles intact within one snapshot |
| a vector or matrix | undecided: a plain object, an array or a typed array |
| a function value | allowed in bindings and parameters, never stored in state |

**Composites have no methods at runtime.** PROPOSALS.md already compiles every composite function to a free function outside the composite, and PROPOSAL-3.md requires behaviour to be library functions over plain data. These are the same rule. `player.update(context)` and `Sprite.update(player, context)` compile to one call of one plain function, and a js developer can call that same function on the same object.

**Function values are not state.** PROPOSALS.md left open whether a function could be stored in kept state. PROPOSAL-3.md's rule answers it: no. State holds a name or an index instead, and the function is looked up.

**Proposed: engine resources are plain handles.** A `ref tex2d` at runtime is a plain handle, such as `{ __type__: "texture", id: "..." }`, that library functions resolve. So a composite that holds a texture is still plain data, and can be snapshotted.

**Types at runtime.** PROPOSALS.md needs a runtime type in three places: `x is T` on an `any`, migrating state when a composite's definition changes, and identifying a type across reloads by its module path and name. PROPOSAL-3.md's `__type__` field is that tag. Whether every composite value carries it, or only values held as `any`, is [open](#raised-by-the-merge).

### State is the program's top-level bindings

**Proposed.** An instance's state is the top-level bindings of its modules. In the example, `player` is state. Since values are plain data, that state is plain data, and everything PROPOSAL-3.md says about state applies to it directly:

- A tool reads `player.frame` in another instance as a property of a plain object, addressed as something like `state:/main/player/frame`.
- A snapshot is a `structuredClone` of the bindings.
- A reload replaces a module's code and leaves its state in place, because the state is stored outside the compiled code.

Two rules from the sources sit side by side here:

- **Inside a program**, a module's state is read-only to its importers (PROPOSALS.md). To let other modules change a value, the module exports a function.
- **Across instances**, reflection can read and write anything (PROPOSAL-3.md). A write from the editor lands between the game's frames, and is recorded as input to the game's next step.

**Kept names carry over.** Decided: a top-level name starting with `@` survives a reload, and every other top-level binding is computed again. In the example, `player` has no `@`, so each reload builds it again, and runs `load` again too. Writing `@player_atlas` would load the atlas once.

Both kinds of binding are state that a tool can read. Only kept ones survive a reload.

### Callbacks and the clock

`on` registers an engine callback. Callbacks belong to the module that registered them, so a reload removes the old ones and registers the new.

| hook | runs | receives |
| --- | --- | --- |
| `ready` | when its scene becomes current | the arguments passed by the scene switch |
| `update` | zero or more times per frame, at the instance's fixed step | an `UpdateContext`, with the step count and the fixed step length. It never sees a timestamp |
| `render` | once per `requestAnimationFrame` | a `RenderContext`, with the target, the previous image, and the fraction of a step elapsed since the last update |
| `keydown`, `keyup`, `pointerdown`, `pointerup`, `pointermove` | at a step boundary, from the engine's recorded input | an event composite |
| `resize` | when the render target changes size | the new size |

Three changes from PROPOSALS.md, all following from PROPOSAL-3.md's clock:

- **Input hooks do not run when the browser dispatches the event.** The engine's own handlers only record input. The recorded input is delivered at the next step boundary, which is what makes a replay of recorded input exact.
- **`update` receives a context**, as in the example, not a bare `dt`.
- **Determinism comes before real time.** There is a cap on update steps per frame. A slow update slows the game down instead of skipping steps.

Render should not change simulation state, and the engine does not enforce it. Interpolation belongs to the developer, using the step fraction.

### Unbounded loops are checkpointed

PROPOSALS.md caught infinite loops with a loop budget compiled into development builds. That is replaced by PROPOSAL-3.md's generators:

- The compiler turns a function into a js generator only when it contains an unbounded loop (`for { }`, `for cond { }`, a range with no end) or calls a function that does. It emits a checkpoint every N iterations.
- Bounded loops and all other functions compile to plain js.
- The engine suspends after a fixed count of checkpoints, never by the clock, so suspension falls at the same point on every run.
- Between slices, the kernel's key handler can set a panic flag. The engine checks it before resuming, and opens the rescue screen if it is set.

Nothing is injected to detect a hang. A hang is interrupted by the escape chord.

### `await`

**Proposed.** The example writes `await load("path/to/atlas")!`. PROPOSAL-3.md rules out promises in callbacks, and makes generators the only way to suspend. Both hold if `await` is the language's word for "suspend this code until an engine operation finishes", built on the same generator mechanism as checkpoints:

- `await e` suspends the surrounding code. The engine resumes it at a step boundary once the operation has finished, the same way it delivers input.
- A module's top-level code can `await`. The instance's first `ready` runs only after every module's top-level code has finished, so a program starts once its resources have loaded.
- What the program computes never depends on how long loading took, only on the fact that it finished.

In js, the same thing is written as `yield` inside a generator the engine drives.

### Shaders

A `gpu` function is a shader. It compiles to wgsl plus an interface descriptor, following the paint contract the engine publishes, so hand-written wgsl and compiled wgsl are interchangeable (objective 4).

The rest carries over from PROPOSALS.md: a context parameter instead of hidden built-in names, calling a shader from host code like a function, `before` for the previous image, and top-level bindings used directly (immutable values become wgsl constants, and `mut` values become uniforms). What a shader may read from a composite is [wider than before](#gpu-compatibility-follows-what-a-shader-reads).

**The two machines keep their own behaviour.** PROPOSALS.md already says `num` is a 64-bit float on the host and a 32-bit float in a shader, and that results can differ. Objective 10 makes that a principle: nothing on the host is slowed down to imitate the GPU.

**Shader guards.** In a checked build, the compiler guards the operations that wgsl leaves undefined or silently repairs: division, `sqrt`, `inverseSqrt`, `log`, `pow`, `asin`, `acos`, `normalize` and indexing.

- The check runs before the operation, because wgsl cannot reliably detect a bad result afterwards.
- A failed check records the source location in an error buffer. The first error wins.
- The engine reads the buffer back asynchronously and adds the report to the instance's fault buffer.
- A guard only reports. The operation's result is whatever an unchecked build would give, so both builds draw the same image.
- Reports go to tools only. They never reach update code, so they cannot affect determinism.
- On the host side of the boundary, a checked build verifies that every number uploaded as a uniform is finite.

This answers PROPOSALS.md's open question about reporting shader faults in development builds.

### Errors

PROPOSALS.md's model carries over whole. There are no exceptions and no `try`/`catch` in the language.

| situation | form | checked with | passed up with |
| --- | --- | --- | --- |
| a value may be absent | an option, `T?`, empty is `nil` | `is nil` | postfix `?` |
| an operation may fail | a result, `T!`, failure is an `Error` | `is err` | postfix `!` |
| a bug the types cannot rule out | a fault | nothing: code does not check for faults | |

What the runtime adds:

- **A fault stops the current callback, and the instance keeps running.** The engine catches it at the callback boundary. An error thrown by js code called from the language is caught the same way.
- **A fault is recorded as plain data** in the instance's fault buffer, with its module, line and message. The editor reads the buffer with a cursor, through the same reflection api as any tool.
- In a callback or in top-level code, `!` on an error and `?` on `nil` report like a fault, since there is no caller to pass to.

### Live reload and recovery

The two documents describe the same mechanism from two sides. PROPOSALS.md has the language rules, and PROPOSAL-3.md has the engine that carries them out.

| PROPOSALS.md | merged |
| --- | --- |
| a reload is per module and all or nothing; the swap happens between callbacks | unchanged. Every accepted edit is also saved as a version at once |
| kept state is restored if the transition fails | the restore point is a snapshot: a `structuredClone` of state taken before the swap |
| the transition is the first full frame after a swap; a failure in it rolls back | unchanged. This is PROPOSAL-3.md's "probation" |
| state migrates field by field when a composite changes | unchanged. It uses the runtime type tag |
| a loop budget catches infinite loops | [checkpoints](#unbounded-loops-are-checkpointed) and the escape chord |
| a default editor, belonging to the editor, is the fallback | a rescue screen, belonging to the engine's kernel and drawn as plain DOM, plus a `?safe` URL flag |
| live reload is an editor feature | live reload is an engine api. The editor is one client of it |
| the editor and the program run in separate frames or workers and exchange messages | they run as separate instances on one thread. Reflection is ordinary property access |

### Instances

From PROPOSAL-3.md, unchanged: all instances run on the main thread in one js realm and share one GPU device. The editor reaches the game only through reflection. The game draws into a texture the editor owns, so game code is the same standalone and inside the editor.

## What is dropped

From PROPOSALS.md, because the runtime wins:

- Separate frames or workers for the editor and the program, and the message channel between them.
- The loop budget in development builds.
- The default editor as part of the editor's fixed core.
- Live reload as something only the editor has.
- `update` receiving a bare `dt`.
- Function values in kept state.

From PROPOSALS.md, because the rules changed:

- `ref` and `ref mut` written on an argument at a call.
- `ref mut T` as a parameter type, and `mut` on a parameter meaning a mutable local copy.
- A composite being host-only as a whole because of one field (proposed).

From the conversation, never recorded in either document:

- The "tolerant at runtime, loud in the tools" approach to errors: js defaults everywhere, type problems as warnings, and `try`/`catch`. PROPOSALS.md's options, results and faults stand instead.

## What carries over

**From PROPOSALS.md**, rewritten in the new syntax but otherwise unchanged:

- [Lexical structure](PROPOSALS.md#lexical-structure): `#` comments, `_private` names, strings and interpolation, braces, newline-ended statements, no `;`.
- [Types](PROPOSALS.md#types): `num` as the one number type, `bool`, vectors and `<1, 2>` literals, matrices, arrays and lists, `any`, anonymous composites, dicts, dot indexing.
- [Composites](PROPOSALS.md#composites): fields, defaults, literals, constructors, methods, overloads, ref composites and ref fields. GPU compatibility is [changed](#gpu-compatibility-follows-what-a-shader-reads).
- [Optional types](PROPOSALS.md#optional-types-t), narrowing, and `else` as the fallback operator.
- [Bindings](PROPOSALS.md#bindings): `name : Type = value`, `:=`, `mut` on places and never on types.
- [Copying and sharing](PROPOSALS.md#copying-and-sharing): everything is copied unless `ref` says to share. Where `ref` has to be written is [changed](#sharing-at-a-call).
- [Operators](PROPOSALS.md#operators): `is` and `is not` for equality, `and`, `or`, `not`, no bitwise operators.
- [Control flow](PROPOSALS.md#control-flow): `if` as a statement, `for` as the only loop, ranges, truthiness.
- [Functions](PROPOSALS.md#functions): explicit `return`, inferred return types, overloads resolved at compile time.
- [Modules](PROPOSALS.md#modules): `import`, `_` for private names.
- [Scenes](PROPOSALS.md#scenes): only the current scene's hooks are attached, and a switch discards everything.
- [Kept state](PROPOSALS.md#kept-state) and [migration](PROPOSALS.md#when-a-kept-values-type-changes).
- [Errors](PROPOSALS.md#errors) and [faults](PROPOSALS.md#faults).

**From PROPOSAL-3.md**, unchanged:

- All ten [objectives](PROPOSAL-3.md#objectives).
- Everything under [Decided](PROPOSAL-3.md#decided): layout as the engine's own, the fixed compiler, separate instances, one thread and one device, the clock, generators, plain-data state.
- The explorations: [surviving broken edits](PROPOSAL-3.md#surviving-broken-edits-objective-3), [suspending safely](PROPOSAL-3.md#suspending-safely), [reflection](PROPOSAL-3.md#reflection-and-the-public-api-objectives-4-and-5), [showing one instance inside another](PROPOSAL-3.md#showing-one-instance-inside-another), [determinism](PROPOSAL-3.md#determinism-objective-7) and [observing state](PROPOSAL-3.md#observing-state-objective-6).
- The layout api is not designed.

## Open questions

The open questions of both source documents still stand unless answered above. These are the new ones.

### Raised by example.qs

- **`mut` parameters.** Does `ref mut T` remain as a type for bindings and fields, such as a field `pos: ref mut vec2`? Can a temporary be passed to a `mut` parameter, where the change would be discarded?
- **Where `ref` is written.** Is the [proposed](#sharing-at-a-call) rule right: only where there is a choice between copying and sharing?
- **Plain parameters.** With `mut` and `ref` both sharing, an unmarked parameter `x: T` is still a copy that the function cannot change. Since neither side can observe the copy unless the caller's value changes during the call, can the compiler always skip it?
- **What a shader can reach.** Under the [proposed](#gpu-compatibility-follows-what-a-shader-reads) rule: can a shader follow a ref composite, or only textures? How is a whole list such as `[Frame]` read per pixel, when its items hold resources? Does a sampler come with each texture automatically?
- **Host evaluation in a `gpu` function.** Is choosing a resource the only thing evaluated on the host, or may the compiler move any expression that does not vary per pixel?
- **`await`.** Is the [proposed](#await) meaning right? Can it appear inside a callback, or only in top-level code?
- **The contexts.** What an `UpdateContext` holds beyond the step count and step length, and what a `RenderContext` holds beyond PROPOSALS.md's context fields.
- **Inline function values** and **the `gpu` assertion tag**, as noted under [Syntax changes](#syntax-changes-from-proposalsmd).
- **Handlers.** Can `on` still take a named function, as in `on render draw_frame`?
- **Constructors.** Are they still bare `(params) { ... }` entries in a `def`, now that functions there take `fun`?

### Raised by the merge

- **Copies and objective 6.** "Everything is copied unless `ref`" means a binding, assignment or plain argument can allocate on js. PROPOSALS.md lets the compiler skip a copy nobody can observe. Is the remaining cost predictable enough from the code?
- **Refs to scalars and places.** `ref` on a number, a field or an element needs a small heap object on js. It is the one place the language boxes a value. It is visible in the code as `ref`, but is it acceptable?
- **Where `__type__` goes.** On every composite value, or only on values held as `any`? Every value costs a field per object. Only `any` means a generic inspector must get types from the module's metadata instead.
- **Vectors and matrices on js.** A plain object, an array or a typed array. This is open in both documents, and decides whether typed arrays are allowed in state.
- **Scenes and instances.** PROPOSALS.md has one current scene per engine. With several instances, is a scene per instance still the right unit, or does an instance replace it?
- **Time in `render`.** PROPOSALS.md's context has `t` and `dt` in seconds since the previous frame. Are they derived from the step count and step fraction, or from the browser's clock? The second is not deterministic, which matters only if render keeps state.
- **Small unifications.** PROPOSALS.md truncates an index toward zero on both machines, and emits its own truthiness test on js so both agree. Both are cheap and decided at compile time. Do they stay under objective 10?
- **Exported applications.** PROPOSALS.md gave them no live reload. If reload is an engine api, is it removed from a release build, or always present?
- **Reflection from the language.** What the api looks like in language code, and which instances a program can name.
- **Recursion.** Runaway recursion on js is a stack overflow, caught as a fault at the callback boundary. Whether recursive functions need checkpoints is still being thought about.
- **The number type and compute shaders.** PROPOSALS.md justified one number type by having only fragment shaders. Shader guards need integers and atomics in the generated wgsl, though not in the language. Compute shaders are still an open question in PROPOSAL-3.md.
