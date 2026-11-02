# Build render.html: the launcher's wallpaper shader on a bare canvas, with draw(t) for render.js to call.
# Usage (from this folder):  python3 make-render-page.py && node render.js && python3 encode.py
import os
import re

here = os.path.dirname(os.path.abspath(__file__))
src = open(os.path.join(here, "..", "launcher", "index.html")).read()
frag = re.search(r'<script type="x-shader/x-fragment" id="frag">(.*?)</script>', src, re.S).group(1)

html = '''<!doctype html><meta charset="utf-8"><body style="margin:0;background:#000">
<canvas id="c" width="W" height="H" style="display:block"></canvas>
<script type="x-shader/x-fragment" id="frag">''' + frag + '''</script>
<script>
const cv = document.getElementById("c");
const gl = cv.getContext("webgl2", { antialias: false, alpha: false, depth: false, preserveDrawingBuffer: true });
const vs = `#version 300 es\\nvoid main(){vec2 p=vec2((gl_VertexID<<1)&2,gl_VertexID&2);gl_Position=vec4(p*2.0-1.0,0.0,1.0);}`;
const mk = (t, s) => { const o = gl.createShader(t); gl.shaderSource(o, s); gl.compileShader(o);
  if (!gl.getShaderParameter(o, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(o)); return o; };
const p = gl.createProgram();
gl.attachShader(p, mk(gl.VERTEX_SHADER, vs));
gl.attachShader(p, mk(gl.FRAGMENT_SHADER, document.getElementById("frag").textContent));
gl.linkProgram(p);
const U = {}; for (const n of ["uRes", "uTime", "uSeed", "uTap", "uHold", "uLite"]) U[n] = gl.getUniformLocation(p, n);
gl.bindVertexArray(gl.createVertexArray()); gl.useProgram(p);
// full quality (both mesh sheets), no tap ripple, no hold
window.draw = (t) => {
  gl.viewport(0, 0, cv.width, cv.height); gl.uniform2f(U.uRes, cv.width, cv.height); gl.uniform1f(U.uTime, t);
  gl.uniform1ui(U.uSeed, 0); gl.uniform3f(U.uTap, 9, 9, -99); gl.uniform1f(U.uHold, 0); gl.uniform1f(U.uLite, 0);
  gl.drawArrays(gl.TRIANGLES, 0, 3); gl.finish();
};
</script>'''
open(os.path.join(here, "render.html"), "w").write(html)
print("wrote render.html")
