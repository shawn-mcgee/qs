# Quicksilver

Quicksilver (`qs`) is a small language embedded in an application/engine. One language is used for both host logic and per-pixel shaders. `qs` is compiled ahead of time: host code becomes js, and shader code becomes wgsl for WebGPU. There is no interpreter at runtime.

## Principles

Every rule in this document follows from these. When a new question comes up, answer it with them.

1. **One language, two machines.** The same code means the same thing on the host and on the GPU. Where the two genuinely cannot agree, the difference is made visible, never hidden.
2. **Everything is application.** There is one shape: a name followed by arguments. Special forms look like calls. Punctuation is rare and earns its place, and words are preferred over symbols.
3. **`num` bends; types don't, unless you name the type.** `num` is the loose host number and adapts to whatever it meets. Typed values (`f32`, `i32`, `u32` and everything built from them) never change type silently, only when you name the type.
4. **Literals are shorthand.** Every literal has a plain spelled-out equivalent. `:` after a value means "interpret this as".
5. **Data is plain.** All state is a plain js tree that serializes to json. Anything that cannot be serialized lives behind a `ref`.
6. **Forgiving on the host, exact on the GPU.** Host code tolerates gaps (`nil`, truthiness, missing arguments). Shader code is static and total, and anything it cannot express is a compile-time error.
7. **Mirror wgsl, borrow glsl's conveniences.** Math semantics are wgsl's. Where wgsl is clumsy, use the conveniences shader authors expect.
8. **Don't decide what isn't understood yet.** An open question is better than a locked-in guess.

## Values

### Host values

| type | meaning | js representation |
| --- | --- | --- |
| `nil` | nothing | `null` |
| `bool` | `true` or `false` | `boolean` |
| `num` | loose host number, 64-bit float | `number` |
| `str` | text | `string` |
| `list` | growable, untyped sequence | `any[]` |
| `dict` | string-keyed map | plain object without `__type__` |
| `ref` | handle to engine-owned, non-serializable data | `{ __type__: "__ref__", __kind__: string, __uuid__: string }` |
| `fn` | function | `{ __type__: "__fn__", __uuid__: string }` |
| `sh` | shader | `{ __type__: "__sh__", __uuid__: string }` |

None of these can be passed into a shader. `bool` also exists in wgsl, but only as a shader-internal value.

### wgsl values

Typed values mirror wgsl types and can be passed into shaders, except bool vectors. Each is a plain object with a `__type__` discriminator. Since the discriminator already names the type, everything inside it is stored as plain js numbers and booleans.

| type | wgsl type | js representation |
| --- | --- | --- |
| `f32`, `i32`, `u32` | `f32`, `i32`, `u32` | `{ __type__: "__f32__", value: 1.5 }` |
| `vec2f`, `vec3f`, `vec4f` | `vec2f` ... | `{ __type__: "__vec3f__", x: 1, y: 2, z: 3 }` |
| `vec2i`, `vec3i`, `vec4i` | `vec2i` ... | same shape |
| `vec2u`, `vec3u`, `vec4u` | `vec2u` ... | same shape |
| `vec2b`, `vec3b`, `vec4b` | `vec2<bool>` ... | same shape, with booleans; shader-internal only |
| `mat2`, `mat3`, `mat4` | `mat2x2f` ... | `{ __type__: "__mat2__", data: [1, 0, 0, 1] }`, column-major |
| `tex1d`, `tex2d`, `tex3d` | `texture_2d<f32>` ... | `{ __type__: "__tex2d__", w: 512, h: 512, data: ref }`; `tex1d` has only `w`, and `tex3d` adds `d` |
| `[T]`, `[T;N]` (arrays) | `array<T, N>` | `{ __type__: "__array__", type: "f32", length: 3, items: [1, 2, 3] }` |

Array items use the plain representation of their element type: numbers for scalars, and vector objects for vectors.

Every type has exactly one name. There are no aliases.

Only square matrices exist for now. Matrices are always `f32`, since wgsl only has float matrices. Structs are planned but not specified.

### Values and sharing

Scalars, vectors, matrices and arrays are values, like in wgsl: binding, assigning or passing one copies it. Lists, dicts, textures, `ref`s, `fn`s and `sh`s are shared.

```qs
let a <1 2 3>
let b a
set b.x 9          # a is still <1 2 3>

let xs [1 2 3]
let ys xs
set ys.0 9         # xs is now [9 2 3]
```

### Serialization

Every value serializes to json as its js representation. A `ref` lets state point at engine-owned data while staying plain. Its `__kind__` names what it points at, such as `"image"`, and its `__uuid__` identifies it.

