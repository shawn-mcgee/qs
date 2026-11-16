
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

  fun update(mut self, context) {
    self.frame += 1
    # ...
  }

  gpu render(self, context) {
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
  (name) { print("Hello", name) }
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