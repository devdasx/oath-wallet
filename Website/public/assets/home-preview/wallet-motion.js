// Palette math mirrors OathAtmosphere/OathColorway.swift. No app data is used.
export const COLORWAYS = [
  ['cobalt', 0x244DE0], ['azure', 0x288CBC],
  ['indigo', 0x5140C5], ['amethyst', 0x8B36C9], ['orchid', 0xBC39A2],
  ['rose', 0xDF438D], ['ruby', 0xBC2835], ['copper', 0xCC6B35], ['champagne', 0xB2964F], ['platinum', 0x656977],
];
export const HOLD_SECONDS = 5;
export const TRANSITION_SECONDS = 0.5; // Native OathBackground.easeInOut(duration: 0.5).
export function paletteFor(rgb) {
  const linear = byte => { const x = (byte & 255) / 255; return x <= .04045 ? x / 12.92 : ((x + .055) / 1.055) ** 2.4; };
  const r = linear(rgb >> 16), g = linear(rgb >> 8), b = linear(rgb);
  const l = Math.cbrt(.4122214708*r + .5363325363*g + .0514459929*b);
  const m = Math.cbrt(.2119034982*r + .6806995451*g + .1073969566*b);
  const s = Math.cbrt(.0883024619*r + .2817188376*g + .6299787005*b);
  const tone = Math.min(1, Math.max(0, .2104542553*l + .793617785*m - .0040720468*s));
  const a = 1.9779984951*l - 2.428592205*m + .4505937099*s;
  const labB = .0259040371*l + .7827717662*m - .808675766*s;
  const magnitude = Math.hypot(a, labB);
  const chroma = magnitude < .0001 ? 0 : Math.min(.19, magnitude);
  const direction = chroma === 0 ? [0, 0] : [a/magnitude, labB/magnitude];
  const shade = (lightness, saturation) => {
    const linearRGB = c => {
      const a = direction[0]*c, b = direction[1]*c;
      const l = (lightness + .3963377774*a + .2158037573*b) ** 3;
      const m = (lightness - .1055613458*a - .0638541728*b) ** 3;
      const s = (lightness - .0894841775*a - 1.291485548*b) ** 3;
      return [4.0767416621*l - 3.3077115913*m + .2309699292*s, -1.2684380046*l + 2.6097574011*m - .3413193965*s, -.0041960863*l - .7034186147*m + 1.707614701*s];
    };
    const inGamut = values => values.every(x => x >= 0 && x <= 1);
    let c = chroma*saturation, value = linearRGB(c);
    if (!inGamut(value)) {
      let low = 0, high = c;
      for (let i=0; i<12; i++) { const mid=(low+high)/2; if(inGamut(linearRGB(mid))) low=mid; else high=mid; }
      value=linearRGB(low);
    }
    return value.map(x => { x=Math.min(1,Math.max(0,x)); return x<=.0031308 ? 12.92*x : 1.055*x**(1/2.4)-.055; });
  };
  return [shade(.32+tone*.08,.80), shade(.52+tone*.10,.90), shade(.20+tone*.04,.35), shade(.32+tone*.06,.50)].flat();
}
export const PALETTES = COLORWAYS.map(([, rgb]) => paletteFor(rgb));
// CSS/SwiftUI ease-in-out: solve cubic-bezier(.42, 0, .58, 1), not a linear fade.
export function easeInOut(x) {
  if (x <= 0) return 0;
  if (x >= 1) return 1;
  let low=0, high=1;
  for (let i=0; i<18; i++) {
    const t=(low+high)/2, q=1-t;
    if (3*q*q*t*.42 + 3*q*t*t*.58 + t*t*t < x) low=t; else high=t;
  }
  const t=(low+high)/2;
  return 3*(1-t)*t*t+t*t*t;
}
export function paletteAt(seconds) {
  const cycle=HOLD_SECONDS+TRANSITION_SECONDS;
  const index=Math.floor(Math.max(0,seconds)/cycle)%PALETTES.length;
  const fraction=easeInOut((Math.max(0,seconds)%cycle-HOLD_SECONDS)/TRANSITION_SECONDS);
  return {name:COLORWAYS[index][0], values:PALETTES[index].map((x,i)=>x+(PALETTES[(index+1)%PALETTES.length][i]-x)*fraction)};
}