json cannot hold `NaN`, `Infinity`, `-Infinity` or `-0`. Wherever a number would be written, including inside typed values, these are written as a tagged object instead and restored when loaded, so every value round-trips exactly. The tag exists only in json: in memory they are ordinary js numbers.

```json
{ "__type__": "__float__", "value": "NaN" }
{ "__type__": "__vec2f__", "x": 1, "y": { "__type__": "__float__", "value": "-Infinity" } }
```

`value` is one of `"NaN"`, `"Infinity"`, `"-Infinity"` or `"-0"`.

A `fn` or `sh` serializes as just its `__type__` and `__uuid__`; a closure's captured variables are not serialized. A serialized function can only be rehydrated while the application still holds the live function with that `__uuid__`. Rehydrating one that no longer exists is an error.

The `__uuid__` names where the function is defined: its script's path and its position in that script. It is therefore stable across page reloads while the source is unchanged. If the source is edited, the positions can move and saved functions may no longer rehydrate. Every closure created by the same `fn` or `sh` shares one `__uuid__`. Such closures are equal under `is`, and rehydrating a serialized one gives the most recently created live one.

```json
{ "__type__": "__fn__", "__uuid__": "game/player.qs:12:14" }
```

## Syntax

### Application

Function application is the one fundamental shape. As in lisp, an application is a head followed by its arguments. Parens around a whole line are optional, and so are commas between arguments. These are all equivalent:

```qs
(foo a b)
foo a b
foo a, b
(foo a, b)
```

