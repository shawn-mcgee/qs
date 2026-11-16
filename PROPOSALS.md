# New language: syntax spec (draft)

A new language, separate from Quicksilver. It compiles ahead of time to two backends:

- **js** for host code in the browser
- **wgsl** for WebGPU shaders

The language is statically typed everywhere: every value's type is known at compile time, in host code and in shaders alike.

A central goal is a **live editor written in the language itself**. Saving any file, including one of the editor's own, updates the running program in place without restarting it, and keeps the state marked to survive (`@` names). So the compiler runs in the browser, compiles each module as it is saved, and swaps the new code in. See [Live reload](#live-reload) for the rules this imposes.

This document records decisions as they are made. Each rule says what the syntax is and, where the backends differ, what it compiles to. Anything not covered here is undecided: do not guess, and check [Open questions](#open-questions).

Library and engine names used in examples (such as `sample`, `load_image`, `tex2d` and `Context`) are illustrative unless a section says otherwise.

## Lexical structure

### Comments

`#` starts a comment that runs to the end of the line. There are no block comments. A `#` inside a [string literal](#strings) is not a comment.

```
# a whole-line comment
x := 1   # a trailing comment
```

### Names

Two prefixes are part of a name and give it meaning:

- `_name` is [private](#modules) to its file.
- `@name` is [kept](#kept-state): its value survives live reloads. Only top-level names can be kept.

Because the prefix is part of the name, it is written at every use.

### Strings

A string literal is written in double quotes. Its type is `str`, which is host-only: using a `str` in shader code is a compile error.

The escapes are `\n`, `\t`, `\"`, `\\` and `\u{...}` (a Unicode code point in hex).

A string prefixed with `$` is interpolated: each `{expr}` inside it is evaluated and inserted. In a plain string, braces have no special meaning.

```
name := "Ana"
msg := $"Hello {name}, you are {age}"
raw := "{not interpolated}"
tab := "a\tb"
```

Strings are joined by interpolation, or with the library function `cat`. `+` is only for numbers, so `"a" + "b"` and `"a" + 1` are compile errors.

```
full := $"{first} {last}"
same := cat(first, " ", last)
"a" + "b"            # error: use interpolation or cat
```

`cat` and `print` accept only `str` arguments, through an ordinary [variadic parameter](#variadic-parameters) `...parts: [str]`. Other values are turned into strings with interpolation or an explicit conversion.

```
print("x =", x)          # error if x is not a str
print($"x = {x}")        # ok
print("x =", str(x))     # ok: str(x) is an explicit conversion
```

### Blocks

Braces `{ }` delimit blocks: function bodies and the bodies of control flow. Indentation is not significant.

```
if x > 0 {
  y = 1
}
```

### Statements

A newline ends a statement, as in Go. There are two exceptions, where the newline is only whitespace:

- inside `( )` or `[ ]`
- after a token that cannot end a statement: a binary [operator](#operators) (including `and`, `or` and the fallback `else`), `,`, `:`, `=`, `:=`, a [compound assignment](#compound-assignment) operator, or an opening bracket

**There is no statement separator.** `;` is not part of the language, and has no other use, so a stray `;` is always a compile error, never silently accepted. Each statement takes its own line. A block can still hold one statement on the line it opens, as in `if c { y = 1 } else { y = 2 }`.

```
x := 1
y := x +
  2            # continues: the line above ends in +
z := (x
  + 2)         # continues: inside ( )
a := 1; b := 2 # error: ; is not part of the language; put each statement on its own line
```

A line that *starts* with an operator does not continue the line before it. Break long expressions after the operator, not before it.

```
w := x
  + 2          # two statements: w := x, then the expression + 2
```

## Types

### Built-in scalar types

There are two scalar types: `num` and `bool`.

**`num` is the one number type.** On the host it is a 64-bit float, js's native number, and in shaders it is a 32-bit float, wgsl's `f32`. There are no integer types and no other float sizes: every number literal, length, index and loop counter is a `num`. So numbers never need converting, and number literals never need a type.

**The two backends can give different results.** The same arithmetic is done in 64 bits on the host and in 32 bits in a shader, so results can differ in their low digits. A 32-bit float holds whole numbers exactly only up to 2^24 (16,777,216), so in shaders, counts and indexes beyond that are not exact. A `num` passed from the host to a shader is rounded to 32 bits. Code that must agree on both backends should not depend on more precision than 32 bits.

**Why one number type.** The rendering pipeline is only rectangles drawn by [fragment shaders](#shaders), with no compute shaders. The strong reasons for integer types on the GPU, atomics and bit operations (e.g. for hashing), come from compute work. The remaining integer uses, indexes, wgsl builtins and texel coordinates, are converted by the compiler. Stored formats, such as 8-bit texels, belong to textures and buffers, not to code.

**In wgsl, an integer operand is truncated.** Where wgsl needs an integer, such as an array index, the compiler converts the `num` with `i32(x)`, which truncates toward zero. The host does the same, so [indexes](#indexing) behave alike on both backends.

### Vectors

The vector types are `vec2`, `vec3` and `vec4`, holding 2, 3 or 4 `num`s. They compile to wgsl's `vec2f`, `vec3f` and `vec4f`. Since there is one number type, there are no vectors of other element types, and no bool vectors.

A vector type's name is also its constructor: `vec3(0)`, `vec3(1, 2, 3)`. A vector's components can be changed when it is held in a [mutable place](#mutability), such as a `mut` binding.

```
UP := vec3(0, 1, 0)
UP.y = 5                       # error: UP is not mut

mut v := vec3(0)
v.x = 1                        # ok: v is mut
```

**Vector literals.** Angle brackets make a vector: `<1, 2, 3>`. Components are separated by commas, as in call arguments. A component can itself be a vector, which is flattened into its components. The total component count, 2 to 4, gives the vector's size.

```
p := <1, 2, 3>              # vec3
q := <i, j>                 # vec2
c := <p, 1>                 # vec4: p's three components, then 1
<1>                         # error: a vector needs 2 to 4 components
```

A `<` where an operand is expected starts a vector literal. A `<` after an operand is the less-than operator. Inside a vector literal, `>` always closes it. (A comparison cannot be a component anyway: its result is a `bool`, and there are no bool vectors.)

### Matrices

Matrices mirror [vectors](#vectors). The matrix types are `mat2`, `mat3` and `mat4`: square matrices of `num`s, 2x2, 3x3 and 4x4, compiling to wgsl's `mat2x2f`, `mat3x3f` and `mat4x4f`. There are no non-square matrices. A 2D affine transform, the main use of wgsl's `mat3x2f`, is a `mat3` applied to `<x, y, 1>`. As with vectors, a matrix's elements can be changed when it is held in a [mutable place](#mutability).

**A matrix type's name is also its constructor.** A constructor takes either:

- column-major scalars: all of column 0, then column 1, and so on
- column vectors, one per column
- a single number, which gives the identity matrix scaled by it, as in glsl

```
I := mat4(1)                 # the identity
r := mat2(c, s, -s, c)       # column-major scalars
n := mat2(<1, 2>, <3, 4>)    # column vectors: column 0 is <1, 2>
```

**Columns are indexed with dots,** as for [indexing](#indexing): `m.0` is column 0, a vector, and `m.0.1` is row 1 of column 0. Assigning a column or element needs the matrix to be in a mutable place.

```
mut m := mat4(1)
m.3 = <tx, ty, tz, 1>           # set the translation column
```

**`*` is linear algebra**, as in wgsl: matrix times matrix, matrix times vector, and vector times matrix. `+` and `-` work element-wise on matrices of the same shape.

```
w := m * <x, y, z, 1>           # transform a point
```

Matrices have no literal of their own: `<<1, 2>, <3, 4>>` is a `vec4`, since vector literals flatten.

### Arrays and lists

Square brackets make arrays and lists:

| type | length | in shaders (wgsl) |
| --- | --- | --- |
| `[T, N]` | `N`, known at compile time, never changes | `array<T, N>` |
| `[T]` | a **list**: its length is known only at runtime, and it can grow and shrink on the host when it is in a [mutable place](#mutability) | `array<T>` (runtime-sized) |

`[T, N]` reads like wgsl's `array<T, N>`. Where a type can appear in an expression, as after [`is`](#any), `[num, 3]` is a type and not a list literal, because `num` is a type and types and values share one namespace.

**Lists are plain values**, like arrays and [dicts](#dicts): binding, assigning or passing one copies it, under the general [copy rule](#copying-and-sharing). To share a list, use `ref`. On js, the compiler can skip a copy nobody can observe, such as a copy of a list that is never changed.

```
a : [num] = [1, 2]
b := a              # a copy: changes to b never reach a
c := ref a          # shared: c is another name for a
```

When a list is passed to a shader, its current length is fixed for that shader call, so it becomes a runtime-sized wgsl array. The list can keep growing on the host afterwards.

**A list changes when its place is mutable.** In a `mut` binding (or another [mutable place](#mutability)), a list's elements can be assigned and its size can change. Otherwise it is frozen: no new value, no element changes, no growing. A `[T, N]` array's elements can change in a mutable place, but its size never does. Types carry no `mut` of their own: `mut [T]` and `[mut T]` are compile errors.

```
xs := [1, 2]
xs.0 = 9                      # error: xs is not mut

mut ys := [1, 2]
ys.0 = 9                      # ok
push(ref mut ys, 3)           # ok: push is illustrative
ys = [4, 5, 6]                # ok

empty : [num] = []            # an empty literal needs its type written
```

**Lists and dicts have no methods.** Their operations, such as adding, removing and finding items, are separate library functions that take the collection as an argument. These are ordinary functions, so the usual [argument rules](#ref-parameters) apply: a function that changes a list takes a `ref mut [T]` parameter, and the call shares the list with `ref mut`.

```
fixed := [1, 2]
push(ref mut fixed, 3)     # error: fixed is not mut
n := len(fixed)            # ok: reading needs no ref
```

### `any`

`any` holds a value of any type, together with a runtime tag saying which type it is. Its main use is mixed lists, `[any]`. `any` is host-only.

A value of any type can be stored where an `any` is expected. Reading one back gives an `any`, which must be checked with `is` and a type name before it is used as that type.

**A type on the right of `is` makes it a type test.** If the right side of `is` is a type (a built-in type name, a composite's name, or a type expression such as `[num]`), `x is T` tests the value's type. Otherwise `is` is [equality](#operators). Types and values share one namespace of names, so a binding cannot have the same name as a type in scope, and there is never a doubt which is meant. `x is not T` is the negated type test. The check narrows a local binding, by the same rules as [optionals](#checking-before-use).

```
stuff : [any] = [1, "two", vec3(0)]
for x in stuff {
  if x is num { print(str(x + 1)) }    # x is a num here
  elif x is str { print(x) }           # x is a str here
}
```

`[]` is still the empty list literal, for any element type: `empty : [any] = []`.

### Anonymous composites

An **anonymous composite** is a [composite](#composites) value written without a type name. Its fields are fixed when it is created: it is a record, not a map. (For a map, see [Dicts](#dicts).)

Because an anonymous composite literal declares its fields, each field is written as a [declaration](#declaration): `name := value`, or the typed form `name : Type = value`. Fields are separated by [commas or newlines](#construction), and a field can be `mut`, as in a composite definition. A named composite literal still uses plain `=`, since its fields already exist, and a [dict](#dicts) literal uses plain `=` too. So a declaration (`:=`, or `:` before `=`) is what marks an anonymous composite field.

```
p := { name := "ana", age := 31 }         # fields name: str and age: num
mut q := {
  mut count := 0
  label : str = "clicks"     # the typed form
}
r := Person { name = "ana", age = 31 }    # a named composite: = sets existing fields

p.name                                     # "ana"
q.count += 1                               # count is a mut field, and q is mut
```

Each field has its own type, checked at compile time, like any composite. Anonymous composites are plain values: binding, assigning or passing one copies it.

**Anonymous composites have no methods.** `m.keys()` always calls the value stored in the field `keys`. Operations on anonymous composites are ordinary functions.

A `{` where an operand is expected starts an anonymous composite or dict literal, told apart by whether entries are declarations (`:=` or `name : Type =`) or plain `key = value`. Elsewhere, `{` starts a block. Right after a condition, `{` always starts the block (see [Literals in conditions](#literals-in-conditions)).

### Dicts

`{T}` is a **dict**: a collection of values of type `T`, looked up by string keys. Like a list, a dict can only change in a [mutable place](#mutability): there, keys can be added and removed, and values replaced. `{any}` holds values of mixed types. Dicts are host-only plain values: binding, assigning or passing one copies it.

A dict literal is written in braces, each entry a key, `=`, and a value, separated by [commas or newlines](#construction). A key is a name, a string literal, or a parenthesized expression for a computed key. This is the same `=` form as a named composite literal. An anonymous composite declares its fields instead (`:=`, or `name : Type =`), so the two are never confused, and mixing declarations and `key = value` entries in one literal is a compile error.

**Keys are always strings.** A computed key, in a literal (`(k) = 1`) or in a lookup (`d.(k)`), must be a `str`. Nothing is converted: `d.(3)` is a compile error. (Digits written after `.`, as in `d.0`, are a name-like shorthand for the string key `"0"`.)

```
ages := { ana = 31, bo = 29 }         # {num}
names := { "my key" = 1, ("x-y") = 2, (k) = 3 }  # string literal and computed keys
bad := { name := "x", age = 3 }                  # error: mixes a declaration and a dict entry
stuff : {any} = { n = 1, s = "two" }
empty : {num} = {}                    # an empty literal needs its type written
rec := { name := "ana" }              # a declaration makes an anonymous composite, not a dict
rec2 := { name : str = "ana" }        # also an anonymous composite
```

**Reading a key gives an [optional](#optional-types-t)**, since the key may be missing: `d.k` has type `T?`, checked with `is nil` or passed up with `?`. Assigning `d.k = value` adds the key, or replaces its value if it exists. Both need the dict to be in a mutable place.

| form | meaning |
| --- | --- |
| `d.ana` | the key `"ana"` |
| `d.0` | the key `"0"`: digits after `.` are a string key on a dict |
| `d."my key"` | a string literal after `.`: the key `"my key"` |
| `d.(k)` | a computed key: `k` must be a `str` |

```
n := ages.ana                # num?
if n is nil { ... }          # ana is missing
ages.cy = 40                 # error: ages is not mut
mut scores := { ana = 3 }
scores.bo = 5                # adds the key "bo"
scores.ana = 4               # replaces ana's value
age := ages.(name)?          # in a function returning an optional: pass a missing key up
```

### Indexing

Elements and fields are reached with dot notation. There is no `xs[i]` form: square brackets are only for array and list types and literals.

| form | meaning |
| --- | --- |
| `xs.0` | a constant index: digits after `.` |
| `xs.(i)` | a computed index: a parenthesized expression after `.` |
| `p.x` | a field, or a vector component |

```
first := arr.0              # arr: [num, 4], a fixed array
item := arr.(i)
arr.(i + 1) = 9             # if arr is mut
m.0.1                       # matrix column 0, component 1
v.1                         # the same as v.y
```

- Arrays, lists, vectors and matrices take a `num` index, and a [dict](#dicts)'s computed key must be a `str`.
- **An index is truncated toward zero**, on both backends: `xs.(1.5)` reads `xs.(1)`, and `xs.(-0.5)` reads `xs.(0)`. A fractional index is never a fault. Only the truncated index is checked against the length.
- **Reading a list gives an [optional](#optional-types-t).** A list can be empty, so there may be no item to read: `xs.(i)` and `xs.0` on a list have type `T?`, like a [dict](#dicts) read. An out-of-range list read is empty. Sharing one, `ref xs.(i)`, gives a `ref? T`.
- **Fixed arrays, vectors and matrices always have their full size,** so reading one is not optional. An out-of-range index on one is a [fault](#faults).
- On every kind, an out-of-range write is a [fault](#faults).
- After `.`, digits are never read as part of a float: `m.0.1` is two indexes, not `m` followed by `0.1`. (On a dict, the digits are a string key instead of an index.)
- Assigning through an index needs the collection to be in a [mutable place](#mutability), as for fields.

**Length.** The built-in `len(x)` gives the number of elements of an array or list, the number of keys of a dict, or the length of a string, as a `num`. It is one overloaded function. (In wgsl, `arrayLength`'s `u32` is converted.) For a `[T, N]` array, `len(xs)` is the compile-time constant `N`.

```
n := len(xs)
last := xs.(len(xs) - 1)    # T?: empty if xs is empty
if last is nil { ... }
```

### Composites

User-defined aggregate types (named fields, like structs) are called **composites**.

#### Definition

`type { ... }` is a composite type. It is named by binding it with the ordinary [declaration](#declaration) syntax, just as functions are named with `fn`. Each field is `name: Type`. Entries in a type definition (fields, and the [constructors](#construction) and [functions](#functions-and-methods) below) are separated by commas or newlines, by the same rule as [literal entries](#construction), with a trailing comma allowed. A field can be marked [`mut`](#mutable-fields).

```
Light := type {
  pos: vec3
  mut on: bool
}

Point := type { mut x: num, mut y: num }    # a short type on one line
```

A field can have a default value, written like a declaration's value: `name: Type = value`.

```
Light := type {
  pos: vec3
  mut on: bool = true
}
```

#### Construction

A composite value can be made in two ways.

**Composite literals.** The type's name, then braces that assign each field with `=`, as in an object literal. A literal builds the whole value at once.

```
p := Point { x = 10, y = 10 }
```

**Entries are separated by commas or newlines.** This applies to every braced literal: composite, [anonymous composite](#anonymous-composites) and [dict](#dicts). A trailing comma is allowed. Under the [statement rule](#statements), a line ending in `,` or `=` continues on the next line.

```
p := Point { x = 10, y = 10 }       # commas on one line
q := Point {                        # newlines
  x = 10
  y = 10
}
r := Point {
  x = 10,                           # commas across lines, with a trailing comma
  y = 10,
}
```

Fields can be listed in any order. A field with a default can be left out, and then gets its default. A field without a default must be given. Giving a field twice, or a name that is not a field, is a compile error.

```
Light := type {
  pos: vec3
  mut on: bool = true
}

Light { pos = vec3(0) }               # on is true
Light { on = false, pos = vec3(0) }   # any order
Light { on = false }                  # error: pos has no default
```

**Constructors.** A composite's body can contain constructors alongside its fields. A constructor is written like an overload entry in a [function namespace](#function-namespaces-overload-sets): a parameter list and a body, with no `fn`. A type with constructors is called like a function, and the call is resolved among its constructors by the same [rules](#resolution) as overloads.

A constructor is an ordinary function that must `return` an instance of its composite, typically built with a composite literal. There is no `self` and no partly built value, so immutable fields need no special rule: every field gets its value when the literal is evaluated. Returning any other type is a compile error, and the return type can be left out.

```
Point := type {
  mut x: num
  mut y: num

  () {
    return Point { x = 0, y = 0 }
  }
  (x: num, y: num) {
    return Point { x = x, y = y }      # the field x, set to the parameter x
  }
}

a := Point()           # the first constructor
b := Point(1, 2)       # the second constructor
```

Inside a literal, the name before `=` is always a field of the type, and the value after it is an ordinary expression. So `x = x` sets the field `x` to the parameter `x`.

#### Functions and methods

A composite body can also contain named functions. A function is written as its name, then a parameter list, an optional return type, and a body, as in a js class. There is no `:=` and no `fn`.

Functions in a composite are not bindings: they cannot be reassigned, and they are not fields. The body's entries are told apart by their shape:

| entry | meaning |
| --- | --- |
| `name: Type` | a field |
| `(params) { ... }` | a constructor |
| `name(params) { ... }` | a function |

Composite functions are always **static**. They belong to the type's namespace, are reached through the type's name, and have no hidden receiver.

**Methods.** A function whose first parameter has the composite's own type, `Point`, `ref Point` or `ref mut Point`, is a **method**. `self` is only a conventional name, not a keyword. Any name works. A method can be called in two ways:

- with dot notation on a value: `p.hypot()`
- statically, through the type, passing the receiver as the first argument: `Point.hypot(...)`

Both forms compile to the same free function, outside the composite. This is what lets composites with methods still compile to plain wgsl structs, which have no methods.

**Untyped receivers are read-only refs.** In a composite function, the first parameter can be left untyped. It then has type `ref T`, where `T` is the composite, which makes the function a method. This is the one exception to the rule that [every parameter must have a type](#parameters).

**A dot call shares its receiver automatically.** In `p.move(1, 0)`, `p` is shared with the method's `ref` or `ref mut` receiver without writing `ref`, whether `p` is a ref, a plain binding, or a temporary. This is a deliberate exception to the [no hidden refs](#ref-shares) rule: the dot itself marks the receiver. A static call follows the ordinary argument rules, so a plain receiver needs `ref` or `ref mut` there: `Point.move(ref mut p, 1, 0)`.

The usual [mutability rule](#sharing-cannot-add-mutability) applies. An untyped receiver is a [read-only ref](#sharing-cannot-add-mutability), so a method that only reads needs nothing written, and can be called on any value, including constants and literals. **A method that changes its receiver says so** with `self: ref mut T`. Through it, the method can change exactly the `mut` fields, and a dot call on it needs a [mutable place](#mutability), such as a `mut` binding or a `ref mut T`.

```
Point := type {
  mut x: num
  mut y: num

  origin() { return Point { x = 0, y = 0 } }                      # static, not a method
  hypot(self) { return sqrt(self.x * self.x + self.y * self.y) }  # self: ref Point, read-only
  move(self: ref mut Point, dx: num, dy: num) {                   # changes self
    self.x = self.x + dx                                        # x is a mut field
    self.y = self.y + dy
  }
}

mut p := Point { x = 0, y = 0 }
p.move(1, 0)               # p is shared automatically: p.x is now 1
Point.move(ref mut p, 1, 0)    # the same call, written statically
h := p.hypot()

UP := Point.origin()
UP.hypot()                 # ok: hypot only reads
UP.move(1, 0)              # error: UP is not mut
```

**The receiver's type decides sharing.** This is one of the two places where an unannotated name is automatically upgraded to a `ref` type (the other is a [`for` loop's item](#items-and-indices)). Writing the plain type opts out: with `self: Point`, a dot call copies its receiver, so changes inside the method never reach the caller. Writing `self: ref Point` is the same as leaving it untyped.

```
Point := type {
  mut x: num
  reset(self: ref mut Point) { self.x = 0 }   # changes the caller's point
  preview(mut self: Point) { self.x = 0 }     # self is a mutable copy: the caller's point is unchanged
  show(self) { print(str(self.x)) }           # self: ref Point: reads the caller's point
}
```

In wgsl, a ref receiver becomes a `ptr<function, Point>` parameter.

**Overloads.** A composite function is overloaded the same way as a [function namespace](#function-namespaces-overload-sets): its name, then a braced block of `(params) { body }` entries. This mirrors `fn { ... }`, without the `fn`. Calls are resolved by the same [rules](#resolution).

```
Person := type {
  name: str

  # one function, no overloads
  wave(self) { print("*waves*") }

  # an overload set
  greet {
    (self) { print("Hello") }
    (self, name: str) { print("Hello", name) }
  }
}
```

Each entry is treated on its own: an entry whose first parameter is an untyped receiver, or has the composite's type, can be called as a method.

- One overload set can mix method entries (with a receiver) and static entries (without one).
- A dot call such as `p.greet("Ana")` is resolved only among the method entries.
- A static call such as `Person.greet(...)` is resolved among all entries, with a receiver counting as an ordinary first argument.

```
Person := type {
  name: str

  greet {
    (self) { print("Hello", self.name) }   # method entry
    (name: str) { print("Hello", name) }   # static entry
  }
}

p.greet()               # method entry
Person.greet("Ana")     # static entry
Person.greet(ref p)     # method entry, called statically
```

**Names.**

- Writing the same function name twice in one composite is a compile error, even with different parameters. Overloads must use the `name { ... }` block.
- A field and a function can share a name. A call decides which is meant: `p.size` is the field, and `p.size()` is the function.

```
Person := type {
  greet(self) { ... }
  greet(self, name: str) { ... }   # error: greet is already defined; use greet { ... }
}

Box := type {
  size: num
  size(self) { return self.size * 2 }   # the field size, inside the function size
}

b.size        # the field
b.size()      # the method
```

#### Ref composites

`ref type { ... }` defines an [inherently ref type](#inherently-ref-types). Every binding of one needs `ref` in its value, and the type is host-only.

```
Node := ref type {
  value: num
}

n := ref Node { value = 1 }
m := n                   # error: Node is a ref type and cannot be copied implicitly; write ref n to share it
```

**Ref fields.** A field that holds a ref must say so in its type, with `ref T`, `ref mut T` or `ref? T`, just as a [ref parameter](#ref-parameters) does. Writing a ref type as a field's type without `ref` is a compile error. So a field's type always shows whether it is shared.

```
Scene := ref type {
  root: ref Node
  mut selected: ref? Node = nil
  bad: Node                       # error: Node is a ref type; write ref Node
}
```

A plain (non-ref) composite can also have ref fields. Copying it is a shallow copy: its plain fields are copied, and its ref fields are shared with the original. This is how a value type points at shared data. A composite with any ref field is host-only, since a wgsl struct cannot hold a pointer.

```
Sprite := type {
  pos: vec2
  tex: ref tex2d
}

a := Sprite { pos = vec2(0), tex = ref photo }
b := a              # b.pos is an independent copy; b.tex shares a.tex
```

Setting a ref field, in a literal or by assignment, follows the [no hidden refs](#ref-shares) rule: the value must be written with `ref`, as in `tex = ref photo`.

**Mutable ref fields can repoint.** Ref bindings can [never be repointed](#assigning-through-a-ref), but a ref field marked `mut` can be pointed at a different shared value, or set to `nil` if it is optional (`ref? T`). This is what lets linked structures be built after construction. An immutable ref field keeps the ref it was constructed with.

```
Node := ref type {
  value: num
  mut next: ref? Node = nil
}

a := ref mut Node { value = 1 }    # ref mut: a can be changed through
b := ref mut Node { value = 2 }
a.next = ref b       # ok: next is a mut ref field, and a is a ref mut
a.next = nil         # ok: next is optional
```

Assigning a `mut` ref field has two forms, chosen by the right side:

- **`s.f = ref y`** (or `nil`) repoints the field.
- **`s.f = value`** writes `value` into the shared value the field refers to, just as `x = value` does for a `ref mut` binding. Everything sharing that value sees the change.

Both need the field to be `mut`, in a [mutable place](#mutability). The second also needs the field's type to be a `ref mut`, as for [any write through a ref](#sharing-cannot-add-mutability).

```
Sprite := type {
  mut pos: ref mut vec2
}

mut s := Sprite { pos = ref mut v }
s.pos = vec2(1)       # writes into the shared vector
s.pos = ref other     # repoints the field to share other
```

**The shared value is not part of the composite.** So a composite in an immutable place does not freeze what its ref fields refer to: changing *through* a ref field (`s.pos.x = 1`) follows the ref's own type, `ref mut vec2` here, whatever `s` and the field's `mut` say.

Ref fields are host-only (a wgsl struct cannot hold a pointer), so wgsl's pointer limits do not apply to them.

#### GPU compatibility

A composite can be used as a wgsl struct if and only if every one of its fields has a wgsl-compatible type. This applies recursively: a field whose type is another composite must itself be compatible.

- A composite with only types such as `num`, `vec3`, `[num, 4]` or other compatible composites can be used in shader code, and compiles to a wgsl `struct`.
- A composite with any host-only field, such as a `str`, or any ref field (`ref T` or `ref? T`), is host-only. Using it in shader code is a compile error.

The same composite definition is used by host code and shader code. There is no separate GPU version to keep in sync.

**There is one level of compatibility.** wgsl itself has two: some types are allowed in shader code but not in buffers sent from the host. `bool` is the main one. This language hides that difference. When a compatible composite is passed from js to the GPU, the compiler stores each such field in a buffer-safe form and converts it back in the shader. For example, a `bool` is stored as a wgsl `u32`. Users never see the stored form.

```
Light := type {
  pos: vec3
  on: bool                # stored as a u32 in the buffer, a bool in the shader
}
```

**Compatibility is inferred, and can be asserted.** The compiler works out from the fields whether a composite is compatible, so no annotation is needed. A definition can also carry the optional [`gpu` tag](#the-gpu-tag), `Light := gpu type { ... }`, which asserts compatibility. With the tag, an incompatible field is a compile error at the definition itself, instead of in some shader that later uses the composite. Without the tag, the error appears at the shader use, and should name the offending field and where it is defined.

Field mutability (see [Mutable fields](#mutable-fields)) is checked only by the compiler and does not affect the wgsl struct.

### Optional types: `T?`

`T?` is an **option**: either a `T`, or **empty**, written `nil`. It says that a value may be absent, such as a missing dict key or an unset `next` node. Absence is not failure: an operation that can go wrong returns a [result](#errors), `T!`, instead. Any type can be made optional, and `T?` can be used anywhere a type appears: bindings, parameters, fields, return types and element types.

The language has exactly these two result shapes, options and results, and no general union types.

For refs, the `?` belongs to the `ref` keyword: `ref? T` is an optional ref, a ref that may point to nothing.

```
Node := ref type {
  value: num
  mut next: ref? Node = nil   # an optional ref field
}

best : num? = nil             # an optional plain value
age := ages.ana               # num?: the key may be missing
a : ref Node = nil            # error: a is not optional; write ref? Node
x : num = nil                 # error: x is not optional; write num?
```

`nil` needs no `ref` keyword, even for a `ref? T`. A binding that starts as `nil` needs its type written, since `nil` alone does not say what it could hold.

`x is nil` and `x is not nil` test whether an optional is empty. (On a `ref? T`, this is the one use of `is` on a ref that is about what the ref points to, not about its contents.)

A `T` can be used wherever a `T?` is expected. A `T?` can be used as a `T` only where it has been checked.

**A `?` binds to the type it follows.** `ref? T` is an optional ref: the ref itself may be empty. `ref T?` is a ref that is always present, to shared storage holding a `T?`, so an optional value can be shared and set to `nil` through the ref.

```
mut best : num? = nil
r := ref mut best              # a ref to an optional num
r = 5                          # best is now 5
r = nil                        # best is empty again
```

**Optionals do not nest.** `T??` is the same type as `T?`, so there is always one level to check. `ref? T?` would have two levels of empty, one for the ref and one for its value, so it is a compile error: write `ref? T` or `ref T?`. Reading a `{num?}` gives a `num?`, which is empty both for a missing key and for a stored `nil`.

```
d : {num?} = { a = nil, b = 2 }
d.a          # num?: empty, a stored nil
d.zz         # num?: empty, a missing key
d.b          # num?: 2
```

#### Checking before use

An optional must be checked before it is used as a `T`. Using it as a `T`, reading a field, or calling a method through it is a compile error, unless the compiler can see that it is not empty at that point. Where it has been checked, it is treated as a plain `T` (or a plain `ref T`). So an empty-value error cannot happen at runtime.

**Only local bindings are narrowed by a check, never field paths.** A field such as `n.next` could be set to `nil` inside the branch by any code that shares `n`, including a function called there. So bind the field to a local name first, then check that name. When the compiler sees a field path checked and then used, its error should suggest binding it first.

```
nxt := ref n.next             # nxt: ref? Node
if nxt is not nil {
  print(nxt.value)            # ok: nxt is checked here
}

if n.next is not nil {
  print(n.next.value)         # error: field paths are not narrowed; bind n.next to a local first
}
```

These forms narrow an optional local:

| form | where the local is treated as checked |
| --- | --- |
| `if x is not nil { A }` | in `A` |
| `if x is nil { A } else { B }` | in `B` |
| `if x is nil { return }` (or `break`, `continue`) | in the rest of the enclosing block, after the `if` |
| `x is not nil and E` | in `E` |
| `x is nil or E` | in `E` |

```
if nxt is nil { return }
print(nxt.value)              # ok: early exit above

if nxt is not nil and nxt.value > 0 { ... }
if nxt is nil or nxt.value is 0 { ... }
```

#### Fallbacks: `else`

`a else b` gives `a`'s value if it has one, and otherwise `b`. `a` must be an optional `T?`. If `b` is a `T`, the result is a `T`, no longer optional. `b` is only evaluated when `a` is empty, as with `and` and `or`.

```
age := ages.ana else 0             # num
name := names.(id) else "unknown"  # str
first := xs.0 else ys.0 else 0     # chains: (xs.0 else ys.0) else 0
```

If `b` is itself optional, the result is optional too, which is what makes chains work. An `else` whose left side is not optional is a compile error.

In an `if` condition, `else` as an operator comes before the block, and the `if`'s own `else` comes after a block, so the parser can always tell them apart. Parentheses make such conditions easier to read: `if (d.n else 0) > 3 { ... } else { ... }`.

`else` binds tighter than arithmetic and comparison, since a fallback almost always supplies the operand of what comes next (see [Precedence](#operators)):

```
ages.a else 0 + 1      # (ages.a else 0) + 1
d.n else 0 > 3         # (d.n else 0) > 3
```

### Number literals

A number literal starts with a digit (so `0.5`, not `.5`). It can be written in decimal, hex (`0xff`), binary (`0b1010`) or octal (`0o17`), and a decimal literal can have a fraction and an exponent (`2.5e-4`). `_` can separate digits anywhere after the first (`1_000_000`, `0xff_ff`). Every number literal is a `num`.

```
big := 1_000_000
eps := 1e-6
orange := 0xff8800
```

There are no number conversions, since there is one number type, and no implicit conversions of any kind.

## Bindings

### Declaration

A declaration introduces a new name and gives it a value. The full form is `name : Type = value`, with the type between the `:` and the `=`.

```
x : num = 1
```

When the type is left out, the `:` and `=` meet and form `:=`. The type is then inferred from the value.

```
x := 1
```

Every declaration must have a value. There are no uninitialized or zero-initialized declarations.

```
mut x : num        # error: a declaration needs a value
mut x : num = 0    # ok
```

### Assignment

`=` gives an existing place a new value. The target must be a [mutable place](#mutability): a `mut` binding, a `mut` field of one, an element of one, or a `ref mut`. For what `=` does on a ref, see [What `=` does](#what--does).

```
mut x := 1
x = 2
```

### Compound assignment

`+=`, `-=`, `*=` and `/=` combine an arithmetic operator with assignment: `x += 1` means exactly `x = x + 1`. They follow the same rules as `=`: the target must be a [mutable place](#mutability). The target is evaluated once.

**On a list item or dict key, a missing target is a fault.** Reading a [list](#indexing) or [dict](#dicts) gives an optional, but compound assignment does not make the statement optional: if the item or key exists, it is updated in place, and if not, it is a [fault](#faults), like an out-of-range write.

```
mut counts := { a = 0 }
counts.a += 1        # a is now 1
counts.zz += 1       # zz is missing: a fault

mut xs := [1, 2]
xs.(5) += 1          # out of range: a fault
```

```
mut i := 0
i += 1
p.x *= 2           # ok if p is mut and x is a mut field
```

Under the [statement rule](#statements), these operators can end a line and the statement continues on the next, like `=`.

### Mutability

Immutability is the default. **`mut` belongs to places, not to types.** A place is somewhere a value is held: a binding, a field, or an element. `mut` can appear in exactly two kinds of position:

- **Before a binding's or field's name**, making that place mutable: `mut x := ...`, `mut x: num` in a type.
- **After `ref`**, making a ref that can change what it shares: `ref mut T` (see [Sharing cannot add mutability](#sharing-cannot-add-mutability)).

Types carry no other `mut`: `mut vec3`, `mut [T]`, `[mut T]` and `mut` before a value are compile errors.

**A mutable place can change everything its value allows.** In a `mut` binding, the value can be replaced, and also changed in place: a vector's components, a list's elements and size, a dict's keys and values, and a composite's `mut` fields. In an immutable binding, nothing can change, all the way down.

```
x := 1
x = 2              # error: x is not mut

mut y := 1
y = 2              # ok

mut v := vec3(1, 2, 3)
v.x = 9            # ok: v is mut
v = vec3(0)        # ok

w := vec3(1, 2, 3)
w.x = 9            # error: w is not mut
```

**The mutable places** are:

- a `mut` binding or parameter, including a `mut` loop name over a plain copy
- a `mut` field of a value in a mutable place
- an element of a list, dict or array in a mutable place
- the value a `ref mut T` shares, including a `self: ref mut T` [method receiver](#functions-and-methods) and a [loop name](#items-and-indices) over a mutable collection

Since values are copied, a place's mutability is all that matters for an unshared value: nothing else can see it. Mutability only affects other code through sharing, which [`ref` and `ref mut`](#sharing-cannot-add-mutability) control.

#### Mutable fields

In a [composite](#composites) definition, `mut` before a field makes that field a mutable place, when the value holding it is in one. An unmarked field never changes, even in a `mut` binding, and nothing inside it changes either. A `mut` field allows everything a `mut` binding does: replacing it, and changing it in place.

```
Particle := type {
  id: num                 # never changes
  mut pos: vec2           # can change: p.pos = ..., p.pos.x = ...
}

mut p := Particle { ... }
p.pos.x = 1               # ok: p is mut, and pos is a mut field
p.pos = <0, 0>            # ok
p.id = 2                  # error: id is not a mut field

q := Particle { ... }
q.pos.x = 1               # error: q is not mut
```

**A change at a path needs every step to be mutable.** `a.b.c = v` needs `a` to be a mutable place, and `b` and `c` to be `mut` fields. The chain stops at [ref fields](#ref-composites): a ref field refers to a separate value, and what can change there is decided by the ref's own type.

Field mutability is checked only by the compiler. wgsl and js have no immutable fields, so the output is the same either way.

#### Compilation

| declaration | js | wgsl |
| --- | --- | --- |
| `x := v` | `const` | `let`, or `var` if it is shared with `ref` |
| `mut x := v` | `let` | `var` |

wgsl cannot take a pointer to a `let`, so an immutable binding that is shared with `ref` must compile to `var`.

## Copying and sharing

**The rule: everything is copied, unless `ref` says to share.** Binding, assigning and passing an argument all copy by default, and `ref` is the way to share instead. There are two deliberate exceptions, where the syntax itself marks the sharing:

- a [method's receiver](#functions-and-methods): an untyped `self` is `ref T`, so a dot call shares it
- a [`for` loop's item](#items-and-indices): an unannotated loop name is a `ref T`, or a `ref mut T` over a mutable collection, so each item is shared

In both, annotating the name with the plain type `T` opts out and copies instead.

### Values are copied

Binding a value to another name, assigning it, or passing it as an argument makes an independent copy. Changing a property of the copy never affects the original.

```
b := vec3(1, 2, 3)
mut a := b
a.x = 9            # b.x is still 1
```

On js, the compiler must copy any value that can change on either side, since js objects are otherwise shared. When a copy cannot be observed (for example, neither side is ever changed), the compiler may skip it.

### `ref` shares

`ref e` shares `e` instead of copying it. The result is a **ref**: another name for the same storage, so a change through one is visible through the other. `ref e` is read-only, and `ref mut e` can change what it shares (see [Sharing cannot add mutability](#sharing-cannot-add-mutability)).

- **If `e` is a place** (a binding, a field path such as `n.pos`, or an element such as `xs.(i)`), `ref e` shares that place itself. Nothing is copied.
- **If `e` is already a ref** (a ref binding, or a ref field such as `n.next`), `ref e` refers to the same storage that `e` currently refers to. Refs never nest: there is no ref to a ref. So `nxt := ref n.next` keeps referring to the node `n.next` pointed at, even if `n.next` is later repointed.
- **If `e` is a temporary** (a literal, or the result of a call or an operator), there is nothing to share yet, so `ref e` creates new shared storage holding it.

```
mut p := vec3(0)
q := ref mut p         # q is another name for p
q.x = 1                # p.x is now 1

n := ref mut Particle { ... }    # a temporary: new shared storage
pos := ref mut n.pos         # shares the pos field of n in place
pos.x = 1                    # n.pos.x is now 1 (pos is a mut field)

c := ref 10                  # new shared storage holding 10
```

**`ref` is part of the type.** A ref to a `T` has type `ref T`, or `ref mut T` if it can change what it shares, written the same way everywhere a type appears: in declarations, parameters and fields.

```
x : ref num = ref 10
f := fn (v: ref mut vec3) { ... }
Scene := type { root: ref Node }
```

**There are no hidden refs.** Every declaration or assignment that stores a ref must write `ref` in the value being stored. A type annotation alone is not enough.

```
x := ref 10            # x: ref num
y : ref num = ref 10   # the same, annotated
z : ref num = x        # error: write ref x
```

**Copying out of a ref is the default.** A plain binding, assignment or argument made from a ref copies the value it refers to, as for any value.

```
v := ref mut vec3(0)
mut w := v             # w is a plain copy of v's value
w.x = 9                # v is unchanged
```

### Sharing cannot add mutability

A ref says, in its type, what it can do with what it shares:

| ref | can |
| --- | --- |
| `ref T`, made with `ref e` | only read. It is a **read-only view**: nothing can be changed through it, though the value can still change through other names |
| `ref mut T`, made with `ref mut e` | read and change: everything a `mut` binding of the value could do, including writing a whole value with `x = value` |

**`ref mut e` needs `e` to be a [mutable place](#mutability)**, or a temporary (`ref mut 0` and `ref mut Node { ... }` make new storage that nothing else shares). So a ref never allows more than its source does. `ref e` can share anything. A `ref mut T` can be used where a `ref T` is expected, but never the reverse.

```
a := 0                 # not mut
b := ref mut a         # error: a is not mut, so a ref mut would add mutability
r := ref a             # ok: r is read-only

mut c := 0
d := ref mut c         # ok: c is mut
d = 7                  # c is now 7
```

**A ref binding is never `mut` itself.** A ref can never be [repointed](#assigning-through-a-ref), so there is nothing for a binding's `mut` to allow: `mut x := ref y` is a compile error. Whether a ref can write is part of its type, `ref mut`.

**So a function's parameters show what it can change.** A `ref T` parameter only reads the caller's value, without copying it, and a `ref mut T` parameter can change it:

```
draw := fn (e: ref Editor) { ... }       # reads the editor, never changes it
step := fn (e: ref mut Editor) { ... }   # can change it

mut ed := Editor { ... }
draw(ref ed)         # ok: a read-only view
step(ref mut ed)     # ok
frozen := Editor { ... }
step(ref mut frozen) # error: frozen is not mut
```

### What `=` does

`=` needs a mutable place. Whether the assignment reaches anything else depends only on whether the name is a ref:

| name | `x = value` does |
| --- | --- |
| `mut` plain binding | replaces the binding's own value. Nothing else is affected |
| `mut` plain parameter | replaces the function's local copy. The caller's value is never touched |
| `ref mut` binding or parameter | writes through to the shared storage. Everything sharing it sees the change |
| loop name over a mutable collection | writes through into the collection, since [loop names share](#items-and-indices) their item |

### Assigning through a ref

**A ref binding can never be repointed**, on the host or in shaders. Once a binding refers to some storage, it refers to that storage for its whole life. `x = ref y` is always a compile error.

On a `ref mut` binding, `x = value` writes `value` into the storage `x` refers to. Everything sharing it sees the change.

```
mut base := 0
x := ref mut base
x = 11                 # base is now 11
x = ref other          # error: a ref binding cannot be repointed
```

Since refs never repoint, a ref compiles directly to a wgsl pointer `let`, which also cannot be reassigned.

### Inherently ref types

A type declared with `ref`, such as a [ref composite](#ref-composites) or a [texture](#textures), is **inherently shared**: each instance is one shared thing, and it is never copied implicitly. So:

- Every binding of one needs `ref` in its value, like any ref.
- A plain binding, assignment or argument made from one is a compile error, instead of the usual copy.
- Copying one requires an explicit library function.

```
n := ref Node { value = 1 }     # a Node literal is a temporary: new shared storage
m := ref n                      # ok: m and n are one Node
k := n                          # error: Node is a ref type and cannot be copied implicitly
```

### `ref` parameters

A parameter is a ref when its type is `ref T` or `ref mut T`.

**Parameters are read-only unless they say otherwise.** A plain parameter is a copy, and `mut` lets the function change that local copy. A `ref mut` parameter can change the caller's value, following the [mutability rule](#sharing-cannot-add-mutability): the caller must pass a mutable place.

```
bump := fn (x: ref mut num) { x = x + 1 }    # writes through to the caller's storage
count := fn (mut n: num) { n = n - 1 }       # changes only the local copy
peek := fn (x: ref num) { x = 0 }            # error: x is a read-only ref
```

Passing arguments:

- **To a `ref` parameter**, a plain argument needs `ref` at the call site, which shares the caller's storage with the callee. **To a `ref mut` parameter**, it needs `ref mut`, so every call that can change an argument says so. An argument that is already a ref is passed as is (a `ref mut` can be passed to either kind).
- **To a plain parameter**, any argument is copied, including a ref. (An inherently ref type cannot be passed to a plain parameter, since it cannot be copied implicitly.)

```
mut n := 0
bump(ref mut n)    # n is now 1
bump(ref n)        # error: bump needs ref mut n
bump(n)            # error: write ref mut n to share it

r := ref mut n
bump(r)            # r is already a ref mut: n is now 2

show := fn (v: num) { ... }
show(r)            # copies the value r refers to
```

### Refs that outlive their source

A ref can outlive the scope of the binding it shares, for example when it is stored in a field or returned from a function.

- **On js**, this is always safe: any binding that is ever shared with `ref` is stored by the compiler in heap storage, so it lives as long as any ref to it. Vectors and composites are already js objects. A shared scalar costs one small heap object.
- **In shaders**, wgsl pointers cannot leave their function, so a ref cannot be returned or stored. (Ref fields are already host-only.)

### Refs in shaders

wgsl has no heap, so in shader code:

- **Inherently ref types are host-only**, with one exception: [textures](#textures). Using any other ref type in shader code is a compile error.
- **Refs to ordinary values are allowed.** `ref local` compiles to a wgsl pointer to that local, which becomes a `var`. A `ref` parameter compiles to a `ptr<function, T>` parameter, and writing through it compiles to `*x = value`. This lets a helper change its caller's variable.

```
bump := fn (v: ref mut vec3) { v.x = v.x + 1 }    # a component write through a ref mut
```

```wgsl
fn bump(v: ptr<function, vec3f>) { (*v).x = (*v).x + 1; }
```

## Operators

The operator set is deliberately minimal. Only arithmetic and comparison have symbols, and logic uses words. Everything else, such as remainder and powers, is a named function. There are no bitwise operations, since there are no integers.

| kind | operators |
| --- | --- |
| arithmetic | `+`, `-`, `*`, `/` |
| comparison | `is`, `is not`, `<`, `<=`, `>`, `>=` |
| logic | `and`, `or`, `not` |
| fallback | [`else`](#fallbacks-else) |

```
a + b * c
x is 0
mod(x, 2) is 0                 # remainder is a function, not %
if ready and not paused { ... }
```

Both operands of an arithmetic or comparison operator must have the same type: `1 + "a"` is a compile error.

**Division by zero is not a fault.** `/` is always float division, so `7 / 2` is `3.5`. On the host, dividing by zero gives an infinity or `NaN`, as in js. wgsl does not promise infinities or `NaN` at runtime, so in a shader the result of dividing by zero is unspecified. Code that may divide by zero should check first.

**Precedence**, from tightest to loosest. All binary operators are left-associative.

| level | operators |
| --- | --- |
| 1 | `.` (field access), calls, and postfix [`!` and `?`](#passing-errors-up-with-) |
| 2 | unary `-` |
| 3 | [`else`](#fallbacks-else) (fallback) |
| 4 | `*`, `/` |
| 5 | `+`, `-` |
| 6 | `is`, `is not`, `<`, `<=`, `>`, `>=` |
| 7 | `not` |
| 8 | `and` |
| 9 | `or` |

Comparisons cannot be chained: `a < b < c` is a compile error, since it rarely means what it looks like.

```
a + b * c          # a + (b * c)
not a is b         # not (a is b)
a and b or c       # (a and b) or c
a < b < c          # error: comparisons cannot be chained
```

**Equality is `is` and `is not`.** There is no `==` or `!=`. This avoids the common mistake of writing `=` (assignment) where `==` was meant. `==` and `!=` are not tokens of the language, and the compiler should suggest `is` or `is not` when it sees them.

`is not` is a single two-word operator. `a is not b` always means "a is not equal to b", never `a is (not b)`. To compare with a negated value, use parentheses: `a is (not b)`.

```
if x is 0 { ... }
if name is not "" { ... }
if a == b { ... }        # error: use is
```

`is` compares whole values and always evaluates to a single `bool`. For vectors, matrices and fixed arrays, `a is b` is true when every component is equal. For composites, it is true when every field is equal. A component-wise comparison, wgsl's `==` on vectors, is a named function. (There are no bool vectors, so what it returns is an [open question](#types).)

```
if pos is target { ... }     # true only if all components are equal
if p is q { ... }            # composites: all fields equal
```

In wgsl, `a is b` on vectors compiles to `all(a == b)`, and on composites to a field-by-field comparison.

`is` compares contents for refs too, so it means "equal value" whatever the bindings are. Whether two refs share the same underlying value (identity) is checked with a separate function, so the two questions cannot be confused.

```
a := ref Point { x = 1, y = 2 }
b := ref Point { x = 1, y = 2 }
c := ref a
a is b             # true: equal contents
a is c             # true
```

`and` and `or` short-circuit: the right operand is evaluated only if it is needed. Their operands follow the [truthiness](#truthiness) rules, and they evaluate to a `bool`. `not` takes one operand by the same rules and evaluates to a `bool`.

## Control flow

### `if`

`if` is a statement, not an expression: it has no value and cannot be used on the right of `=` or `:=`. To choose between values, assign in each branch.

```
mut y := 0
if c { y = 1 } else { y = 2 }

w := if c { 1 } else { 2 }    # error: if is not an expression
```

The condition is written without parentheses, and every branch is a braced block, as in Go and Rust. Braces are required even for a single statement. Further conditions are chained with `elif` or `else if`, which mean exactly the same thing and can be mixed in one chain.

```
if x > 0 {
  y = 1
} elif x < 0 {
  y = -1
} else {
  y = 0
}

if x > 0 {
  y = 1
} else if x < 0 {      # the same chain, spelled with else if
  y = -1
}

if x > 0 y = 1     # error: the branch must be a block
```

`else` and `elif` may start a new line. This is an exception to the [statement rule](#statements): after an `if` or `elif` branch's closing `}`, the parser skips any newlines and checks whether the next token is `else` or `elif`. This is unambiguous because neither can start a statement. (Go requires `} else` on one line only because its lexer inserts statement ends without knowing the grammar. This language does not have that limitation.)

```
if x > 0 {
  y = 1
}
else {
  y = 0
}                  # one if statement, same as `} else {`
```

### Literals in conditions

In the condition of `if`, `elif` and `for`, and in the collection of `for ... in`, a `{` after the condition always starts the block. So a composite literal (`Name { ... }`), anonymous composite or dict literal there must be in parentheses. This is the same rule as Go's. Array, list and vector literals are not affected, since they do not use braces.

```
if ready { ... }                              # always a block
if p is (Point { x = 0, y = 0 }) { ... }      # a composite literal needs parentheses
for v in ({ a = 1, b = 2 }) { ... }           # so does a dict literal
for x in [1, 2, 3] { ... }                    # brackets are fine
```

### Truthiness

A condition (in `if`, `elif` and `for cond` loops, and the operands of `and`, `or` and `not`) can be of any type, not only `bool`. Each type defines which of its values are falsy, and every other value is truthy.

```
if n { ... }        # n is a num: same as n is not 0
```

Since types are static, the compiler knows the condition's type and emits that type's test explicitly:

- **wgsl** requires a `bool` condition, so a non-`bool` condition compiles to a comparison, e.g. `if (n != 0)`.
- **js** must not rely on js's own truthiness, which differs for objects (an object, such as a vector, is always truthy in js). The compiler emits the type's test there too, so both backends agree.

### Loops

`for` is the only loop keyword, as in Go. It has three shapes, and the body is always a braced block:

| shape | meaning |
| --- | --- |
| `for cond { ... }` | runs while `cond` is truthy, checked before each iteration |
| `for x in xs { ... }` | runs once for each item of `xs`, binding it to `x` |
| `for { ... }` | runs forever, until `break` or `return` |

```
mut i := 0
for i < 10 { i = i + 1 }

for x in xs { draw(x) }

for {
  if done { break }
}
```

The condition follows the same [truthiness](#truthiness) rules as `if`.

#### `break` and `continue`

`break` exits the innermost enclosing loop. `continue` skips to its next iteration. Neither can target an outer loop, and there are no loop labels, as in wgsl. To leave several loops at once, use a flag variable or `return`. Using either outside a loop is a compile error.

```
for y in h {
  for x in w {
    if hit(x, y) { break }   # exits the inner loop only
  }
}
```

#### Items and indices

`for x in xs` binds each item. A second name after a comma binds the item's index, or its key for a [dict](#dicts). The item always comes first, so the one-name form is simply the item.

```
for x in xs { }        # each item
for x, i in xs { }     # each item and its index
for v, k in d { }      # for a dict: each value and its key
```

**A `for` loop shares each item automatically.** The loop name refers to the item itself, not a copy, so changes through it go back into the collection. No `ref` is written. Like a method's receiver, this is one of the two places where an unannotated name is automatically upgraded to a `ref` type, a deliberate exception to the [no hidden refs](#ref-shares) rule. The loop itself marks the sharing.

Changes follow the [mutability rule](#sharing-cannot-add-mutability): over a collection in a [mutable place](#mutability), the loop name is a `ref mut T`, so the body can change each item, or replace it with `x = value`. Over any other collection, it is a read-only `ref T`.

**The loop name's type decides sharing.** An unannotated loop name has type `ref T` or `ref mut T`, where `T` is the item type. Annotating it with the plain type, `for x: T in xs`, opts out: each item is copied, and changes through `x` never reach the collection. A copied loop name can be `mut` (`for mut x: T in xs`) to change the copy.

```
for p in particles { p.pos = <0, 0> }      # particles is mut: p: ref mut Particle, resets every pos in place
for mut p: Particle in particles { p.pos = <0, 0> }   # p is a mutable copy: particles is unchanged
for p: ref mut Particle in particles { ... }   # the same as the first line, written out
for n in nodes { ... }                     # items of a ref type are shared, as always
for n: Node in nodes { ... }               # error: Node is a ref type and cannot be copied implicitly
```

With an index, the annotation goes on the item name: `for p: Particle, i in particles`.

**An index is a `num`**, like [`len`](#indexing). (A dict's key is a `str`.)

**Replacing an item.** Over a mutable collection, `x = value` writes a whole item into the collection, as on any `ref mut`. No `mut` is written on the loop name, since a ref binding is [never `mut`](#sharing-cannot-add-mutability).

```
for p in particles {
  p = Particle { ... }               # replaces the item in particles
}
```

Range loops have nothing to share: each counter value is a fresh value. A `mut` counter (`for mut i in 10`) only reassigns the local counter.

In wgsl, the loop name over an array compiles to a pointer to the current element, e.g. `&arr[i]`.

#### Counting

Range literals make counting loops. `..` excludes the end and `..=` includes it. Either end can be left out, and a single number can also be iterated.

| form | meaning |
| --- | --- |
| `a..b` | from `a` up to, but not including, `b` |
| `a..=b` | from `a` up to and including `b` |
| `..b`, `..=b` | a missing start is `0`: the same as `0..b` and `0..=b` |
| `a..` | a missing end: counts up from `a` without end, until `break` or `return` |
| `n` | a single number is a count: the same as `0..n` |

```
for i in 0..10 { }      # 0 to 9
for i in ..10 { }       # 0 to 9
for i in 10 { }         # 0 to 9
for i in 0..=10 { }     # 0 to 10
for i in ..=10 { }      # 0 to 10
for i in 5.. { }        # 5, 6, 7, ... until break
```

A `by` clause after a range sets the step. Without one, the step is `1`.

- **The step is never inferred.** A range counts down only when its step is negative. A step that points away from the end gives zero iterations, so `10..0` with no step runs zero times.
- `..` still excludes the end and `..=` still includes it, in either direction.
- A step of `0` is a compile error when it is a constant. A zero step held in a variable gives zero iterations (see [Faults](#faults)).

```
for i in 0..10 by 2 { }     # 0 2 4 6 8
for i in 10..0 by -1 { }    # 10 down to 1
for i in 10..=0 by -1 { }   # 10 down to 0
for i in 10..0 { }          # zero iterations: the step is 1
```

**Ranges count in whole numbers.** The counter is a `num`, but the start, end and step are each truncated toward zero first, as an [index](#indexing) is. So a counter is always a whole number, and can be used as an index as it is. A step that truncates to `0` is a zero step, under the rule above: a compile error when it is a constant, and zero iterations when it is held in a variable.

```
for i in 10 { }             # i: 0, 1, ... 9
for i in half { }           # half is 2.5: 0, 1 (the end is truncated to 2)
for i in 0..10 by 2.5 { }   # 0 2 4 6 8: the step is truncated to 2
for t in 0..1 by 0.5 { }    # error: the constant step truncates to 0
```

For fractional steps, scale a whole-number counter: `for k in 5 { t := k / 4 }` gives `t` as 0, 0.25, 0.5, 0.75 and 1.

In wgsl, the compiler can count with an `i32` and convert the counter where it is used.

## Functions

Functions are values. Outside composites, a function is named by binding it with the ordinary [declaration](#declaration) syntax; there is no separate named-function statement. (Functions inside a composite are written by name, without a binding: see [Functions and methods](#functions-and-methods).)

There are two kinds of function declaration:

1. **Standard function**: one function with one signature.
2. **Function namespace**: an overload set.

### Calls

Calls are C-style, and the parentheses are always required: the function, then `(`, then the arguments separated by commas, then `)`. A call with no arguments is written `f()`. A bare name without parentheses is never a call: it is the function value itself, which is how functions are passed around.

```
y := add(1, 2)
p.move(1, 0)
img := load(path)!
now()                     # a call with no arguments
on render draw_frame      # draw_frame is passed as a value, not called
```

Calls compile one-to-one to js and wgsl calls (after [overload resolution](#resolution) picks the function).

### Parameters

Every parameter must have a type, written `name: Type`. This applies to both kinds of function, and to functions inside composites. There are no generic or inferred parameter types. The one exception is the first parameter of a composite function (see [Untyped receivers](#functions-and-methods)).

```
add := fn (a: num, b: num): num { return a + b }
bad := fn (a, b) { return a + b }    # error: a and b need types
```

#### Variadic parameters

A final parameter written `...name: [T]` collects all remaining arguments into a [list](#arrays-and-lists) `[T]`. Every collected argument must be a `T`. Only the last parameter can be variadic, and it can receive zero arguments. Variadic functions are host-only for now, since wgsl has none.

```
cat := fn (...parts: [str]): str { ... }
cat("a", "b", "c")          # parts has 3 items
cat()                       # parts is empty

log := fn (level: str, ...parts: [str]) { ... }
log("info", "loaded", name)
```

### Standard functions

`fn`, then a parameter list, then an optional return type, then a body block. The return type follows `:` after the parameter list, as in TypeScript, so `:` always introduces a type.

```
add := fn (a: num, b: num): num {
  return a + b
}
```

#### Returning

A function returns a value only through `return value`. The last expression in a body is not returned implicitly. `return` with no value exits a function that returns nothing.

```
sq := fn (x: num): num { return x * x }
bad := fn (x: num): num { x * x }        # error: no return
```

A function with a return type must return a value on every path. A path that can reach the end of the body without returning is a compile error, as in wgsl.

#### Inferred return types

The return type can be left out, and is then inferred from the body:

- With no `return value` statements, the function returns nothing.
- Otherwise, every `return value` must have the same type, and that type is the return type. Returns of different types are a compile error.

```
hi := fn () { print("Hello") }          # returns nothing
sq := fn (x: num) { return x * x }      # returns num
```

When a return type is written, every `return` must match it.

### Function namespaces (overload sets)

`fn { ... }` creates a function namespace: one function value holding several overloads. Each overload is a parameter list followed by a body block.

```
greet := fn {
  () { print("Hello") }
  (name: str) { print($"Hello {name}") }
}
```

(`$"..."` is an [interpolated string](#strings).)

#### Resolution

Overloads are distinguished by parameter count and parameter types. The compiler resolves every call at compile time:

- If exactly one overload matches the arguments' count and types, the call uses it.
- If none matches, or more than one does, it is a compile error.
- Two overloads in one namespace with the same parameter count and types are a compile error.

Each overload compiles to its own separately named function in js and in wgsl (wgsl has no user-defined overloads). The call site calls that function directly, so there is no runtime dispatch.

```
greet()          # compiles to a call to greet's first overload
greet("Ana")     # compiles to a call to greet's second overload
greet(1)         # compile error: no overload of greet takes a number
```

This relies on the language being statically typed everywhere, so every argument's type is known at compile time.

## Shaders

A shader is a GPU entry point, declared with `sh`. It is written like a [standard function](#standard-functions): `sh`, a parameter list, an optional return type, and a body. It is named by binding it with the ordinary declaration syntax.

For now, every shader is a **per-pixel (fragment) shader**: it runs once for each pixel of a target surface, and its return value is the color written to that pixel. The compiler supplies a fixed full-screen vertex stage, which users never write. Vertex and compute shaders may be added later.

### The context parameter

A shader's first parameter is always its **context**. The context holds the target the shader draws to, the previous image (`before`), the frame's timing and the current pixel's position. There are no hidden built-in names: everything comes through the context.

```
tint := sh (ctx: Context, src: ref tex2d, color: vec4): vec4 {
  return sample(src, ctx.uv) * color
}

grad := sh (ctx: Context): vec4 {
  return vec4(ctx.uv.x, ctx.uv.y, 0, 1)
}
```

(The names `Context` and `tex2d`, and the `sample` built-in, are illustrative. Textures are refs: see [Textures](#textures).)

| field | type | meaning |
| --- | --- | --- |
| `target` | `ref tex2d` | the surface the shader draws to. Host-only: it cannot be read in shader code |
| `before` | `ref tex2d` | the image from before this pass: the previous pass's output, or the last frame's (see below). Readable in shader code |
| `t` | `num` | time, in seconds |
| `dt` | `num` | time since the previous frame, in seconds |
| `wh` | `vec2` | the target's width and height, in pixels |
| `xy` | `vec2` | the current pixel's center on the target, in pixels: `(0.5, 0.5)` for the top-left pixel |
| `uv` | `vec2` | the same position normalized by the target's size: exactly `xy / wh` |

`(0, 0)` is the target's top-left corner, and y grows downward, as in WebGPU. `xy` is what wgsl's `@builtin(position)` gives. Since `xy`, `uv` and `wh` are all `vec2`, they combine without conversions. All context fields are immutable.

**The target is not visible inside a shader.** A shader writes to its target only through its return value, so `ctx.target` is not useful there, and reading it in shader code is a compile error. What a shader can read is `ctx.before`.

`Context` is a built-in type, not an ordinary composite. Its `target` field would otherwise make it host-only (see [GPU compatibility](#gpu-compatibility)), but since `target` is not visible in shader code, a context can be passed to shaders.

```
fade := sh (ctx: Context): vec4 {
  return sample(ctx.before, ctx.uv) * 0.95    # reads the previous image
}
bad := sh (ctx: Context): vec4 {
  return sample(ctx.target, ctx.uv)           # error: target is not visible in shader code
}
```

### Running a shader

Host code runs a shader by calling it like a function, passing a context first. The context is usually provided by an engine callback (such as a per-frame hook), but host code can also construct one, for example to draw into an offscreen surface. The GPU work is asynchronous, but this is hidden from the program.

```
tint(ctx, photo, vec4(1, 0.5, 0.5, 1))
```

A context built by host code must give every frame field: `target`, `t` and `dt`. `target` is a texture ref, so it is set with `ref`, like any [ref field](#ref-composites). There is no hidden clock. `wh` comes from the target, `before` is maintained by the engine for each target, and `xy` and `uv` cannot be set, since they are filled in on the GPU for each pixel.

```
off := Context { target = ref scratch, t = now(), dt = 0.016 }    # now() is illustrative
bad := Context { target = ref scratch }                                # error: t and dt are required
bad2 := Context { target = ref scratch, t = 0, dt = 0, uv = vec2(0) }  # error: uv is per pixel
```

The call draws into `ctx.target` and evaluates to the context it was given. So passes chain by passing the context along: each shader in a chain draws into the same target, in order.

```
vignette(tint(ctx, photo, c))     # tint draws into ctx.target, then vignette draws into it too
```

**`before` connects the passes.** In each pass, `ctx.before` is the image as it was before that pass: for the second shader in a chain, it is what the first one drew. For the first pass of a frame, it is the last frame's final image. So a chain of effects can each build on the previous one, and feedback effects (trails, blur over time) can read the last frame.

WebGPU cannot read and write one texture in the same pass. Because a shader can only read `before` and only write its target, the engine can keep the two as separate textures and swap them between passes. Users never see this.

### Textures

Textures (images, and surfaces that shaders draw to) are a built-in **ref type**. They live on the GPU and are always shared, never copied. Following the [no hidden refs](#ref-shares) rule, every binding of one needs `ref` in its value, and they are passed as `ref` parameters.

Textures are the one ref type allowed in shader code: a shader can take them as `ref` parameters and read from them.

```
photo := ref load_image("photo.png")
scratch := ref tex2d(512, 512)

tint := sh (ctx: Context, src: ref tex2d, c: vec4): vec4 {
  return sample(src, ctx.uv) * c
}
```

(The names `tex2d`, `load_image` and `sample` are illustrative.)

### Shader rules

A shader's body compiles to wgsl, so it must follow the rules already given for shader code:

- No host-only types: `str`, `any`, dicts `{T}`, optional refs `ref? T`, ref composites, and composites that are not [GPU compatible](#gpu-compatibility).
- [Optionals](#optional-types-t) of GPU-compatible plain types are allowed, and compile to the value plus a `bool` flag. `nil`, `is nil`, narrowing and `?` work as on the host. So a list read in a shader gives a `T?`, as on the host.
- [Results](#errors) are host-only for now, since an `Error` holds a `str`.
- No [variadic](#variadic-parameters) functions.
- Refs only as described under [Refs in shaders](#refs-in-shaders).
- No recursion, since wgsl forbids it.

Ordinary functions called from a shader are compiled to wgsl as well, and must follow the same rules. The same function can still be called from host code.

### Top-level bindings in shaders

A shader can use a script's top-level bindings directly, without taking them as parameters, as long as they are GPU compatible:

- **Functions** that follow the shader rules can be called. They compile to wgsl helper functions.
- **Immutable values** of a compatible type compile to wgsl `const`s.
- **`mut` values** of a compatible type become uniforms. They are read each time the shader runs, so a later change on the host is seen by the next call.
- Using any other top-level binding in a shader is a compile error.

```
UP := vec3(0, 1, 0)                     # becomes a wgsl const
mut strength : num = 0.5                # becomes a uniform, read on every call
lum := fn (c: vec4) { return c.r * 0.3 + c.g * 0.59 + c.b * 0.11 }

fx := sh (ctx: Context, src: ref tex2d): vec4 {
  c := sample(src, ctx.uv)
  return mix(c, vec4(lum(c)), strength)
}
```

### The `gpu` tag

GPU compatibility is always inferred, but a function or composite can carry the optional `gpu` tag to assert it. A tagged definition that is not compatible is a compile error at the definition, instead of at some shader that later uses it. The tag never changes what the code means.

```
lum := gpu fn (c: vec4) { ... }     # checked against the shader rules here
Light := gpu type {
  pos: vec3
  name: str                              # error: str is host-only, but Light is tagged gpu
}
```

## Modules

`import` loads another file and evaluates to its module, which is bound to a name with the ordinary declaration syntax. The module's top-level names are then reached through that name.

```
math := import "lib/math.qs"
v := math.lerp(a, b, 0.5)
```

- The path must be a string literal, so the compiler can find every file ahead of time.
- It is resolved relative to the importing file.
- An import cycle (`a` imports `b`, which imports `a`) is a compile error.
- A module is evaluated once and shared: every importer gets the same module, and its top-level code runs only the first time it is needed. It runs again only when the module is [reloaded](#reloading-a-module), or when the [scene changes](#scenes), which discards and reloads every module.

(The `.qs` extension is a placeholder, since the language's name and file extension are not decided.)

**Exports.** Every top-level name in a module is visible to importers, except names starting with `_`, which are private to their file. There is no export keyword or list.

```
# math.qs
lerp := fn (a: num, b: num, t: num) { return a + (b - a) * t }   # exported
_scale := 2                                                      # private

# main.qs
math := import "lib/math.qs"
math.lerp(0, 10, 0.5)      # ok
math._scale                # error: _scale is private to math.qs
```

**Module state is read-only from outside.** A module's own code can change its `mut` top-level values, but to importers they are immutable places: importers can read them, but not assign them, change their fields, or call a method with a `self: ref mut T` receiver on them. To let other files change a value, the module exports a function that does it. Each module's state stays under its own control.

```
# math.qs
mut scale := 1
set_scale := fn (s: num) { scale = s }

# main.qs
math.scale              # ok: reads the current value
math.scale = 2          # error: only math.qs can assign scale
math.set_scale(2)       # ok
```

## Engine hooks

The engine reports events, such as each displayed frame, through hooks. `on` registers a handler for a hook: `on`, the hook's name, then a function. `on` is only allowed at a file's top level, so that a module's handlers can be replaced when it [reloads](#hooks-across-reloads).

```
on render fn (ctx: Context) {
  vignette(tint(ctx, photo, c))
}

draw_frame := fn (ctx: Context) { ... }
on render draw_frame              # a named function works too
```

The `render` hook's handler receives the frame's [context](#the-context-parameter), which is where shader contexts usually come from.

| hook | runs | handler receives |
| --- | --- | --- |
| `ready` | each time its [scene](#scenes) becomes current, including at startup | the arguments passed by the scene switch: [any parameter list](#scene-arguments) |
| `update` | at a fixed time step | `dt: num`, the fixed step in seconds |
| `render` | once per displayed frame | `ctx: Context`, the frame's context |
| `keydown`, `keyup` | when a key is pressed or released | a key event composite |
| `pointerdown`, `pointerup`, `pointermove` | on pointer input | a pointer event composite |
| `resize` | when the render target changes size | `size: vec2`, the new size in pixels |

```
on ready fn () { ... }
on update fn (dt: num) { ... }
on render fn (ctx: Context) { ... }
on keydown fn (e: Key) { ... }
on pointermove fn (e: Pointer) { ... }
on resize fn (size: vec2) { ... }
```

(`Key` and `Pointer` are illustrative names for the event composites.)

### Scenes

Every script is a module, and any module can contain `on` handlers. But **the engine only attaches the hooks of the current scene**, which is one module. Importing a module never attaches its hooks: they stay inactive unless that module becomes the current scene.

So a library does not react to events by being imported. Instead it exposes functions, and the scene calls them from its own handlers.

```
# ui.qs: a library
draw := fn (ctx: Context) { ... }
on render fn (ctx: Context) { ... }     # inactive unless ui.qs is the current scene

# editor.qs: the current scene
ui := import "ui.qs"
on render fn (ctx: Context) {
  ui.draw(ctx)                          # the scene decides what runs, and in what order
}
```

This keeps all of a program's event wiring in one place: reading the current scene's handlers shows everything that runs on each event.

**Choosing and switching scenes.** The engine is started with an entry scene. From then on, any module can switch the current scene through the engine's API. The new scene's module does not need to be imported first. In both cases, a scene is given in one of two forms:

- **a path**, a string saying where to load the script from
- **source text**, a string holding the script itself, which is compiled and run as the scene

```
on keydown fn (e: Key) {
  if e.key is "enter" {
    _ := engine.scene("levels/one.qs")  # by path; engine.scene is illustrative
  }
}

_ := engine.scene_source(text)   # the script's own text, e.g. generated or sent by the editor
```

The two forms are **separate functions**, one taking a path and one taking source text. Both arguments are `str`, so [overload resolution](#resolution) could not tell them apart, and a separate name makes every call say which it means.

Source text lets a scene come from somewhere other than a file, such as code the editor sends to the program's [engine instance](#the-editor-and-the-program).

**Switching discards everything.** When the scene changes, every loaded module is discarded, with all of its values, including [kept](#kept-state) `@` values (which only survive reloads). The new scene starts as if the program had just started. A switch happens in two parts:

1. **The switch call loads and checks the new scene.** The new scene's module, and every module it imports, is loaded fresh, and its top-level code runs. (Shared modules get fresh copies: the old scene's copies are still loaded.) Then its `ready` handler's parameters are checked against the call's arguments. If either step fails, the call returns an error, and nothing else happens (see [A failed switch](#a-failed-switch)).
2. **After the current hook returns, the swap happens.** The old scene and all of its modules are discarded, the new scene's hooks are attached, and its `ready` handler runs.

So the handler that called the switch finishes in the old scene, and a handler never runs partly in one scene and partly in another. This matches [reloads](#failed-reloads), which also swap code only between hook calls.

```
on keydown fn (e: Key) {
  _ := engine.scene("levels/one.qs") # loaded and checked now
  print("still in the old scene")    # runs
}
# the swap happens here: levels/one.qs's ready runs before the next hook call
```

So switching to a scene always gives it a completely fresh start. State moves from one scene to the next in only two ways:

- **Arguments handed to the new scene.** The switch call can pass any arguments after the scene, and the new scene's `ready` handler receives them as its parameters (see [Scene arguments](#scene-arguments)).
- **The persistence API.** Scenes can read and write persisted data through the engine, which survives scene changes (and presumably restarts).

```
# game.qs
on keydown fn (e: Key) {
  if lives is 0 {
    engine.save("best", str(score))                          # persistence; names illustrative
    r := engine.scene("menu.qs", score, false)               # hand arguments to the next scene
    if r is err { print("menu is broken") }
  }
}

# menu.qs
on ready fn (score: num, won: bool) {
  show_score(score)                                          # the arguments from the switch
  best := engine.load("best")                                # read persisted data
}
```

`ready` therefore means "this scene is now current", not "the program started". It runs each time the program switches to that scene, including at startup.

#### Scene arguments

A scene's `ready` handler can have **any parameter list**, like an ordinary function, including a final variadic parameter such as `...args: [any]`. The switch call passes its arguments after the scene, and they become `ready`'s arguments. So the switch function itself takes a variadic `...args: [any]` after the path.

Because a scene is named by a runtime string, the compiler cannot match the arguments to the new scene's `ready` when it compiles the switch. Instead, **the switch call checks them at runtime**, once it has loaded the new scene: the argument count and types must match `ready`'s parameters, by the same rules as an ordinary call.

```
# level.qs
on ready fn (n: num, hard: bool) { ... }

# menu.qs
_ := engine.scene("level.qs", 3, true)    # ok: matches (num, bool)
r := engine.scene("level.qs", 3)          # r is an error: ready needs 2 arguments

# log.qs: a scene that accepts anything
on ready fn (...args: [any]) { ... }
```

#### A failed switch

A switch can fail: the new scene may not load or compile, or its `ready` may not accept the arguments. Because the switch call loads and checks the new scene **before** anything is discarded, a failure is safe:

- The old scene stays current, with all of its state intact.
- **The switch call returns a [result](#errors)**, an error on failure. Like any result, it [cannot be ignored](#errors): it is checked with `is err`, passed up with `!`, or explicitly discarded with `_ :=`.

```
r := engine.scene("levle.qs")        # a typo in the path
if r is err {
  print($"could not switch: {r.message}")
}
# still in the old scene
```

## Live reload

The language supports a live editor that is itself written in the language. Saving a file, including one of the editor's own files, updates the running program in place, without restarting it. This section gives the rules that make that possible.

### Reloading a module

When a file is saved, the compiler, which runs in the browser, recompiles it. Compilation is per module and incremental:

- Only the changed module is recompiled.
- Its importers are type-checked again only if its exported names or types changed.

The module is then reloaded: the new code replaces the old, and its top-level code runs again. Every top-level binding is computed again, except [kept](#kept-state) `@` names.

Importers that did not change are not run again. They reach the module's names through the module binding (`math.lerp`), so they see the new versions. A copy an importer made earlier, such as `x := math.scale` at its top level, keeps its old value, as copies always do.

### Kept state

A top-level name that starts with `@` is **kept**: its value survives reloads. Its value is computed on the module's first load, and on every later reload the binding keeps the value it had. Every other top-level binding, `mut` or not, is computed again on every reload. (A [scene change](#scenes) discards kept values too.)

`@` is part of the name, like the `_` that makes a name [private](#modules), so it is written at every use, not only where the name is declared. Wherever kept state is read or changed, the code shows it: `@cursor = 5` survives a save, and `cursor = 5` does not.

```
@photo := ref load_image("photo.png")   # loaded on the first load only
@seed := random()                       # the same seed across every reload
mut @doc := Document { ... }            # kept and assignable
mut @cursor := 0
mut layout_cache : {Layout} = {}        # not kept: rebuilt on every reload, so never stale

on keydown fn (e: Key) {
  @cursor += 1                          # visibly kept state
}
```

- **Keeping and mutability are independent.** `mut @x` is kept and assignable. A kept name without `mut` is still useful: its value is computed once and never again, which suits expensive or nondeterministic values such as loaded assets, random seeds and start times.
- **Ordinary top-level `mut` values are not kept.** They are recomputed on every reload, which suits state derived from code, such as caches, since it can never outlive the code that built it.
- **Only top-level bindings can be kept.** An `@` name for a local, a parameter or a field is a compile error.
- It uses the ordinary declaration forms: `@x := v`, `@x : T = v`, and the same with `mut`.
- Like all module state, a kept value is [read-only from outside](#modules) its module. An importer writes `math.@scale`.
- A kept value is identified by its module's path and its own name. Renaming the binding, or moving its file, starts it fresh.

**Changing a declaration resets it.** A kept binding is computed again, as on a first load, when its own declaration changes: its value expression, or its written type. Edits anywhere else leave it kept. So editing a starting value takes effect at once, and unrelated edits never lose state.

A change is judged by the declaration's **tokens**: its name, `mut`, written type and value expression. Whitespace, comments, and moving the declaration to another place in the file are not changes, so reformatting a file never loses state. Only the declaration itself is compared, not the names its value uses: `mut @zoom := DEFAULT` stays kept when `DEFAULT`'s value is edited (unless its type changes, below).

```
mut @cursor := 0     # the program later sets @cursor to 12
# edit some other function, save: @cursor is still 12
# edit this line to  mut @cursor := 3,  save: @cursor is reset to 3
```

On js, kept values are stored outside the module's compiled code, so they survive the code being replaced.

### When a kept value's type changes

If a composite's definition changes between reloads, kept values of that type still have the old shape. They are migrated to the new definition field by field, matched by name:

| change | result |
| --- | --- |
| field unchanged | keeps its value |
| field removed | dropped |
| field added, with a default | gets its default |
| field added without a default, or a field's type changed | the value cannot be migrated: its binding is reset (below) |

**A value that cannot be migrated resets its binding.** If any value inside a kept binding cannot be migrated, that whole binding is reset: its value is computed again from its source, as on a first load. The reload still succeeds, and every other kept value survives. So a reload never gets stuck on old state, at the cost of that one binding's contents. To keep a value across such a change, give the new field a default.

**A change to a binding's own type also resets it**, by the same rule, even when its declaration's text did not change. Nothing is converted.

```
ZOOM := 1              # edited to ZOOM := <1, 1>
mut @zoom := ZOOM      # @zoom's declaration is unchanged, but its type goes from num to vec2: reset to <1, 1>
```

Migration applies wherever a value sits inside kept state: in fields, lists, dicts and `any`s. A composite type keeps its identity across reloads by its module's path and its name, so `x is Document` on a kept `any` still matches after `Document` is reloaded.

Kept state can hold [ref composites](#ref-composites), which cannot be copied. They are migrated in place, so sharing survives: if two kept bindings shared one node before a reload, they still share it after.

Migration needs each value's fields and types at runtime, so the js output carries type metadata, at least in development builds.

### Function values across reloads

A function value that names a top-level function is **late-bound**: calling it always runs the newest version of that function. So a callback stored in kept state does not keep running old code.

```
mut @tools := [pen, eraser]     # pen and eraser are top-level functions
tool := @tools.0                # a list read is optional
if tool is not nil {
  tool()                        # after a reload that edits pen, this runs the new pen
}
```

A function literal written inside other code has no top-level name, and so no stable identity. How it behaves in kept state is not decided.

### Hooks across reloads

Handlers belong to the module that registered them, and only the [current scene's](#scenes) handlers are attached. When the scene's module reloads, its old handlers are removed and its top-level code registers them again, so a save never adds a second `render` handler. This is why `on` is only allowed at a file's top level.

When any other module reloads, the scene's handlers stay attached. They reach that module's functions through its module binding (`ui.draw`), so they call the new versions.

### The editor and the program

The live editor and the program it edits run **in separate engine instances**, for example in separate browser frames or workers. Each instance has its own current [scene](#scenes), hooks, kept state and GPU resources. They talk only by sending messages over a channel, and share no state or textures directly.

```
[ editor engine ]   <-- messages -->   [ program engine ]
  editor scene                           program's current scene
```

This isolates the two. A program that hangs or fails cannot freeze or break the editor, and the program sees exactly the engine it would see when it runs alone.

The same live reload rules apply in both instances. When the editor saves one of the program's files, the program's instance reloads it. When the editor saves one of its own files, the editor's own instance reloads, and the [default editor](#the-fixed-core) is the fallback if that fails.

### Failed reloads

A broken save must never take down the running program, since the program may be the editor being used to fix it. A reload is all or nothing:

- **Compile errors.** If the changed module, or any importer checked again, fails to compile, nothing is replaced. The old version keeps running, and the errors are reported.
- **Timing.** The swap happens between hook calls, never while a hook is running.
- **Runtime failures.** Code can fail at runtime in three ways: a [fault](#faults), an infinite loop, or a js stack overflow from deep recursion. The runtime catches all three at hook boundaries. In development builds, the compiler inserts a loop budget, so an infinite loop is caught instead of freezing the page.

What happens after a runtime failure depends on when it happens:

| failure | result |
| --- | --- |
| during the transition: in the new top-level code, or in the first full frame after the swap | **rollback**: the old code is restored, and kept state is restored to what it was just before the swap, which also undoes any migration |
| a later fault | the hook call is stopped and reported, and the program keeps running, as for any [fault](#faults) |
| a later infinite loop or stack overflow | **no automatic recovery**: when running in the editor, the editor offers to open the [default editor](#the-fixed-core) |

**The transition ends after the first full frame.** That is one displayed frame after the swap: the `update` steps that run before it, any input hooks that fire in it, and then its `render`. A fixed-step loop already groups `update` steps by frame this way, so this joins the two clocks without a separate rule for each.

```
swap                   # new top-level code runs
  update, update       # this frame's fixed steps
  keydown              # input in this frame
  render               # the transition ends when this returns
next frame             # a hang from here on offers the default editor (in the editor)
```

Automatic recovery is limited to the transition because only then is the old state still meaningful. Once the new code has run for a while, kept state has moved on in ways the old code cannot be trusted with, so the only safe step is to hand control to an editor that does not depend on the failed code.

**Live reload is an editor feature.** Everything in this section applies to a program running inside the editor. An **exported application** runs without an editor: it has no live reload and never opens the default editor, even when it hangs or fails.

### The fixed core

The code that compiles and swaps modules is not itself live-reloaded, so a bad save cannot break the mechanism needed to fix it. There is also a safe mode that starts the program without the latest edits.

The editor's fixed core includes a **default editor**, which does not depend on any user code. It is the fallback when a running program hangs after a reload's transition, including when the failing program is the live editor itself. The default editor belongs to the editor, not to the engine: an exported application does not include it.

## Errors

Errors are values. A function that can fail returns a **result**, `T!`: either a `T`, or an **error**. There are no exceptions and no try/catch. Results are the second of the two result shapes, beside [options](#optional-types-t) (`T?`) for values that may be absent. The two look alike on purpose:

| | option | result |
| --- | --- | --- |
| type | `T?` | `T!` |
| the other case | `nil`: absent | an `Error`: failed |
| check | `is nil`, `is not nil` | `is err`, `is not err` |
| pass it up | postfix `?` | postfix `!` |

**An error is a real value.** `err("...")` makes one: a value of the built-in composite type `Error`, whose `message` field holds the `str` it was given. `return err("missing file")` returns one, and any other `return` produces a `T`.

**Checking.** A `T!` must be checked with `is err` before it is used as a `T`. Checking follows the same rules as for [options](#checking-before-use): only local bindings are narrowed, by the same five forms (`is not err`, the `else` of `is err`, an early exit, and `and` and `or` chains). Inside the error branch, the binding is narrowed to the `Error`, so its fields can be read.

```
load := fn (path: str): Image! {
  if not exists(path) { return err($"{path}: missing file") }
  return decode(path)
}

img := load("a.png")
if img is err {
  print(img.message)     # img is the Error here
  return
}
draw(img)                # img is an Image here
```

(`exists`, `decode` and `Image` are illustrative.)

**A function that can fail but returns nothing on success** has the return type `!` on its own. Success is a bare `return`, or reaching the end of the body, and failure is `return err(...)`. An inferred return type works the same way: a body with `return err(...)` and no `return value` infers `!`.

```
save := fn (f: File): ! {
  if not writable(f) { return err("read-only") }
  write(f)                  # reaching the end is success
}

r := save(f)
if r is err { print(r.message) }
```

**A `T!` cannot be ignored.** Using a call that returns a `T!` as a statement on its own, without binding its result, is a compile error. To ignore a result on purpose, bind it to `_`. A binding to `_` declares nothing, so `_` can be used any number of times.

```
save(file)               # error: the result of save may be an error
_ := save(file)          # ok: explicitly ignored
r := save(file)
if r is err { ... }
```

### Passing errors up with `!`

A postfix `!` on an expression of type `T!` passes an error up to the caller. If the expression succeeded, `e!` evaluates to its `T`. If it is an error, the current function immediately returns that error. So `e!` can only be used inside a function whose return type is itself a result (`U!`, or `!`). The `!` mirrors the `T!` type.

A postfix `?` does the same for options: on an empty `T?`, `e?` returns `nil` from a function whose return type is itself an option.

```
image_name := fn (path: str): str! {
  img := load(path)!        # returns load's error, if any
  return img.name
}

first_name := fn (d: {str}): str? {
  n := d.first?             # returns nil if first is missing
  return n
}

main := fn () {
  x := load("a.png")!       # error: main does not return a result
}
```

`e!` and `e?` bind as tightly as a call, so `load(path)!.width` reads the `width` of the loaded value. (`e?.width` is not js's optional chaining: an empty `e` returns from the function, rather than making the whole expression empty.)

**In hook handlers and top-level code, `!` and `?` report like a [fault](#faults).** A hook handler returns nothing, and top-level code is not inside a function, so there is no caller to pass to. There, `e!` on an error, or `e?` on `nil`, stops the hook call (or the module's top-level code) and reports it, exactly as a fault would: an error with its message, and a `nil` as an empty value at that line. The program keeps running. So handlers can stay short, and an unexpected failure is never silently lost.

```
on keydown fn (e: Key) {
  img := load("a.png")!     # an error: this hook call stops here
  draw(img)
}
# reported: main.qs:2 a.png: missing file
```

An ordinary function that returns nothing still cannot use `!` or `?`, as `main` above shows. Only hook handlers and top-level code have this rule.

**A fault in top-level code fails the whole module.** If a module's top-level code faults, or stops at a `!` or `?`, while the module is loading, the bindings after that point would never get values, and every binding must have one. So the module fails to load as a whole, and so does every module that imports it. What follows depends on why it was loading:

| loading for | result |
| --- | --- |
| the program's start | the failure is reported, and the program does not start |
| a [scene switch](#a-failed-switch) | the switch returns an error, and the old scene stays |
| a [reload](#failed-reloads) | a transition failure: the reload is rolled back |

```
# level.qs
data := load("level1.json")!     # an error: level.qs fails to load

# menu.qs
r := engine.scene("level.qs")
if r is err { print(r.message) } # e.g. "level1.json: missing file"; still in the menu
```

### Faults

A **fault** is a bug that the type system cannot rule out, such as writing past the end of an array. Faults are not options or results: code does not check for them. What happens depends on where the code runs.

**On the host, a fault traps the current hook call.** The hook call stops at the fault, and the runtime reports it (the file, the line, and what happened). Changes the call made before the fault are kept. The program keeps running: the next hook call runs normally. This uses the same hook-boundary catching as [infinite loops](#failed-reloads), so a fault never crashes the program.

**In shaders, a fault has a defined result**, since the GPU cannot trap. These follow wgsl's rules, and are a fallback for shader code, not the language's meaning: code should not rely on them.

| fault | on the host | in shaders |
| --- | --- | --- |
| out-of-range read of a fixed array, vector or matrix | trap | clamped to the nearest valid index |
| out-of-range write | trap | dropped: nothing is written |
| `+=` and the other compound assignments on a missing list item or dict key | trap | dropped, like a write |

(Reading a list or dict is not a fault: it gives an [optional](#indexing).)

```
on keydown fn (e: Key) {
  x := arr.(i)         # arr: [num, 4], i is 9: this keydown call stops here
  print("never runs")
}
# reported: main.qs:2 index 9 is out of range for [num, 4]
# the next hook call runs normally
```

**Not faults.** Some cases are never trapped, because they have a sensible meaning rather than hiding a bug:

| case | result |
| --- | --- |
| a fractional index | truncated toward zero (see [Indexing](#indexing)) |
| `/` by zero | an infinity or `NaN` on the host, unspecified in shaders (see [Operators](#operators)) |
| zero range step held in a variable | zero iterations |

A case the compiler can see at compile time is still a compile error where this spec says so, e.g. a constant zero step.

## Open questions

### Errors

- Custom error types: whether a result can carry a user composite as its error (e.g. a `ParseError` with a line number), or `Error` gains fields (a kind, a source location), and how code tells kinds of error apart.
- Whether an error passed up with `!` can be wrapped with context (e.g. which file failed to load).
- A value that may be absent and may fail, e.g. a lookup that can also fail: whether `T?!` is allowed, and how it is checked.
- Whether `else` also works on results (`load(p) else placeholder`), dropping the error.
- Whether a call returning an option can be ignored as a statement, as it can today (only results cannot be ignored).
- Whether binding a `T!` to a name and never checking it is also an error (e.g. `r := save(file)` with no later `is err`).
- Whether results can be used in shaders, with a GPU-side error type that holds no `str`.
- Whether `err` is a keyword (for `is err`), and whether `Error` can be written as a type on its own (e.g. a field of type `Error`).
- Whether results of other types can be dropped silently (e.g. calling `f()` as a statement when `f` returns a `num`).
- The full list of faults, beyond out-of-range reads and writes and compound assignment on a missing item, e.g. whether a `NaN` or infinite index is a fault or simply out of range.
- Whether a fault that repeats on every hook call (e.g. in the live editor's own `render`) offers the default editor, as a hang does (in the editor only).
- What a fault report contains, and where it goes (the editor, the console), especially for a program running without an editor.
- Whether shader faults can be reported in development builds (e.g. by compiling bounds checks that write to a debug buffer).
- Whether an `Error` records where it was made (file and line), for fault reports and the editor.

### Engine hooks

- The fields of the key and pointer event composites (e.g. key name, physical key code, repeat flag; pointer position, button, pointer id), and their type names.
- The default `update` rate, whether it can be changed, and how many catch-up steps run when frames fall behind.
- Whether a handler must match the hook's parameters exactly, or can take fewer (e.g. `on update fn () { ... }`).
- Whether a hook can have more than one handler in one module, and in what order they run. (Across modules, only the [current scene's](#scenes) handlers are attached.)
- The engine API for switching scenes: the two functions' names (`engine.scene` and `engine.scene_source` are illustrative), how the API itself is reached (a built-in, or an imported engine module), and how the entry scene is given to the engine (e.g. a project file, or the editor).
- Scene paths: whether they are relative to the calling file (like `import`) or to the project, and how a scene that does not exist or does not compile is reported. A path that is not a string literal can only be checked at runtime.
- A scene given as source text has no path. What its `import` paths are relative to, and what identifies its kept `@` state across reloads (which is otherwise keyed by module path).
- How compile errors in a scene's source text are reported to the code that passed it.
- An optimization that keeps modules loaded across a scene change instead of discarding them (e.g. a library that both scenes import). It would have to be invisible: a module with no top-level `mut` or `@` values computes the same values when loaded again, but one with state would visibly keep it. Whether this is done, and for which modules.
- Whether the old scene gets a hook before it is discarded (e.g. `exit`, to save progress through the persistence API). Without one, the code that requests the switch has to do it.
- What a failed switch's error contains: which kind of failure (not found, compile errors, argument mismatch) and the details of each.
- The switch call's success type: presumably `!` (nothing on success), or a handle to the pending scene.
- Loading can be slow (e.g. fetching files over the network), but the switch call loads before returning. Whether the call blocks, or how loading stays hidden, as GPU work is.
- What a second successful switch call in the same hook does: presumably the last one wins, and the scene loaded earlier is dropped.
- Whether the new scene's top-level code may run while the old scene is still current, given it runs inside the switch call (e.g. its top-level code calling engine APIs that affect the current scene).
- Whether a `ready` handler that fails at runtime (e.g. an infinite loop) is handled like a failed reload transition, given the old scene is already discarded by then.
- The cost of loading the new scene while the old one is still loaded (two scenes' modules and resources in memory at once).
- Whether a scene with no `ready` handler accepts arguments (presumably only none), and what `ready` receives for the entry scene at startup (e.g. arguments from the engine's start configuration).
- Whether refs can be passed as scene arguments, given everything they could share with is discarded.
- Whether the source-text form of switching takes arguments the same way.
- The persistence API: its names, keys (presumably `str`), which values can be stored (only `str`, or any plain value that can be serialized), whether reads are optional (`T?`, for a missing key), whether it is synchronous, where data is stored (e.g. IndexedDB or `localStorage` on the web), whether it survives restarts, and how it is scoped per program.
- Engine resources owned by discarded modules (e.g. textures held only by non-kept values): when they are freed.
- Whether more than one scene can be active at once (e.g. an overlay), or exactly one.
- Whether an imported module's top-level code may have other side effects, such as loading assets or printing, or only declarations and computed values.
- Whether code can remove a handler. (Across reloads, handlers belong to their module: see [Hooks across reloads](#hooks-across-reloads).)
- Whether the hook name is a fixed keyword-like word or an expression, and whether misspelling one is a compile error.
- How `update`'s fixed `dt` relates to the `render` context's `dt`, which is the time since the previous displayed frame.

### Modules

- The language's name and file extension.
- Whether the `_` privacy rule also applies to composite fields and functions (e.g. a private `_cache` field).
- In what order modules' top-level code runs on the first load, e.g. each import's code before its importer's. (Reloads are covered under [Live reload](#reloading-a-module).)
- Whether a module binding is a value (can it be passed to functions, or bound with `mut`?).
- Whether paths may omit the extension, and whether there are package or absolute paths.
- Whether `import` can appear anywhere, or only at a file's top level.
- How shaders use names from imported modules (presumably by the same [top-level binding](#top-level-bindings-in-shaders) rules).

### Live reload

- Whether resetting a kept binding that cannot be migrated is reported (e.g. a warning in the editor naming the binding and the field that caused it).
- A way to reset a kept value without editing its declaration (e.g. an editor command).
- How `@` combines with the private `_` prefix (`@_cache`, `_@cache`, or both), and whether `cursor` and `@cursor` can both exist in one module.
- Whether the editor and the program run in separate frames (iframes, each with its own canvas) or in workers (WebGPU through `OffscreenCanvas`), and how the program's output is shown inside the editor.
- The message channel: its API in the language, what values can be sent (presumably plain values that can be copied, not refs), and whether messages are typed.
- Which instance runs the compiler for the program's files: the editor's (sending compiled modules) or the program's (sending source).
- What the editor can inspect in the running program (e.g. its kept state, for a debugger view), given they share nothing directly.
- What an exported application does when it hangs, overflows the stack, or faults repeatedly (e.g. stops with a message, or reloads the page), and what it does with fault reports.
- Whether an exported application is the same as a release build (e.g. without type metadata or loop budgets).
- Whether shaders can use kept values, presumably as uniforms like top-level `mut` values, since a kept value is only known at runtime (even an immutable one, such as `@seed := random()`).
- Whether `@` is reserved for kept names only, or may later also be used for annotations (e.g. `@gpu`), which the `@name` form would make ambiguous.
- Migrating a renamed field by hand. The by-name rule treats a rename as a removal plus an addition, so the old field's value is dropped.
- Whether function values are allowed in kept state at all (deferred). An editor can keep data instead: a tool's name or index rather than the tool function, command composites rather than undo closures, with the functions themselves in ordinary bindings that are rebuilt on every reload. If functions are forbidden:
  - a kept binding's type cannot contain a function type anywhere (fields, list elements, dict values, nested and ref composites), checked at compile time
  - `any` would need a rule too, since it could carry a function in: either `any` never holds functions, or a function found in kept state resets its binding
  - [late binding](#function-values-across-reloads) would only matter for an importer's top-level copy of a function (`f := math.lerp`), which is not run again on reload

  If functions are allowed, a function literal with no top-level name cannot be rebound: it would either stay stale, or reset its binding by the same rule as a value that cannot be migrated.
- Whether late binding also covers composite functions (`Point.hypot`) and individual overloads, and what happens when a stored function is deleted or its signature changes.
- What the default editor does with the failed program's kept state (keep it for the next attempt, offer to reset it), and whether the failed program keeps running behind it.
- How the program is started again from the default editor once the code is fixed.
- The loop budget's size, whether it applies in release builds, and how a rollback or failure is reported to the user.
- Whether type metadata is in release builds. (Live reload itself only exists in the editor.)
- Exactly which parts form the fixed core (the compiler, the reloader, the engine, any part of the editor), how safe mode is entered, and whether safe mode and the default editor are the same thing.
- Whether a module's reload also re-runs modules that import it when its exports change, or they are only re-checked.

### Shaders

- The context's type name, and whether its type can be left out (like an [untyped receiver](#functions-and-methods)).
- How `now` (the current time) is obtained by host code for a hand-built context.
- What `before` holds on the very first frame (e.g. transparent black), and after the target is resized.
- Whether `before` for the first pass of a frame is always the last frame's final image, or can be cleared (e.g. for effects that should not see the last frame).
- The swap's cost and limits: two textures per target, and whether every target gets a `before` or only those whose shaders read it.
- Whether the context itself is a ref type (the target is shared GPU state, and a shader call draws into it), and so whether its bindings need `ref`.
- Whether context fields can be passed to ordinary helper functions (e.g. `wave(ctx.t)`), and whether a whole context can be passed to a helper that also runs on the host.
- What `t` is measured from (page load, engine start, or scene start), and whether it can be paused. In shaders a `num` is 32 bits, which loses sub-millisecond precision after a few hours, so long-running time may need wrapping.
- An integer pixel position for exact texel loads, e.g. a function that converts `ctx.xy`.
- How the context is passed to wgsl: `xy` from `@builtin(position)`, the other fields as uniforms.
- How a future vertex or compute shader would be marked, so the `sh` syntax leaves room for it.
- How a shader reads textures, samplers and buffers.
- Texture type names and kinds (1D, 2D, 3D, cube, array), formats (e.g. `rgba8unorm`, `rgba16float`), and how they are created and loaded.
- Whether textures can be optional (`ref? tex2d`). (A composite with a texture field is host-only by the ref field rule, which matches wgsl: structs cannot hold textures.)
- Whether the return type must always be `vec4`, or can follow the target's format.
- A shader that is passed its own target as an ordinary texture argument (e.g. `tint(ctx, ctx.target, c)` on the host). WebGPU cannot read and write one texture in the same pass, so this needs to be either an error or a hidden copy. (`ctx.before` is the supported way to read the previous image.)
- Whether a shader can be called from shader code, or only from the host.
- Reading GPU results back to the host, and how that interacts with the hidden asynchrony.
- How host values become shader inputs: uniforms, buffers, and the composite layout rules.
- Whether a shader can be overloaded with `sh { ... }`, like `fn { ... }`.
- Whether a shader can use non-top-level bindings, e.g. a shader defined inside a function that uses that function's locals.
- Whether `mut` top-level values of a ref type (shared) can become uniforms, or only plain values.
- How the `gpu` tag is written on composite functions (e.g. `gpu hypot(self) { ... }`) and on function namespaces (`gpu fn { ... }`).
- Whether the `gpu` tag can be used on values (e.g. `gpu UP := ...`).
- Whether `sh` is also valid inside composites.

### Lexical structure

- Whether a space is allowed between a function and its `(` (e.g. `f (a)`), and whether a trailing comma is allowed in an argument list (`f(a, b,)`).
- Named arguments at call sites (e.g. `draw(x = 1, y = 2)`), if any.
- The complete escape list (e.g. `\r`, `\0`), and whether an unknown escape is an error.
- How a literal brace is written in an interpolated string (e.g. `\{`).
- How non-`str` values are formatted when interpolated (numbers, vectors, composites, refs, `nil`).
- What an interpolated expression may contain (e.g. nested strings, other interpolated strings).
- Whether strings can span lines.
- The `str(x)` conversion: which types it accepts, and whether it formats values exactly as interpolation does.
- Other string operations: length (code points or UTF-16 units), indexing, slicing and iteration.
- Whether `:` and `=` are separate tokens, so that `x : = 1` and `x:num=1` are valid, or `:=` is a single token.
- The exact name syntax: which characters are allowed (e.g. letters, digits, `_`, Unicode), and whether keywords can be used as field names.
- Whether mixing commas and newlines within one literal is allowed (e.g. `x = 1, y = 2` on one line, then `z = 3` on the next).
- Whether a lone expression such as `+ 2` is a valid statement or an error. Making it an error catches the mistake shown under [Statements](#statements).
- Whether every block creates a new scope, and whether a bare `{ ... }` block is allowed as a statement. (Blocks never have a value: neither functions nor `if` use one.)

### Operators

- Unary minus and negative literals: whether `-1` is a literal or negation applied to `1`, and how a line starting with `-` interacts with the statement rule.
- Short-circuiting in wgsl: `&&` and `||` short-circuit on `bool`, but non-`bool` operands need the compiler's truthiness test inserted first.
- Names and exact semantics of the function forms: remainder and modulo (floored vs truncated), powers, `floor`, `trunc` and rounding.
- Whether host-only bitwise functions exist (e.g. for packing data on the host), given that they cannot be exact in shaders.
- Vector arithmetic: whether `+ - * /` work component-wise on vectors as in wgsl, and whether a scalar operand is broadcast (`v * 2`). (Matrix arithmetic is decided under [Matrices](#matrices).)
- The name of the ref identity function (e.g. `same(a, b)`).
- How `is` handles cycles of refs (e.g. two `Node`s that point at each other), since comparing contents could recurse forever.
- What `<`, `<=`, `>` and `>=` mean for vectors (component-wise, or an error), and the names of the component-wise comparison functions (e.g. `equal`, `less`).
- `is` on numbers: whether `NaN is NaN` is false (as in IEEE and wgsl), and whether `-0 is 0` is true.
- Whether composites can define their own operators.
- What `is` means for lists and dicts, e.g. equal lengths and elements, or the same keys and values.

### Control flow

- An expression form for choosing between values, e.g. a `select(a, b, cond)` built-in matching wgsl's `select`. With `if` as a statement, `y := ...` cannot pick between two values in one line otherwise.
- Which values are falsy for each built-in type (e.g. `0`, `-0`, `NaN`, empty strings and lists, all-zero vectors).
- How a user-defined type declares its falsy values, and whether a type can opt out of being used as a condition.
- Whether `..` with neither end is allowed, e.g. as "count from 0 forever".
- Whether a range with no end (`a..`) runs truly forever, given that the counter stops changing once it passes 2^53 on the host, or 2^24 in shaders.
- Whether `by` also works with a single number (`for i in 10 by 2`) and with a missing end (`5.. by -1`).
- Whether ranges are values outside `for` (e.g. `r := 0..10`, or slicing with `xs.(1..3)`).
- Which types can be iterated with `for x in xs`, and what each yields.
- What the second name binds when iterating a range (e.g. `for i, n in 0..10 by 2`): the iteration count, or an error.
- How to bind only the index, e.g. `for _, i in xs`. (`_ := ...` already discards a value; see [Errors](#errors).) Whether `_` works in every binding position, including parameters.
- Whether reassigning a `mut` range counter inside the body affects the next iteration (e.g. `i = i + 5` skipping ahead), or the next value is always computed from the range.
- Whether the index name can be annotated or `mut` (e.g. `for x, mut i in xs`).
- Whether there is a `switch` or `match`.

### Types

- Whether hex float literals exist. (Negative literals are under [Operators](#operators-1).)
- The js representation of vectors and matrices (e.g. plain objects, arrays, or `Float64Array`s).
- What a component-wise vector comparison returns, since there are no bool vectors (e.g. a vector of `0`s and `1`s, as wgsl's `step` does).
- Whether the host should optionally emulate 32-bit floats for `gpu` functions (e.g. in tests), so host and shader results can be compared exactly.
- Whether matrix constructors also accept partial input (e.g. a `mat3` from a `mat4`, keeping the top-left 3x3), and missing or extra components.
- Whether some collections need a fixed size with changeable elements (e.g. a list that can be edited but not grown), which places alone cannot express.
- Whether `m * s` (matrix times scalar) and `/` on matrices are allowed, as in wgsl's scalar multiplication.
- The vector component names: `x y z w` are used above, and the shader examples use `c.r`, so presumably `r g b a` too, as in wgsl. Which swizzles exist (e.g. `v.xy`, `c.rgb`).
- Whether the swizzles of a mutable vector can be assigned, e.g. `v.xy = vec2(1, 2)`.
- Whether `x is T` is allowed on values that are not `any` (e.g. on a plain `num`, where it is always known at compile time: a warning, an error, or simply `true`).
- Whether `any` is allowed outside lists and dicts in general (bindings, fields, anonymous composite fields). Parameters can be `any`: a scene's `ready` can take `...args: [any]` (see [Scene arguments](#scene-arguments)).
- Whether storing into an `any` copies the value or can hold a ref, and how inherently ref types (which cannot be copied) are stored in one.
- What `is` (equality) does between two `any` values of different types: `false`, or a compile error.
- Whether `any` loop items (`for x in stuff`) are shared like other loop items, and what assigning through one does when the new value has a different type.
- How an anonymous composite's type is written (e.g. `{ name: str, age: num }` as a type), and whether two anonymous composites with the same fields have the same type (structural typing).
- Whether an anonymous composite can be GPU compatible, and so used in shaders, when all its fields are.
- Whether an anonymous composite literal's fields can be `ref` fields, or have defaults.
- Whether narrowing a `T?` and then an `any` can be combined in one check (e.g. `if t is str` directly on an `any?`, treating empty as "not a str"), e.g. for reading an `{any}` dict.
- Whether the fields of an anonymous composite can be iterated, and in what order.
- The names and signatures of the list library functions (e.g. `push`, `pop`, `insert`, `remove`, `find`). They are generic over the element type, which user functions cannot be, so they are built-ins.
- Whether a read-only ref parameter on a library function that only reads (e.g. `find(ref xs, 3)`) is worth avoiding a copy, or such functions take plain parameters and rely on the compiler skipping unobserved copies.
- The names and signatures of the dict library functions (e.g. `keys(d)`, `has(d, k)`, `remove(ref mut d, k)`). A dict has no methods, so `d.keys()` would read the key `"keys"`.
- The order in which `for v, k in d` visits a dict's entries (e.g. insertion order).
- Whether a dict's values are shared by `for` loops like list items, and whether a dict can hold refs or inherently ref types.
- Whether an empty `{}` or `[]` can take its type from context (e.g. as an argument to a `{num}` parameter), or only from a written annotation as shown above. (An empty `{}` is presumably always a dict, since an anonymous composite with no fields is not useful.)
- What a field default can be: only a constant, or any expression (and when it is evaluated). This matters for [live reload](#when-a-kept-values-type-changes), where a new field's default is how kept values are migrated.
- Whether a constructor can return a modified copy of a literal, e.g. build `mut p := Point { ... }`, then set `p.x` on a `mut` field before `return p`. (Nothing in the rules forbids it.)
- Whether a composite literal can be used when the type has constructors, or constructors replace it.
- Whether a type with no constructors can be called like a function, e.g. `Point(1, 2)` as an implicit field-order constructor.
- Whether constructors can be written for ref composites, and how construction works for them.
- Whether a function's name can be the same as the composite's own name.
- Referring to a composite function as a value without calling it (e.g. `f := Point.hypot`). When a field shares the name, `p.size` without a call is always the field, so is there a way to name the function itself?
- What a field whose type is a function means when a function shares its name: `p.f()` could call the field's function or the composite function.
- Whether a composite's functions can refer to each other without the `Point.` prefix.
- Whether a static function can be called through a value (`p.origin()`), or only through the type.
- Whether `type` can also name a non-composite type, i.e. an alias such as `Pos := vec3` or `Pos := type vec3`.
- Whether types are first-class values at runtime, or `Name := type { ... }` is only compile-time syntax that happens to use the binding form.
- Whether composites can be generic, e.g. take a type parameter (`Pair<T>`, illustrative).
- The full list of types that need a buffer-safe stored form besides `bool`, and their exact conversions.
- Memory layout for composites passed from js to the GPU. wgsl has strict alignment and padding rules (e.g. a `vec3`, wgsl `vec3f`, takes 16 bytes, and uniform buffers are stricter than storage buffers). The compiler must generate the packing code, and must keep fields in their written order.
- Whether a `[T]` list can be a field of a GPU-compatible composite, given wgsl only allows a runtime-sized array as the last member of a storage-buffer struct.
- Whether "composite" could be confused with wgsl's own term, which covers vectors, matrices, arrays and structs.
- Self-referential composites: a ref composite can contain a field of its own type as `ref? Node` (shown under [Ref composites](#ref-composites)), and a plain composite presumably cannot contain itself, since it would have infinite size. Can a non-nullable `ref Node` field of its own type exist at all, given the first node could never be built?
- Whether `nil` is a keyword.
- How `is` compares two optionals when one or both are empty (e.g. whether `a is b` is true when both are `nil`), given `is` otherwise compares contents.
- js interop: values that come from js can be `null` or `undefined`. How these are handled at the boundary.
- `[T]` lists in shaders: wgsl only allows runtime-sized arrays as the last member of a storage buffer, not as local values or parameters. Can shader code only receive them (as storage buffers), never create them?
- Array and list literal forms beyond `[a, b, c]` and `[]` (e.g. a repeat form), and creating a list of runtime length (e.g. filled with a value).
- Whether a string's length (`len(s)`) counts code points or UTF-16 units.
- Whether a `[T, N]` value converts to `[T]`.
- Which built-in types, besides textures, are inherently ref types.

### Refs

- Whether writing `ref` on an argument that is already a ref (`g(ref r)`) is allowed. By the [`ref` shares](#ref-shares) rule it would refer to the same storage, the same as `g(r)`.
- A dot call on a temporary that changes it, e.g. `Point.origin().move(1, 0)`, changes a value that is then discarded. Should that be a warning or an error?
- Sharing an element of a list or dict (e.g. `e := ref list.3`) when the collection later grows, shrinks or reallocates: does `e` keep referring to the old item?
- The name and form of the library function that copies an inherently ref type (e.g. `copy(n)`), and whether every ref type can be copied that way (a texture copy is a GPU operation).
- How an optional mutable ref is written (presumably `ref? mut T`), e.g. for a linked node's `next` field that should allow changing the next node through it. (`ref? Node` is read-only.)
- Other wgsl pointer restrictions that affect refs in shaders, e.g. pointers into some address spaces cannot be passed to functions, and pointers cannot be stored in a `var` or a struct.

### Functions

- Variadics and overload resolution: how a variadic overload ranks against a fixed-count one that also matches (e.g. `f(a: str)` and `f(...xs: [str])` for `f("x")`).
- Spreading an existing list into a variadic call (e.g. `cat(...words)`).
- Whether a variadic parameter can be `mut` (`mut ...parts: [str]`), to change the collected list in the body.
- The name of the "returns nothing" type, if it can be written (e.g. `void`). A function that can fail but returns nothing is written `: !` without it.
- How the return type of a recursive function is inferred, or whether it must be written. (wgsl forbids recursion, so this only matters on js.)
- Whether overload entries can give a return type the same way, e.g. `(a: num): num { ... }`.
- Whether overload entries in `fn { ... }` and in a composite's `name { ... }` can also be separated by commas, as type definition entries can.
- Whether overloads can differ only in return type. The current rules say no, since resolution only looks at arguments.
- Whether `(v: vec3)`, `(v: ref vec3)` and `(v: ref mut vec3)` can be overloads of one namespace.
- Whether a function namespace can be passed around as a value (e.g. `f := greet`, then `f("Ana")`), and what its type is.
- Naming of the compiled functions for each overload (mangling scheme).