// Lazy initialization: one small canvas, a 30fps cap, no rendering offscreen or in hidden tabs.
// Native Cobalt poster stays visible if WebGL is unavailable or the context is lost.
export function mountWalletMotion(canvas) {
  let disposed=false, visible=false, lost=false, paused=false, frame=0, elapsed=0, last=null;
  let gl, program, buffer, shaders=[], uniforms, initializing=false, failed=false;
  const abort=new AbortController();
  const media=window.matchMedia('(prefers-reduced-motion: reduce)');
  const button=document.createElement('button');
  button.type='button';
  button.textContent='Pause animation';
  button.setAttribute('aria-label','Pause wallet preview animation');
  // Keep the drawn app untouched. The quiet playback control lives in the phone's containing figure.
  button.style.cssText='position:absolute;right:8px;bottom:8px;z-index:3;padding:6px 10px;border:1px solid #ffffff40;border-radius:20px;background:#161616;color:#fff;font:11px system-ui;cursor:pointer;display:none';
  const controls=canvas.closest('[data-preview-stage]');
  controls?.append(button);
  const stop=()=>{cancelAnimationFrame(frame);frame=0;last=null;};
  const release=()=>{
    if(gl){if(buffer)gl.deleteBuffer(buffer);if(program)gl.deleteProgram(program);shaders.forEach(s=>gl.deleteShader(s));}
    buffer=null;program=null;shaders=[];uniforms=null;
  };
  const draw=()=>{
    if(!program || lost || disposed)return;
    const palette=paletteAt(elapsed);
    gl.useProgram(program);gl.bindBuffer(gl.ARRAY_BUFFER,buffer);
    const attribute=gl.getAttribLocation(program,'position');
    gl.enableVertexAttribArray(attribute);gl.vertexAttribPointer(attribute,2,gl.FLOAT,false,0,0);
    gl.viewport(0,0,canvas.width,canvas.height);
    gl.uniform2f(uniforms.resolution,canvas.width,canvas.height);gl.uniform1f(uniforms.time,elapsed);
    ['deep','crest','reflectionColor','darkReflection'].forEach((name,i)=>gl.uniform3fv(uniforms[name],palette.values.slice(i*3,i*3+3)));
    gl.drawArrays(gl.TRIANGLES,0,3);
    canvas.style.opacity='1';canvas.dataset.colorway=palette.name;
  };
  const tick=now=>{
    frame=0;
    if(disposed || !visible || document.hidden || media.matches || paused || lost)return;
    if(last===null){last=now;draw();}
    else if(now-last>=1000/30){elapsed+=(now-last)/1000;last=now;draw();}
    frame=requestAnimationFrame(tick);
  };
  const sync=()=>{
    stop();
    if(disposed || !visible || document.hidden || lost || failed)return;
    if(!program){initialize();return;}
    draw();
    button.style.display=media.matches?'none':'block';
    if(!media.matches && !paused)frame=requestAnimationFrame(tick);
  };
  async function initialize(){
    if(initializing || failed || disposed)return;
    initializing=true;
    try{
      const response=await fetch(new URL('./silk.frag',import.meta.url),{signal:abort.signal});
      if(!response.ok)throw new Error('Artwork unavailable');
      const fragment=await response.text();
      if(disposed || lost)return;
      gl=canvas.getContext('webgl',{alpha:false,antialias:false,depth:false,stencil:false,powerPreference:'low-power'});
      if(!gl)throw new Error('WebGL unavailable');
      // Fixed 1.5x drawing buffer; text remains full-resolution HTML.
      canvas.width=660;canvas.height=690;
      const compile=(type,source)=>{
        const shader=gl.createShader(type);shaders.push(shader);gl.shaderSource(shader,source);gl.compileShader(shader);
        if(!gl.getShaderParameter(shader,gl.COMPILE_STATUS))throw new Error('Artwork shader unavailable');
        return shader;
      };
      program=gl.createProgram();
      gl.attachShader(program,compile(gl.VERTEX_SHADER,'attribute vec2 position; void main(){gl_Position=vec4(position,0.0,1.0);}'));
      gl.attachShader(program,compile(gl.FRAGMENT_SHADER,fragment));gl.linkProgram(program);
      if(!gl.getProgramParameter(program,gl.LINK_STATUS))throw new Error('Artwork pipeline unavailable');
      buffer=gl.createBuffer();gl.bindBuffer(gl.ARRAY_BUFFER,buffer);gl.bufferData(gl.ARRAY_BUFFER,new Float32Array([-1,-1,3,-1,-1,3]),gl.STATIC_DRAW);
      uniforms=Object.fromEntries(['resolution','time','deep','crest','reflectionColor','darkReflection'].map(key=>[key,gl.getUniformLocation(program,key)]));
      canvas.dataset.motion='ready';sync();
    }catch(error){
      if(!disposed && error.name!=='AbortError'){
        failed=true;release();canvas.style.opacity='0';canvas.dataset.motion='fallback';button.style.display='none';
      }
    }finally{initializing=false;}
  }
  const onLost=event=>{event.preventDefault();lost=true;stop();canvas.style.opacity='0';canvas.dataset.motion='fallback';button.style.display='none';};
  const onRestored=()=>{lost=false;failed=false;release();sync();};
  const onToggle=()=>{paused=!paused;button.textContent=paused?'Resume animation':'Pause animation';button.setAttribute('aria-label',paused?'Resume wallet preview animation':'Pause wallet preview animation');sync();};
  const observer=new IntersectionObserver(entries=>{visible=entries.some(entry=>entry.isIntersecting);sync();});
  observer.observe(canvas);
  document.addEventListener('visibilitychange',sync);
  media.addEventListener('change',sync);
  canvas.addEventListener('webglcontextlost',onLost);
  canvas.addEventListener('webglcontextrestored',onRestored);
  button.addEventListener('click',onToggle);
  return ()=>{
    disposed=true;abort.abort();stop();observer.disconnect();release();button.remove();
    document.removeEventListener('visibilitychange',sync);media.removeEventListener('change',sync);
    canvas.removeEventListener('webglcontextlost',onLost);canvas.removeEventListener('webglcontextrestored',onRestored);
    button.removeEventListener('click',onToggle);
  };
}
