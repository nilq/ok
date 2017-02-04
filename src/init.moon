with love
  current_folder = ((...)\gsub "%.init$", "") .. "."

  cpml = require "cpml"
  ffi  = require "ffi"

  use_gles = false

  ok = {}

  ----------------------------------
  -- love bindings
  ----------------------------------
  new_canvas = .graphics.newCanvas

  ----------------------------------
  -- utility functions
  ----------------------------------
  is_callable = (x) ->
    (nil != (getmetatable x).__call or "function" == type x)

  -- combines a set of functions
  combine = (...) ->
    _error = "expected either function or nil"

    n = select "#", ...

    return noop if n == 0

    if n == 1
      fn = select 1, ...

      return noop unless fn

      assert (is_callable fn), _error

      return fn

    funcs = {}

    for i = 1, n
      fn = select i, ...

      if fn != nil
        assert (is_callable fn), _error
        funcs[#funcs + 1] = fn

    (...) ->
      for f in *funcs
        f ...

  ----------------------------------
  -- procedure for important OpenGL functions
  -- @use_monkey
        -- patch the Love API with Ok functions
  -- @automatic
        -- attempt to automatically upload transformation matrices
  ----------------------------------
  ok.summon = (use_monkey, automatic) ->
    unless pcall -> ffi.C.SDL_GL_DEPTH_SIZE
      ffi.cdef [[
          typedef enum {
            SDL_GL_DEPTH_SIZE = 6
          } SDL_GLattr;

          void *SDL_GL_GetProcAddress(const char *proc);

          int SDL_GL_GetAttribute(SDL_GLattr attr, int* value);
        ]]

    local sdl

    if "Windows" == .system.getOS!
      if not .filesystem.isFused! and .filesystem.isFile "bin/SDL2.dll"
        sdl = ffi.load "bin/SDL2"
      else
        sdl = ffi.load "SDL2"
    else
      sdl = ffi.C

    local opengl

    if "OpenGL ES" == select 1, .graphics.getRendererInfo!
      use_gles = true

      opengl = require current_folder .. "/lib/opengles2"
    else
      opengl = require current_folder .. "/lib/opengl"

    opengl.loader = (fn) ->
      sdl.SDL_GL_GetProcAddress fn

    opengl\summon!

    ok._state = {
      stack: {}
    }

    ok.push "all"

    out = ffi.new "int[?]", 1
    sdl.SDL_GL_GetAttribute sdl.SDL_GL_DEPTH_SIZE, out

    assert out[0] > 8, "fucked up depth buffer: not good"

    print string.format "[depth bits]: %d", out[0]

    ok.patch automatic == nil and true or automatic if use_monkey

  ok.clear = (color, depth) ->
    to_clear = 0

    if color
      to_clear = bit.bor to_clear, tonumber GL.COLOR_BUFFER_BIT

    if depth or depth == nil
      to_clear = bit.bor to_clear, tonumber GL.DEPTH_BUFFER_BIT

    gl.Clear to_clear

  ok.reset = ->
    ok.set_depth_test!
    ok.set_depth_write!
    ok.set_culling!
    ok.set_front_face!

  ok.get_fxaa_alpha = (color) ->
    c_vec = (cpml.vec3.isvector color) and color or cpml.vec3 color
    c_vec\dot cpml.vec3 0.299, 0.587, 0.114

  ok.set_fxaa_background = (color) ->
    c_vec = (cpml.vec3.isvector color) and color or cpml.vec3 color
    .graphics.setBackgroundColor c_vec.x, c_vec.y, c_vec.z, ok.get_fxaa_alpha c_vec

  -- enable or disable writing to depth buffer
  ok.set_depth_write = (mask) ->
    assert "boolean" == type mask, "fucked up parameter typing" if mask
    gl.DepthMask mask or true

  ok.set_depth_test = (method) ->
    if method
      methods = {
        greater: GL.GEQUAL
        equal:   GL.EQUAL
        less:    GL.LEQUAL
      }

      assert methods[method], "fucked up invalid depth test operation"

      gl.Enable GL.DEPTH_TEST
      gl.DepthFunc methods[method]

      if use_gles
        gl.DepthRangef 0, 1
        gl.ClearDepthf 1
      else
        gl.DepthRange 0, 1
        gl.ClearDepth 1
    else
      gl.Disable GL.DEPTH_TEST

  ok.set_front_face = (facing) ->
    if not facing or facing == "ccw"
      gl.FrontFace GL.CCW
      return
    elseif facing == "cw"
      gl.FrontFace GL.CW
      return

    error "invalid face winding, must be 'cw' or 'ccw', defaults to 'ccw' if nil"

  ok.set_culling = (method) ->
    unless method
      gl.Disable GL.CULL_FACE
      return

    gl.Enable GL.CULL_FACE

    switch method
      when "back"
        gl.CullFace GL.BACK
        return
      when "front"
        gl.CullFace GL.FRONT
        return

    error "invalid culling method, must be 'front' or 'back', defaults to *disabled*"

  ok.new_shader_raw = (gl_version, vc, pc) ->
    is_vc = (code) ->
      code\match "#ifdef%s+VERTEX" != nil

    is_pc = (code) ->
      code\match "#ifdef#s+PIXEL" != nil

    mk_shader_code = (arg1, arg2) ->
      if "OpenGL ES" == .graphics.getRendererInfo!
        error "fucked up something with GLES"

      local vc, pc

      something = (a) ->
        if a
          vc = a if is_vc a
          is_pixel = is_pc a
          pc = a if is_pixel

      something arg1
      something arg2

      versions = {
        ["2.1"]: "120", ["3.0"]: "130", ["3.1"]: "140", ["3.2"]: "150",
  			["3.3"]: "330", ["4.0"]: "400", ["4.1"]: "410", ["4.2"]: "420",
  			["4.3"]: "430", ["4.4"]: "440", ["4.5"]: "450",
      }

      fmt = [[%s
#ifndef GL_ES
#define lowp
#define mediump
#define highp
#endif

#pragma optionNV(strict on)
#define %s
#line 0
%s]]
      vs = arg1 and (string.format fmt, "#version #{versions[gl_version]}", "VERTEX", "vc") or nil
      ps = arg2 and (string.format fmt, versions[gl_version], "PIXEL", pc) or nil

      vs, ps

    orig = .graphics._shaderCodeToGLSL
    .graphics._shaderCodeToGLSL = mk_shader_code

    shader = .graphics.newShader vc, pc
    .graphics._shaderCodeToGLSL = orig

    shader

  ok.update_shader = (shader) ->
    ok._active_shader = shader

  ok.push = (which) ->
    stack = ok._state.stack

    assert #stack < 64, "stack overflow - too deep, fucked up - please pop"

    if #stack == 0
      table.insert stack, {
        projection: false
        matrix: cpml.mat4!
        active_shader: ok._active_shader
      }
    else
      top = stack[#stack]

      new = {
        projection: top.projection
        matrix: top.matrix\clone!
        active_shader: top.active_shader
      }

      if "all" == which
        new.active_shader = top.active_shader

      table.insert stack, new

    ok._state.stack_top = stack[#stack]

  ok.pop = ->
    stack = ok._state.stack

    assert #stack > 1, "stack underflow - popped a lot"

    table.remove stack

    top = stack[#stack]

    ok._state.stack_top = top

  ok.translate = (x, y, z) ->
    top = ok._state.stack_top
    top.matrix = top.matrix\translate cpml.vec3 x, y, z or 0

  ok.rotate = (r, axis) ->
    top = ok._state.stack_top

    if "table" == type r and r.w
      top.matrix = top.matrix\rotate r
      return

    assert "number" == type r

    top.matrix = top.matrix\rotate r, axis or cpml.vec3.unit_z

  ok.scale = (x, y, z) ->
    top = ok._state.stack_top
    top.matrix = top.matrix\scale x, y, z or 1

  ok.origin = ->
    top = ok._state.stack_top
    top.matrix = top.matrix\identity!

  ok.get_matrix = ->
    ok._state.stack_top.matrix

  ok.update_matrix = (matrix_type, m) ->
    unless ok._active_shader return

    local w, h

    if "projection" == matrix_type
      w, h = .graphics.getDimensions!

    send_m = m or "projection" == matrix_type and (cpml.mat4!\ortho 0, w, 0, h, -100, 100) or ok.get_matrix!

    ok._active_shader\send matrix_type == "transform" and "u_model" or "u_projection", send_m\to_vec4s!

    if "projection" == matrix_type
      ok._state.stack_top.projection = true

  ok.new_triangles = (t, offset=(cpml.vec3 0, 0, 0), mesh, usage) ->
    data, indices = {}, {}

    for k, v in pairs t
      current = {}

      table.insert current, v.x + offset.x
      table.insert current, v.y + offset.y
      table.insert current, v.z + offset.z

      table.insert data, current

      unless mesh
        table.insert indices, k

    unless mesh
      layout = {
        {"VertexPosition", "float", 3}
      }

      m = .graphics.newMesh layout, data, "triangles", usage or "static"
      m\setVertexMap indices

      return m
    else
      mesh\setVertices data if mesh.setVertices
      return mesh