Parens always group, and whitespace around them never changes the meaning: `foo(a b)` is the same as `foo (a b)`. Elsewhere, whitespace matters only for [`-`](#arithmetic) and for prefixes and suffixes that must touch their operand: `:T`, `...` and `$"`. Arguments are never called. A group is a single argument, and its value is the result of its own application.

```qs
foo a bar b c      # 4 arguments: a, bar, b and c
foo a (bar b c)    # 2 arguments: a and the result of (bar b c)
foo(a b)           # 1 argument: the result of (a b)
```

Since `foo(a b)` reads like a C-style call but means something else, the compiler warns when `(` directly follows a name or a `)`. The meaning is unchanged. `.(` computed keys are exempt.

```qs
on render(draw_frame)  # warning: this calls draw_frame now; did you mean `on render draw_frame`?
add(1, 2)              # warning: this applies 1 to 2; did you mean `add 1 2`?
```

The head can be any expression. A group in head position is evaluated, and its result is applied to the remaining arguments.

```qs
((make_adder 1) 2) # 3
(make_adder 1) 2   # 3: the outer parens are optional
(foo a) + b        # infix, not application: the result of (foo a), plus b
```

Commas control arity: an empty slot is `nil`, and trailing commas are optional.

```qs
foo a ,, b         # 3 arguments: a, nil and b
foo a b ,,         # 3 arguments: a, b and nil
foo, a b           # a comma after the head only separates: 2 arguments, a and b
foo ,, a           # 2 arguments: nil and a
(, a)              # error: no head
```

An empty group `()` is a compile-time error, since an application needs a head. `foo()` is therefore an error too. To call a function with no arguments, write `foo` or `(foo)`. To pass nothing, write `nil`. The one place `()` is allowed is an empty parameter list, `fn () ...`, because a parameter list is a pattern and is never applied.

An application with no arguments still applies its head. If the head's value is a function, it is called with no arguments; otherwise the application evaluates to that value. This holds for any head: a name, a path or a group. Use `get` to get a function itself in a lone position.

A line is an application, and parens around the whole line belong to it, so `(foo a)` and `foo a` are the same line. Each further pair of parens is another application, so it can add another call.

```qs
foo                # calls foo
(foo)              # calls foo: the same line
m.bump             # calls m.bump
let x (foo)        # binds the result of calling foo
let f foo          # foo is an argument: f is the function itself
{ get foo }        # a block evaluating to the function foo
{ x }              # the value of x, when x is not a function

(make_adder 1)     # the adder function
((make_adder 1))   # calls the adder with no arguments
fn (x) x           # returns x
fn (x) (x)         # calls x if it is a function
```

### Lines and blocks

A newline ends an expression, unless it is inside parens, square brackets or braces.

Braces group newline-separated expressions into a block. A block's value is its last expression's value; an empty block is `nil`. Every block creates a new scope.

```qs
{
  let a 1
  let b 2
  a + b
}
```

### Names and comments

Identifiers contain ASCII letters, digits and underscores, cannot start with a digit, and are case-sensitive.

`#` starts a line comment, except inside a str literal.

Reserved words: `let`, `set`, `fn`, `sh`, `if`, `elif`, `else`, `while`, `each`, `and`, `or`, `return`, `break`, `continue`, `import`, `on`, `nil`, `true`, `false`. These are special forms or literals. Every other built-in is an ordinary binding and can be shadowed.

### Special forms

Special forms look like calls, but each has a fixed shape. A function ignores extra arguments; a special form rejects missing or extra operands with a compile-time error. Arguments are never called, so an application used as an operand needs parens.

| form | shape |
| --- | --- |
| `let` | `let name value`, or `let name:T value` |
| `set` | `set target value` |
| `fn`, `sh` | `fn params body` |
| `if` | `if cond branch`, then any number of `elif cond branch`, then at most one `else branch` |
| `while` | `while cond body` |
| `each` | `each pattern a body`, with up to two more arguments before the body (see [Counting](#counting)) |
| `return` | `return`, or `return value` |
| `break`, `continue` | no operands |
| `import` | `import path` |
| `on` | `on name handler` |

```qs
if not done { ... }      # error: if takes a condition and a branch
if (not done) { ... }
while (lt i n) { ... }
let x add 1 2            # error: let takes one value
let x (add 1 2)
fn (x) foo x             # error: fn takes one body
fn (x) (foo x)
```

## Literals

### Nil and bools

`nil`, `true` and `false`.

### Numbers

A number literal is a `num`. It must start with a digit (`0.5`, not `.5`). Integers, decimals, exponents, hex (`0xff`), binary (`0b1010`) and octal (`0o17`) are supported, and `_` can separate digits (`1_000_000`). `-7` is a negative literal.

A type suffix interprets the literal as a wgsl scalar. A suffix is always `:` followed by a full type name, the same spelling used for annotations.

```qs
42:i32
0xff:u32
2.5e-4:f32
```

A suffixed literal whose value does not fit its type, such as `0xffffffff:i32`, `-1:u32` or `1.5:i32`, is a compile-time error. A suffix must directly follow the literal, with no whitespace. This applies to every `:` suffix in the language.

### Strings

Strings use double quotes. The escapes are `\n`, `\t`, `\r`, `\0`, `\"`, `\\` and `\u{hex}` for any Unicode code point. Any other backslash sequence is a compile-time error. Braces in a plain string have no special meaning.

A string may span lines, and its newlines are kept as written. A newline inside a string does not end the expression.

```qs
"caf\u{e9}"        # café
let msg "line one
line two"
"\q"               # error: unknown escape
```

A string prefixed with `$` is interpolated: `{expr}` inside it is evaluated and inserted. The expression may contain plain string literals, but not other interpolated strings. A non-str value is inserted in its `qs` source form, e.g. `nil`, `1.5:f32`, `vec2f 1 2`, `[1 2 3]`. In an interpolated string, `\{` writes a literal brace.

```qs
"{not interpolated}"
$"hello {name}"
$"total: {add a b}"
$"{cat "a" b}"
$"\{not interpolated}"
```

### Lists

Square brackets make a list. Inside brackets, whitespace separates elements rather than applying functions, so an application must be wrapped in parens. Infix operators still bind first. Commas work as in application.

```qs
[1 2 3]
[a b + 1 c]        # 3 elements: a, b + 1, c
[(foo a b) c]      # 2 elements
[a ,, c]           # [a nil c]
[0 ...xs 9]        # spread: the elements of xs, between 0 and 9
```

`list 1 2 3` is the same as `[1 2 3]`.

### Vectors

Angle brackets make a vector. Items follow list rules. Vector items are flattened: each contributes its components in order. The size is the total component count, which must be 2, 3 or 4.

```qs
<1 2>              # vec2f
<1.5 2 3>          # vec3f
<v.xy 1>           # 3 components, from a vector and a scalar
<a.xy b.xy>        # 4 components
<1>                # error: too few components
```

The component type is inferred:

- Typed components must all have the same type, and the vector takes it. Mixing types is an error.
- `num` components adapt to that type.
- If every component is a `num`, the vector is `f32`, as in glsl. Positions and colors are the common case. An integer vector needs a type, from a typed component or a suffix: `<1 2>:vec2i`.

A vector type suffix names the type, so it converts mixed components. The suffix's size must match the literal's.

```qs
<x 0 0>            # vec3f when x is an f32
<x i>              # error: f32 and i32
<x i>:vec2f        # vec2f
<1 2>:vec2u        # vec2u
<1 2>:vec3u        # error: 2 components, not 3
```

Inside a vector literal, `>` always closes it. `<` and `>` have no other meaning.

### Arrays

A list literal with an array type suffix makes an array. Array types are `[T]` (length from the items) and `[T;N]` (exact length), and this is the only way arrays are spelled. Every item is converted to `T`. To make an array from an existing list, spread it into a literal.

```qs
[1 2 3]:[f32]
[1 2 3 4]:[f32;4]
[...weights]:[f32;9]
[1 2]:[f32;4]      # error: 2 items, but 4 required
```

An array must have at least one item, and with a fixed length the count must match exactly. Arrays are never zero-filled. In shaders, `[T;N]` compiles to wgsl `array<T, N>` and `[T]` to a runtime-sized `array<T>`.

### Matrices

Matrices have no literal; they are built with their constructor, from column-major scalars or column vectors.

```qs
# the same mat2; the first column is <1 2>
mat2 1 2 3 4
mat2 <1 2> <3 4>
```

Angle brackets never make a matrix: `<<1 2> <3 4>>` is a `vec4f`.

## Bindings and functions

### Bindings

`let` declares a name and `set` reassigns it. Scope is lexical. Declaring a name twice in the same scope is an error, and so is `set` on an undeclared name. `let` can shadow an outer scope's name.

`let` and `set` take exactly one value, as [special forms](#special-forms) have fixed shapes. An application used as the value needs parens:

```qs
let x add 1 2      # error: let takes one value; write (add 1 2)
let x (add 1 2)    # 3
let f add          # the function add itself
```

`let` can take a type, written like a parameter annotation. It is checked at runtime on the host and at compile time in shaders.

```qs
let x 5
set x 6
let speed:f32 2
```

Any type name can be an annotation, including host types such as `str`, `list`, `dict` and `fn`. An annotation with a wgsl type converts numbers, as described under [Coercion](#coercion). An annotation with a host type only checks, since there is nothing to convert. Shaders accept only wgsl types.

An annotated binding or parameter never holds `nil`. A missing argument to an annotated parameter is therefore an error. To accept `nil`, leave the parameter unannotated.

```qs
let name:str "qs"
let scores:list []
let greet (fn (who:str times:i32) { ... })
```

### Functions

`fn` takes a parameter list, then exactly one body. Use a block for several expressions. A function returns its body's value; `return` exits early. Functions are named with `let`.

```qs
let add (fn (a b) (a + b))

let hyp (fn (a b) {
  let a2 (a * a)
  let b2 (b * b)
  sqrt (a2 + b2)
})
```

Missing arguments are `nil` and extra arguments are ignored. A final `...rest` parameter collects the remaining arguments into a list. At a call site, `...xs` spreads a list into arguments.

```qs
let log (fn (level ...parts) { ... })
log "info" ...parts "c"
```

Parameters may be annotated with a type. On the host, annotations are checked at runtime. Default parameter values are planned.

Closures share the variables they capture: a later `set` is visible on both sides.

## Control flow

```qs
if (lt x 0) {
  "negative"
} elif (is x 0) {
  "zero"
} else {
  "positive"
}

while cond { ... }
each x xs { ... }
```

`if` evaluates to the taken branch, or `nil` if none is taken. A line starting with `elif` or `else` continues the `if`. `while` and `each` evaluate to `nil`. `break` and `continue` work in both loops.

`each` takes a binding pattern, which is never evaluated. One name binds each value. Names in parens bind the value, then the index or key; an empty slot is skipped. Each iteration gets a fresh binding.

```qs
each fruit fruits { ... }
each (fruit, i) fruits { ... }
each (, i) fruits { ... }
```

| iterable | value | index/key |
| --- | --- | --- |
| list, array | each item | index |
| dict | each value, in insertion order | key |
| str | each code point, as a one-code-point str | code point position, not UTF-16 offset |
| `nil` | nothing: zero iterations, on the host | |
| vector | each component | index |
| matrix | each column | index |
| number | each whole number from `0` up to, but not including, it | iteration count |

### Counting

A number is iterable, so `each` counts. With two or three arguments before the body, they are a start, an end (not included) and a step.

```qs
each i 10 { ... }          # 0 1 2 ... 9
each i 2 10 { ... }        # 2 3 ... 9
each i 0 10 2 { ... }      # 0 2 4 6 8
each i 10 0 -1 { ... }     # 10 9 ... 1
each i 0 ,, { ... }        # nil end: 0 1 2 ... with no end
each i 0 ,, 2 { ... }      # nil end, step 2
each i (len xs) { ... }    # applications need parens
```

These are ordinary arguments: they are evaluated once, before the loop, and the body is always the last argument.

**The step is never inferred.** It is `1` unless given, so counting goes up unless the step is negative. A step pointing away from the end gives no iterations, whether the arguments are literals or variables: `each i 10 0` and `each i -3` run zero times. A step of `0` is an error.

**Counting is in whole numbers.** The start, end and step must be whole: this is checked at compile time for literals and at runtime for host variables. For fractions, convert the counter: `(f32 i) / 10`.

**The counter's type is an integer type, or a whole `num`:**

- A typed start, end or step names the type, which must be `i32` or `u32`. Mixing types is an error.
- `num`s adapt to that type. A `u32` count may still have a negative step, which counts down.
- If the start, end and step are all `num` literals, the type is `i32`, on the host and in shaders alike, so `each i 10` binds the same `i32` everywhere.
- If a `num` variable is involved and nothing is typed, the counter is a `num`. This only works on the host.

```qs
each i 10 { ... }          # i is an i32
each i n { ... }           # a u32 when n is a u32; a num when n is a num
each i 0:u32 10 { ... }    # u32
each i n 0 -1 { ... }      # counts down, even when n is a u32
each i x { ... }           # error when x is an f32
```

**A `nil` end** goes as far as the type allows, and includes that last value: the largest `i32` or `u32` (or the smallest, when counting down). A `num` count has no limit. Such a loop runs until `break` or `return`.

### Part of a collection

When the first argument is a collection, the second is a count and the third is a step. The count is how many items to visit, and a `nil` count visits them all. A negative step starts from the last item and walks backwards.

```qs
each x xs 3 { ... }        # the first 3 items
each x xs 3 -1 { ... }     # the last 3 items, last first
each x xs ,, 2 { ... }     # items 0 2 4 ...
each x xs 3 2 { ... }      # items 0 2 4: 3 items, every other one
each x xs ,, -1 { ... }    # every item, last to first
```

`each i 3` and `each x xs 3` both run three times: a lone number counts to an end, which from `0` is the same as a count.

- A count larger than what is left visits every remaining item, and a count of `0` or less visits none.
- The count and step must be whole numbers, and a step of `0` is an error.
- The second pattern name is the item's real index, not the iteration count: `each (x, i) xs ,, -1` binds `i` from the last index down to `0`. For a dict, it is still the key, and positions follow insertion order.
- Like any argument, the collection is evaluated once, before the loop, and its length is read then. Items pushed during the loop are not visited.
- In shaders, the index is an `i32`.

## Operators

### Arithmetic

The only infix operators are `+`, `-`, `*` and `/`. They bind tighter than application. `.` (access) binds tightest, then prefix `-`, then `*` `/`, then `+` `-`, all left-associative.

```qs
foo a + b          # 1 argument: a + b
(foo a) + b        # the result of (foo a), plus b
```

Whitespace is optional, except for `-`. A `-` is negation when it follows another operator (`+ - * /`), an opening bracket, or a comma, or when it has whitespace before it and none after it. Any other `-` is subtraction.

```qs
a-b                # subtraction
foo a -7           # 2 arguments: a and -7 (with a warning, see below)
foo a - 7          # 1 argument: a - 7
a - -b             # a minus negative b
each i 10 -2 -1    # 10 down to -1
[-1 2]             # starts with negation
```

The compiler warns when a negation directly follows a name, path or group, since that is usually a mistyped subtraction. A comma silences the warning, and so does spacing the `-` as subtraction. A negation after a literal or a comma is silent.

```qs
each i n -1 { ... }    # warning: start n, end -1. Did you mean n - 1?
foo a -b               # warning: write foo a, -b or a - b
foo a, -b              # 2 arguments, no warning
each i 10 0 -1 { ... } # no warning: -1 follows a literal
```

Arithmetic applies to numbers, vectors and matrices, following wgsl (`mat * vec` is linear algebra). `+` does not concatenate; strs and lists are joined with `cat`.

### Word operations

Everything else is a prefix function.

| function | meaning |
| --- | --- |
| `and`, `or`, `xor`, `not` | logic |
| `is` | deep equality |
| `eq` | component-wise equality, as in wgsl |
| `lt`, `lte`, `gt`, `gte` | comparison |
| `mod`, `rem` | floored modulo, truncated remainder |
| `pow` | exponentiation |
| `band`, `bor`, `bxor`, `bnot`, `shl`, `shr` | bitwise, on `i32` and `u32` |

`and` and `or` are special forms: they short-circuit and evaluate to an operand. `xor` evaluates to the one truthy operand, or `false`. The shift amount of `shl` and `shr` is a `u32`, as in wgsl.

When every operand is a `num`, bitwise operations follow js rules and return a `num`: operands are truncated to signed 32-bit integers, and `shr` is js's sign-preserving `>>`. In shaders, such expressions are only possible between literals, which fold at compile time like any other `num` expression.

```qs
band 5 3           # 1
bnot 0             # -1
band 5:u32 3       # 1:u32: 3 adapts to u32
```

`mod` floors, as in glsl: the result has the sign of the divisor, which is what wrapping angles and tiling need. `rem` truncates, like wgsl's and js's `%`: the result has the sign of the dividend.

```qs
mod -1 3           # 2
rem -1 3           # -1
mod -0.25 1        # 0.75
```

`is` compares deeply and returns a `bool`. Two different typed scalars, such as `is 1:i32 1:f32`, are an error; inside lists and dicts, different types are simply unequal. `ref`s, `fn`s and `sh`s compare by uuid.

`lt`, `lte`, `gt` and `gte` on vectors compare component-wise and return a bool vector. Reduce it with `any` or `all`.

`is` deliberately differs from wgsl's `==`: it always means "the same value" and returns one `bool`, even for vectors. `eq` is wgsl's `==`. It takes numbers, vectors and bools, compares component-wise, and returns a bool vector for vectors.

```qs
is <1 2> <1 3>             # false
eq <1 2> <1 3>             # vec2b: true false
select a b (eq u v)        # per component
```

### Truthiness

The falsy values are `nil`, `false`, zero (of any number type), `""`, empty lists and dicts, and vectors and matrices whose components are all zero or `false`. Everything else is truthy. Truthiness applies to typed values too. In shaders, a typed condition compiles to a comparison with zero.

A bool vector condition is truthy if any component is `true`.

## Numbers

### Coercion

**Only `num` is coerced by operations.** Arithmetic, comparisons, logic and bitwise operations on two different typed scalars are errors, as in wgsl. A `num` operand adapts to the typed operand.

```qs
x + i              # error: f32 + i32
x + (f32 i)        # ok
x * 0.5            # 0.5 adapts to f32
7:i32 / 2          # 3:i32: 2 adapts to i32
```

**Naming a type converts.** A type suffix, a constructor, a `let` type or a parameter with a declared concrete type converts any number to that type.

```qs
f32 i              # explicit conversion
vec2f i j          # the constructor converts
pow (f32 n) 3      # 3 adapts to f32
```

A suffix can also follow a group, touching its `)`. `(expr):T` is exactly `T expr`.

```qs
(len xs):u32       # u32 (len xs)
(a + b):f32        # f32 (a + b)
```

Built-ins only coerce `num`s. Built-ins whose arguments must share a type, such as `min`, `max` and `clamp`, never convert one typed argument to match another. Float-only built-ins, such as `pow`, `sin` and `sqrt`, reject typed integers, as in wgsl: `pow 2:i32 3` is an error, and the integer must be converted explicitly. Lists are never converted to arrays.

A `num` converted to `i32` or `u32` must be a whole number. This is checked at compile time for constants and at runtime for host variables. Explicit conversions truncate.

### `num` math

`num` math uses 64-bit js numbers, so `7 / 2` is `3.5`. Integer division only happens with a typed integer. Expressions of only `num` literals are folded at compile time by `num` rules, so they behave identically in shaders. A shader cannot hold a `num` at runtime: a shader `let` whose value is only a `num` must name its type.

```qs
let a 7            # in a shader: error
let a 7:i32        # ok
```

On the host, math built-ins given only `num`s return a `num`. `sin 0.5` on the host can therefore differ slightly from a shader. Use typed values (`sin 0.5:f32`) when they must match.

### Typed math on the host

Compiled js emulates wgsl's rules:

| rule | behavior |
| --- | --- |
| `f32` | rounded to 32-bit after each operation |
| `i32`, `u32` | wrap on overflow |
| integer `/` | truncates toward zero |
| integer `/` by zero | evaluates to the left operand |
| integer `mod` or `rem` by zero | evaluates to `0` |
| float to integer | truncates, clamped to the type's range |

Integer math and `f32` `+`, `-` and `*` match the GPU exactly. wgsl allows `f32` `/` and some built-ins to be slightly inexact, and GPUs may flush tiny values to zero, so those can differ in the last bits.

### Constructors

Every typed value's name is a constructor. Constructor arguments are flattened like vector literals. Missing components are zero and extras are ignored. A single scalar fills every component of a vector (as in wgsl) and the diagonal of a matrix (as in glsl).

```qs
vec4f v.xyz 1
vec4f v.xy         # vec4f v.x v.y 0 0
vec3f 1            # vec3f 1 1 1
mat3 1             # identity
vec3f              # vec3f 0 0 0 (a lone name is a call)
```

### Math built-ins

All wgsl math built-ins are available by their wgsl names, on the host and in shaders.

## Collections

```qs
let xs [1 2 3]
let d (dict "name" "qs" "version" 1)

get xs 0           # xs.0
get d "name"       # d.name
d.(k)              # computed key
m.0.1              # column 0, component 1: digits after . are indexes
```

On a dict, digits after `.` are a string key: `d.0` is `get d "0"`.

Reading a missing key or an out-of-range list index is `nil`. Elements are changed with `set`, `push`, `pop` and `del`. Arrays have a fixed length, so `push` and `pop` on them are errors. There are no dict literals for now.

```qs
set xs.0 5
set d.name "quicksilver"
push xs 4
del d "name"
```

Vectors support swizzles with `xyzw` or `rgba` (not mixed). A swizzle can be assigned if no component repeats; in shaders this compiles to one assignment per component.

```qs
v.zyx
set v.xy <1 2>
```

## Shaders

A shader is a per-pixel function, created with `sh` and named with `let`. Its first parameter is the target surface it writes to; surfaces are owned by the engine. All parameters must be typed. The body's value is the `vec4f` written to the current pixel.

```qs
let tint (sh (target:tex2d src:tex2d color:vec4f) {
  (sample src uv) * color
})
```

A shader is called like a function, target first. The call evaluates to the target, so passes chain. The GPU work is asynchronous, but this is hidden.

```qs
gray screen (tint scratch photo <1 0.5 0.5 1>)
```

Inside a shader:

| name | meaning |
| --- | --- |
| `uv` | `vec2f` position on the target, from 0 to 1 |
| `coord` | `vec2u` pixel position on the target |
| `sample tex uv` | filtered read |
| `load tex coord` | exact texel read |

`(0, 0)` is the top-left corner and y grows downward, as in WebGPU and in pointer events. `uv` is taken at the pixel's center: `coord + 0.5`, divided by the target's size in pixels. It never quite reaches 0 or 1. Pointer hooks use the same convention for `pos` and `uv`.

`sample` takes an `f32`, `vec2f` or `vec3f` coordinate for `tex1d`, `tex2d` or `tex3d`; `load` takes a `u32`, `vec2u` or `vec3u`.

Every language feature works in shaders, but every value must have one static type. This means the following are compile-time errors:

- js-only values (strs, lists, dicts, `ref`s, `fn`s, `sh`s, runtime `num`s), including spread and variadic parameters
- a final value or `return` that is not a `vec4f`
- using an `if` with no `else` as a value, or `if` branches of different types
- `and`, `or` or `xor` operands of different types
- calling a nested function with missing arguments
- recursion

Arguments are converted to parameter types at the call. An array parameter only accepts an array, never a list.

A shader can define nested functions with `let` and `fn`. Their parameters must be typed; return types are inferred. They compile to wgsl helper functions, and captured values become extra parameters.

```qs
let gray (sh (target:tex2d src:tex2d) {
  let lum (fn (c:vec4f) (c.r * 0.3 + c.g * 0.59 + c.b * 0.11))
  let l (lum (sample src uv))
  vec4f l l l 1
})
```

A shader can also use a script's top-level bindings, so helpers are written once and shared by the host and the GPU.

- A top-level `fn` can be called from a shader if its body follows the shader rules. The rules for nested functions apply: its parameters must be typed, and it compiles to a wgsl helper function. The same function can still be called from host code.
- A top-level typed value is captured as a uniform. It is read each time the shader is called, so a later `set` is seen by the next call.
- Capturing any other value, including a `num`, is a compile-time error.

```qs
let lum (fn (c:vec4f) (c.r * 0.3 + c.g * 0.59 + c.b * 0.11))
let strength 0.5:f32

let gray (sh (target:tex2d src:tex2d) {
  let c (sample src uv)
  let l (lum c)
  mix c (vec4f l l l 1) strength
})
```

## Engine

The engine runs qs. A page can hold any number of engine instances, each added with a single `<script>` tag, and each instance owns all of its state: nothing is shared globally between instances.

The engine API is the same from js and from qs. This is what lets an editor, which is itself an instance running qs scripts, control another instance running a game.

### Render targets

Each instance has exactly one render target: a WebGPU canvas or an `OffscreenCanvas`. An instance can also be shown in a viewport inside another instance, as a game is shown inside the editor. Such an instance shares its parent's GPU device, so the parent can draw its output.

### Scenes

An instance runs one scene at a time. A scene is an ordinary script that the instance has selected. Scripts imported by the scene live exactly as long as it does: when the scene changes, the scene, everything it imported and every hook handler they registered go away. Nothing else persists.

A script is either fetched from a URL or given directly as source text. An editor's files are given as source text.

### Hooks

`on name handler` registers a function to run on an instance hook. `name` is a word and is not evaluated; `handler` is any expression that evaluates to a function.

```qs
on ready (fn (e) { ... })
on update (fn (e) { ... })
on render draw_frame       # draw_frame is passed, not called
```

`on` can only appear at a script's top level. A script can register at most one handler per hook, and a second one is a compile-time error. Handlers cannot be removed; they go away with their scene. Handlers from different scripts run in the order they were registered.

Every handler receives one plain dict, so fields can be added later without breaking anything.

| hook | runs | fields |
| --- | --- | --- |
| `ready` | once the scene has loaded | |
| `update` | at a fixed time step | `dt`: the fixed step in seconds |
| `render` | once per displayed frame | `dt`: seconds since the last frame; `alpha`: how far it is, from 0 to 1, between the last update and the next |
| `keydown`, `keyup` | when a key is pressed or released | `key`: the character, e.g. `"a"`; `code`: the physical key, e.g. `"KeyA"`; `repeat`: whether it is a held key's repeat |
| `pointerdown`, `pointerup`, `pointermove` | on pointer input | `pos`: a `vec2f` in target pixels; `uv`: a `vec2f` from 0 to 1, as in shaders; `button`; `id` |
| `resize` | when the render target changes size | `size`: a `vec2u` |

`update` runs 60 times a second by default, and the rate can be set per instance. When frames fall behind, `update` runs extra times to catch up, up to a cap, and the rest of the lost time is dropped.

### Reflection

Whoever controls an instance, from js or from qs, can inspect it:

- its current scene and loaded scripts
- each script's top-level bindings, readable and writable as plain data
- its `error` and `output` events (`print` writes to the instance's output)
- pausing, stepping and resuming its loop

## Modules and errors

`import` evaluates a file once per scene and returns its top-level bindings as a dict. The path must be a string literal, so the engine can find and fetch every file a scene needs before running it, and `import` never waits. A path is resolved relative to the importing script and names the file exactly, including its extension. An import cycle, such as `a.qs` importing `b.qs` which imports `a.qs`, is a compile-time error.

```qs
let m (import "path/to/file.qs")
m.helper 1 2
```

The dict is live. Reading a field reads the module's current binding, and `set` on a field changes the module's binding, just as [Reflection](#reflection) allows. Every script that imports a module gets the same dict.

```qs
# counter.qs
let count 0
let bump (fn () (set count (count + 1)))

# main.qs
let m (import "counter.qs")
m.bump
m.count              # 1
set m.count 5        # counter.qs now sees 5
```

A runtime error aborts the current script or callback, and the engine reports it. There is no try/catch.

Type errors, such as `f32 + i32` or a value that does not match an annotation, are found as early as possible:

- In shaders, every type error is a compile-time error.
- On the host, a type error is a runtime error. It is also a compile-time error whenever the compiler can prove it, from literals, annotated bindings and annotated parameters. The host does not infer types beyond that, so an unannotated parameter is only checked when the function runs.

```qs
let add (fn (a b) (a + b))
add 1:f32 2:i32          # runtime error

let x:f32 1
x + 2:i32                # compile-time error
```

## Open questions

- The engine API: its js and qs functions, the `update` catch-up cap, surfaces, and reading GPU results back.
- How qs listens to another instance's events, such as an editor watching a game's `error` and `output`.
- Persistence and messaging between scenes, a separate mechanism.
- Compiling in the page needs `new Function`, which a strict Content Security Policy blocks unless it allows `unsafe-eval`. Exporting a finished game as precompiled js would avoid this.
- Letting the page's js give an instance extra functions (not needed for the prototype).
- Structs and default parameter values.
- Lone names as special-form operands. Under "arguments are never called", `while ready { ... }` tests the function `ready` itself, which is always truthy, and `return foo` returns the function. Keep this, warn about it, or call lone names in condition positions.
- Whether a `let` annotation applies to later `set`s on the host, converting and checking each new value. In shaders a binding has one static type regardless.
- The str and list library beyond `cat`.
- Dict literals.
- `set` past the end of a list, and `pop` on an empty list.
- A dict key named `__type__`, which would make the dict load back as a typed value: reserve it, reserve every `__name__` key, or escape it when serializing.
- Dict order. Plain js objects always put integer-like keys such as `"1"` first, in ascending order, so dicts cannot keep insertion order for them as currently promised.
- Out-of-range array indexes (wgsl leaves this partly implementation-defined).
- A shader whose target is also one of its texture arguments, such as `tint photo photo`. WebGPU cannot read and write one texture in the same pass, so this must be either an error or a hidden copy.
- Whether qs code can raise its own errors.
