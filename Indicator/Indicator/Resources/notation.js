/* 드럼 채보 공용 오선 표기 엔진 — /chart(편집)와 /drum(뷰어) 양쪽이 이 파일 하나를 그대로 쓴다.
   전에는 이 코드가 두 파일에 각각 복사돼 있었는데, 그러면 한쪽만 고치고 다른 쪽을 깜빡하는
   사고가 나기 쉽다. 이제 "채보 한 마디를 어떻게 그릴지"는 여기 한 곳에만 있고, /chart의 실제
   편집 상호작용(선택·커서·입력·오디오)과 /drum의 라이브 동기화(곡 자동 추적·하이라이트)는
   각자 페이지에 남아 이 엔진을 호출만 한다.
   전역을 더럽히지 않도록 전부 이 IIFE 안에 있고, 밖에서 쓸 것만 window.Notation으로 내보낸다. */
(function(){
'use strict';

const SVG_NS = 'http://www.w3.org/2000/svg';
const VK = {hand:'h', foot:'f'};
const DIV_OK = [2,3,4,6,8];
const INSTR = [
  {id:'crash', name:'크래쉬 16″', head:'x', pos:-2, voice:'hand'},
  {id:'hihat', name:'하이햇',     head:'x', pos:-1, voice:'hand'},
  {id:'ride',  name:'라이드',     head:'x', pos: 0, voice:'hand'},
  {id:'tom1',  name:'탐 10″',    head:'n', pos: 1, voice:'hand'},
  {id:'tom2',  name:'탐 12″',    head:'n', pos: 2, voice:'hand'},
  {id:'snare', name:'스네어',     head:'n', pos: 3, voice:'hand'},
  {id:'ftom',  name:'플로어탐',   head:'n', pos: 5, voice:'hand'},
  {id:'kick',  name:'킥',        head:'n', pos: 7, voice:'foot'},
];
const byId = Object.fromEntries(INSTR.map(i=>[i.id,i]));
const ART = {OFF:0, NORM:1, GHOST:2, ACCENT:3, OPEN:4};

function beatCount(m){ return (m && m.ts) ? (m.ts[0]|0) || 4 : 4; }
function divOf(m, b, voice){
  const d = m && m.div && m.div[b];
  const v = d ? d[VK[voice]] : 0;
  return DIV_OK.includes(v) ? v : 4;
}
function beatOffset(m, voice, b){
  let n = 0;
  for(let i=0; i<b; i++) n += divOf(m, i, voice);
  return n;
}
function locOf(m, voice, idx){
  let n = 0;
  for(let b=0; b<beatCount(m); b++){
    const d = divOf(m, b, voice);
    if(idx < n + d) return {b, k: idx - n, d};
    n += d;
  }
  const b = beatCount(m) - 1, d = divOf(m, b, voice);
  return {b, k: d-1, d};
}
function beatPosOf(m, voice, idx){
  const l = locOf(m, voice, idx);
  return l.b + l.k / l.d;
}
function normTs(src){
  if(!Array.isArray(src)) return [4,4];
  const num = Math.max(1, Math.min(32, src[0]|0)) || 4;
  const den = (src[1]|0) === 8 ? 8 : 4;
  return [num, den];
}
function tsKey(m){ return (m && m.ts) ? m.ts.join('/') : '4/4'; }

/* ── SVG 그리기 ── */
const LG = 9;                 // 오선 간격
const INK = '#14121A';
let GEO = {SLOT_W:19, BEAT_GAP:6, M_PAD:13, CLEF_W:54};
let SVGT = null;   // 현재 그리는 대상 SVG (drawMeasure류가 여기 append한다)

function el(name, attrs){
  const e = document.createElementNS(SVG_NS, name);
  for(const k in attrs) e.setAttribute(k, attrs[k]);
  return e;
}
function yOf(pos, top){ return top + pos*LG/2; }
function beatW(){ return 4*GEO.SLOT_W; }
function xAtPos(mx, pos){
  const b = Math.floor(pos + 1e-9);
  return mx + GEO.M_PAD + b*(beatW() + GEO.BEAT_GAP) + (pos - b)*beatW() + 6;
}
const UNIT_FLAGS = {2:1, 3:1, 4:2, 6:2, 8:3};
function noteValue(span, div){
  const u = UNIT_FLAGS[div] || 2;
  let p = 1;
  while(p*2 <= span) p *= 2;
  const flags = Math.max(0, u - Math.round(Math.log2(p)));
  return {flags, dot: (span === p*1.5)};
}
function isTuplet(d){ return d===3 || d===6; }
function voiceHasAny(m, voice){
  return INSTR.some(i => i.voice===voice && m[i.id].some(v=>v));
}
function onsetsOf(m, b, voice){
  const arr=[], d = divOf(m, b, voice), off = beatOffset(m, voice, b);
  for(let k=0; k<d; k++){
    const ids = INSTR.filter(i=>i.voice===voice && m[i.id][off+k]).map(i=>i.id);
    if(ids.length) arr.push({k, ids, idx: off+k});
  }
  return arr;
}
function restsFor(start, len, div){
  const out = [];
  let s = start, n = len;
  let guard = 0;
  while(n > 0 && guard++ < 32){
    let p = 1;
    while(p*2 <= n && s % (p*2) === 0) p *= 2;
    if(s % (p*2) === 0 && n === p*1.5){ out.push([s, p*1.5, div]); break; }
    out.push([s, p, div]);
    s += p; n -= p;
  }
  return out;
}
function tupletMark(x1, x2, y, up, num, bracket){
  const mid = (x1 + x2)/2, half = 5.2;
  const t = el('text',{x:mid, y:y + (up ? 3.4 : 3.4), 'font-size':10.5, 'font-weight':'700',
    fill:INK, 'font-family':'Georgia,"Times New Roman",serif', 'text-anchor':'middle'});
  t.textContent = String(num);
  if(bracket){
    const hook = up ? 4 : -4;
    const seg = (a, b)=> SVGT.appendChild(el('line',{x1:a, y1:y, x2:b, y2:y,
      stroke:INK, 'stroke-width':1.1, 'stroke-linecap':'round'}));
    seg(x1, mid - half); seg(mid + half, x2);
    SVGT.appendChild(el('line',{x1, y1:y, x2:x1, y2:y + hook, stroke:INK, 'stroke-width':1.1, 'stroke-linecap':'round'}));
    SVGT.appendChild(el('line',{x1:x2, y1:y, x2:x2, y2:y + hook, stroke:INK, 'stroke-width':1.1, 'stroke-linecap':'round'}));
  }
  SVGT.appendChild(t);
}
function drawVoiceBeat(m, mx, top, b, voice){
  const ons = onsetsOf(m, b, voice);
  const up = (voice==='hand');
  const div = divOf(m, b, voice);
  const xOfK = k => xAtPos(mx, b + k/div);
  if(!ons.length){
    drawRest(xAtPos(mx, b + 0.375), top, up, 0, false);
    return;
  }
  const lead = ons[0].k;
  if(lead > 0){
    restsFor(0, lead, div).forEach(([k, span])=>{
      const v = noteValue(span, div);
      drawRest(xOfK(k), top, up, v.flags, v.dot);
    });
  }
  const notes = ons.map((o,i)=>{
    const next = (i<ons.length-1)? ons[i+1].k : div;
    const span = next - o.k;
    const v = noteValue(span, div);
    const x = xOfK(o.k);
    const ys = o.ids.map(id => yOf(byId[id].pos, top));
    return {x, ys, span, flags:v.flags, dot:v.dot, k:o.k, s:o.idx, ids:o.ids};
  });
  const wholeBeatOne = (notes.length===1 && notes[0].k===0 && notes[0].span===div);
  if(wholeBeatOne){ notes[0].flags = 0; notes[0].dot = false; }
  let beamY;
  if(up){
    const minY = Math.min(...notes.flatMap(n=>n.ys));
    beamY = Math.min(minY - 30, top - 14);
  } else {
    const maxY = Math.max(...notes.flatMap(n=>n.ys));
    beamY = Math.max(maxY + 28, top + 4*LG + 22);
  }
  const stemDx = up ? 5.2 : -5.2;
  notes.forEach(n=>{
    n.ids.forEach(id=>{
      const ins = byId[id];
      const y = yOf(ins.pos, top);
      const art = m[id][n.s]|0;
      const ghost = (art === ART.GHOST);
      if(ins.pos <= -2){
        SVGT.appendChild(el('line',{x1:n.x-9,y1:yOf(-2,top),x2:n.x+9,y2:yOf(-2,top),stroke:INK,'stroke-width':1}));
      }
      if(ins.head==='x'){
        const r = ghost ? 3.3 : 4.4, w = ghost ? 1.4 : 1.8;
        SVGT.appendChild(el('line',{x1:n.x-r,y1:y-r,x2:n.x+r,y2:y+r,stroke:INK,'stroke-width':w,'stroke-linecap':'round'}));
        SVGT.appendChild(el('line',{x1:n.x-r,y1:y+r,x2:n.x+r,y2:y-r,stroke:INK,'stroke-width':w,'stroke-linecap':'round'}));
      } else {
        SVGT.appendChild(el('ellipse',{cx:n.x,cy:y,rx:ghost?4.1:5.4,ry:ghost?3.1:4,
          fill:INK,transform:`rotate(-18 ${n.x} ${y})`}));
      }
      const px = Math.min(7.4, GEO.SLOT_W*0.45);
      if(ghost){
        SVGT.appendChild(el('path',{d:`M ${n.x-px} ${y-5.6} q -2.6 5.6 0 11.2`,
          stroke:INK,'stroke-width':1.2,fill:'none','stroke-linecap':'round'}));
        SVGT.appendChild(el('path',{d:`M ${n.x+px} ${y-5.6} q 2.6 5.6 0 11.2`,
          stroke:INK,'stroke-width':1.2,fill:'none','stroke-linecap':'round'}));
      }
      if(art === ART.OPEN){
        SVGT.appendChild(el('circle',{cx:n.x,cy:y-10.5,r:3.1,fill:'none',stroke:INK,'stroke-width':1.3}));
      }
      if(n.dot){
        SVGT.appendChild(el('circle',{cx:n.x+(ghost?px+4.5:10),cy:y - (y%LG===0? LG/2 : 0),r:1.9,fill:INK}));
      }
    });
    const yEnd = up ? Math.max(...n.ys) : Math.min(...n.ys);
    SVGT.appendChild(el('line',{x1:n.x+stemDx,y1:yEnd + (up?-1:1),x2:n.x+stemDx,y2:beamY,stroke:INK,'stroke-width':1.6}));
  });
  notes.forEach(n=>{
    if(!n.ids.some(id => (m[id][n.s]|0) === ART.ACCENT)) return;
    accentGlyph(n.x, up ? beamY - 10 : beamY + 10, up);
  });
  const bw = 3.6;
  const groups = [];
  let run = [];
  notes.forEach(n=>{
    if(n.flags > 0) run.push(n);
    else { if(run.length) groups.push(run); run = []; }
  });
  if(run.length) groups.push(run);
  groups.forEach(gr=>{
    if(gr.length === 1){ drawFlags(gr[0].x+stemDx, beamY, up, gr[0].flags); return; }
    const x1 = gr[0].x+stemDx, x2 = gr[gr.length-1].x+stemDx;
    SVGT.appendChild(el('rect',{x:Math.min(x1,x2),y:up?beamY:beamY-bw,width:Math.abs(x2-x1),height:bw,fill:INK}));
    const maxF = Math.max(...gr.map(n=>n.flags));
    for(let lvl=2; lvl<=maxF; lvl++){
      const off = (bw+2.4)*(lvl-1);
      const y2 = up ? beamY + off : beamY - off;
      for(let i=0;i<gr.length;i++){
        const n = gr[i];
        if(n.flags < lvl) continue;
        const nx = n.x+stemDx;
        const prev = i>0 ? gr[i-1] : null;
        const nxt  = i<gr.length-1 ? gr[i+1] : null;
        const linkNext = !!(nxt && nxt.flags >= lvl && nxt.k - n.k === 1);
        const linkPrev = !!(prev && prev.flags >= lvl && n.k - prev.k === 1);
        if(linkNext){
          const nnx = nxt.x+stemDx;
          SVGT.appendChild(el('rect',{x:Math.min(nx,nnx),y:up?y2:y2-bw,width:Math.abs(nnx-nx),height:bw,fill:INK}));
        } else if(!linkPrev){
          const dir = prev ? -1 : 1;
          SVGT.appendChild(el('rect',{x:dir>0?nx:nx-9,y:up?y2:y2-bw,width:9,height:bw,fill:INK}));
        }
      }
    }
  });
  if(isTuplet(div) && !wholeBeatOne){
    const y = up ? beamY - 22 : beamY + 22;
    const beamed = (groups.length===1 && groups[0].length===notes.length && notes.length>1);
    const onlyNum = beamed && lead === 0;
    const x1 = onlyNum ? notes[0].x : xOfK(0) - 3;
    const x2 = onlyNum ? notes[notes.length-1].x : xAtPos(mx, b+1) - GEO.SLOT_W*0.7;
    tupletMark(x1, x2, y, up, div, !onlyNum);
  }
}
function drawFlags(x, y, up, count){
  for(let i=0;i<count;i++){
    const oy = up ? y + i*6 : y - i*6;
    const d = up
      ? `M ${x} ${oy} c 7 3, 9 9, 3 17 c 4 -7, 2 -11, -3 -13 Z`
      : `M ${x} ${oy} c 7 -3, 9 -9, 3 -17 c 4 7, 2 11, -3 13 Z`;
    SVGT.appendChild(el('path',{d, fill:INK}));
  }
}
const REST_BY_FLAGS = ['q', 'e8', 'e16'];
function drawRest(x, top, up, flags, dot){
  const voice = up ? 'hand' : 'foot';
  const kind = REST_BY_FLAGS[Math.min(flags|0, 2)];
  drawRestAt(x, top, voice, kind);
  if(dot){
    const g = REST_GLYPH[kind], sc = LG/9;
    SVGT.appendChild(el('circle',{
      cx: x + (g.w/2 + 2.8)*sc,
      cy: top + REST_ORIGIN[voice]*LG - LG*0.42,
      r: LG*0.21, fill:INK}));
  }
}
/* Bravura(Steinberg, SIL OFL 1.1) 아웃라인 — LG=9 기준 사전 스케일 */
const REST_GLYPH = {
  q: {top:-13.43, bot:13.5, w:9.68, x0:0.04,
      d:'M2.81 1.37C3.38 2.09 3.89 2.77 4.36 3.53C4.43 3.67 4.57 3.96 4.57 4.03C4.57 4.07 4.57 4.14 4.54 4.18C4.46 4.32 4.32 4.36 4.14 4.36C4 4.36 3.71 4.28 3.56 4.25C3.53 4.25 3.46 4.25 3.42 4.25L3.13 4.14C1.26 4.14 0.04 5.83 0.04 7.6C0.04 9.4 1.58 11.16 4.21 13.18C4.5 13.39 4.86 13.5 5.15 13.5C5.4 13.5 5.65 13.43 5.69 13.28C5.72 13.18 5.76 13.1 5.76 13.03C5.76 12.71 5.47 12.42 5.18 12.17C4.72 12.17 4.32 11.2 4.25 10.87C4.14 10.58 4.1 10.26 4.1 9.94C4.1 8.46 4.86 7.31 6.37 7.31C7.42 7.31 8.6 7.7 9.22 7.92L9.25 7.96C9.4 7.99 9.47 7.99 9.54 7.99C9.65 7.99 9.72 7.96 9.72 7.85C9.72 7.42 8.78 6.23 8.39 5.8C7.02 4.14 5.9 2.81 5.9 0.79C5.9 0.76 5.9 0.72 5.9 0.68L5.94 0.43C5.94 0.4 5.94 0.36 5.94 0.32C6.08 -1.76 7.38 -3.49 8.32 -4.97C8.42 -5.15 8.46 -5.33 8.46 -5.51C8.46 -5.87 8.32 -6.19 8.32 -6.19C8.32 -6.19 2.99 -12.53 2.38 -13.14C2.2 -13.32 1.94 -13.43 1.73 -13.43C1.37 -13.43 1.01 -13.18 1.01 -12.67C1.01 -12.49 1.04 -12.31 1.15 -12.1C1.3 -11.7 3.35 -9.86 3.35 -7.27C3.35 -5.94 2.81 -4.39 1.19 -2.7C0.83 -2.34 0.68 -1.94 0.68 -1.66C0.68 -1.15 1.04 -0.79 1.04 -0.79Z'},
  e8: {top:-6.26, bot:9.04, w:8.89, x0:0,
      d:'M4.82 -3.85C4.82 -5.18 3.74 -6.26 2.41 -6.26C1.08 -6.26 0 -5.18 0 -3.85C0 -3.1 0.43 -2.45 0.97 -2.02C1.55 -1.62 2.23 -1.4 2.92 -1.4C3.42 -1.4 3.92 -1.51 4.32 -1.66C4.82 -1.8 5.15 -1.94 5.62 -2.2C5.69 -2.23 5.76 -2.23 5.8 -2.23C5.94 -2.23 5.98 -2.09 5.98 -1.91C5.98 -1.8 5.98 -1.66 5.94 -1.51C5.83 -0.97 3.24 6.19 2.59 8.57C2.59 9 3.42 9.04 3.64 9.04C4.03 9.04 4.54 8.96 4.9 8.68C5 8.6 8.53 -4.03 8.53 -4.03C8.68 -4.68 8.86 -5.26 8.89 -5.44C8.89 -5.8 8.53 -5.98 8.46 -6.01C8.39 -6.01 8.28 -6.01 8.06 -5.87C7.81 -5.65 6.01 -3.49 4.82 -3.49Z'},
  e16: {top:-6.44, bot:18, w:11.52, x0:0,
      d:'M7.49 -4C7.49 -5.36 6.41 -6.44 5.04 -6.44C3.71 -6.44 2.59 -5.36 2.59 -4C2.59 -2.52 4.1 -1.55 5.47 -1.55C6.44 -1.55 7.45 -1.87 8.28 -2.34C8.39 -2.38 8.46 -2.41 8.53 -2.41C8.64 -2.41 8.71 -2.34 8.71 -2.16C8.71 -1.58 6.88 3.78 6.62 4.32C6.34 5 5.36 5.44 4.86 5.44C4.9 5.29 4.9 5.18 4.9 5.08C4.9 3.71 3.78 2.63 2.45 2.63C1.08 2.63 0 3.71 0 5.08C0 6.55 1.51 7.52 2.88 7.52C3.82 7.52 4.75 7.2 5.58 6.77C5.65 6.77 5.72 6.84 5.72 6.98L5.69 7.02C5.69 7.06 5.69 7.06 5.69 7.06L2.27 17.24C2.27 17.24 2.27 17.28 2.27 17.28L2.23 17.32C2.23 17.64 2.56 18 3.35 18C4.39 18 4.57 17.57 4.72 17.17L8.89 3.46C9.83 0.4 10.51 -2.02 10.51 -2.02C10.51 -2.02 11.41 -5.18 11.48 -5.65C11.48 -5.72 11.52 -5.76 11.52 -5.8C11.52 -6.01 11.23 -6.16 11.16 -6.19C10.98 -6.19 10.87 -6.12 10.76 -6.05C10.51 -5.83 8.71 -3.67 7.49 -3.64Z'},
  w: {top:-0.32, bot:4.86, w:10.15, x0:0,
      d:'M10.15 3.92L10.15 0.61C10.15 0.07 9.72 -0.32 9.22 -0.32L0.94 -0.32C0.4 -0.32 0 0.07 0 0.61L0 3.92C0 4.43 0.4 4.86 0.94 4.86L9.22 4.86C9.72 4.86 10.15 4.43 10.15 3.92Z'},
};
function restGlyph(x, originY, kind){
  const g = REST_GLYPH[kind], s = LG/9;
  SVGT.appendChild(el('path',{ d:g.d, fill:INK,
    transform:`translate(${x - (g.x0 + g.w/2)*s} ${originY})` + (s!==1 ? ` scale(${s})` : '') }));
}
const ACCENT_GLYPH = {
  above: {d:'M11.74-3.78C12.20-3.89 12.20-4.14 12.20-4.43C12.20-4.72 12.20-4.93 11.74-5.08L0.94-8.75C0.79-8.78 0.65-8.82 0.61-8.82C0.29-8.82 0.18-8.60 0.07-8.32C0.04-8.17 0.00-8.06 0.00-7.96C0.00-7.78 0.11-7.60 0.50-7.45C0.50-7.45 8.28-4.82 8.64-4.68C8.82-4.64 8.89-4.54 8.89-4.43C8.89-4.32 8.82-4.25 8.60-4.18C8.21-4.07 0.50-1.44 0.50-1.44C0.11-1.26 0.00-1.08 0.00-0.90C0.00-0.79 0.04-0.68 0.07-0.58C0.18-0.32 0.32-0.04 0.58-0.04C0.61-0.04 0.68-0.04 0.72-0.07', w:12.2},
  below: {d:'M11.74 5.04C12.20 4.93 12.20 4.68 12.20 4.39C12.20 4.10 12.20 3.89 11.74 3.74L0.94 0.07C0.79 0.04 0.65 0.00 0.61 0.00C0.29 0.00 0.18 0.22 0.07 0.50C0.04 0.65 0.00 0.76 0.00 0.86C0.00 1.04 0.11 1.22 0.50 1.37C0.50 1.37 8.28 4.00 8.64 4.14C8.82 4.18 8.89 4.28 8.89 4.39C8.89 4.50 8.82 4.57 8.60 4.64C8.21 4.75 0.50 7.38 0.50 7.38C0.11 7.56 0.00 7.74 0.00 7.92C0.00 8.03 0.04 8.14 0.07 8.24C0.18 8.50 0.32 8.78 0.58 8.78C0.61 8.78 0.68 8.78 0.72 8.75', w:12.2},
};
function accentGlyph(x, y, up){
  const g = ACCENT_GLYPH[up ? 'above' : 'below'], s = LG/9;
  SVGT.appendChild(el('path',{ d:g.d, fill:INK,
    transform:`translate(${x - (g.w/2)*s} ${y})` + (s!==1 ? ` scale(${s})` : '') }));
}
const REST_ORIGIN = {hand: 1.7, foot: 4.6, both: 2.0};
function drawRestAt(x, top, voice, kind){
  restGlyph(x, top + REST_ORIGIN[voice]*LG, kind);
}
function drawWholeRest(x, top, voice){
  restGlyph(x, top + (voice==='foot' ? 4*LG : LG), 'w');
}
// 리핏 마디 기호(simile mark, SMuFL repeat1Bar와 같은 뜻) — 사선 하나 + 점 두 개.
// Bravura 실제 외곽선 대신 기본 도형으로 재현(폰트 파일 없이도 항상 동일하게 그려짐).
function drawRepeatBarGlyph(cx, top){
  const midY = top + 2*LG;
  SVGT.appendChild(el('line', {x1:cx-6.5, y1:midY+LG*0.9, x2:cx+6.5, y2:midY-LG*0.9,
    stroke:INK, 'stroke-width':1.6, 'stroke-linecap':'round'}));
  SVGT.appendChild(el('circle', {cx:cx-4.2, cy:midY-LG*0.55, r:1.7, fill:INK}));
  SVGT.appendChild(el('circle', {cx:cx+4.2, cy:midY+LG*0.55, r:1.7, fill:INK}));
}
function drawMeasure(m, mx, top, mw){
  if(m && m.repeatPrev){ drawRepeatBarGlyph(mx + mw/2, top); return; }
  const hasH = voiceHasAny(m,'hand'), hasF = voiceHasAny(m,'foot');
  if(!hasH && !hasF){ drawWholeRest(mx + mw/2, top, 'both'); return; }
  if(!hasH) drawWholeRest(mx + mw/2, top, 'hand');
  if(!hasF) drawWholeRest(mx + mw/2, top, 'foot');
  for(let b=0;b<beatCount(m);b++){
    const hOn = hasH && onsetsOf(m, b, 'hand').length;
    const fOn = hasF && onsetsOf(m, b, 'foot').length;
    if(hasH && hasF && !hOn && !fOn){
      restGlyph(xAtPos(mx, b + 0.375), top + REST_ORIGIN.both*LG, 'q');
      continue;
    }
    if(hasH) drawVoiceBeat(m, mx, top, b, 'hand');
    if(hasF) drawVoiceBeat(m, mx, top, b, 'foot');
  }
}

/* 한 "줄"(라인) 하나를 그린다 — 폭은 항상 고정(refCount 기준 표준 마디폭 × refCount)이고,
   그 안에 들어가는 실제 마디 수(o.to-o.from)가 refCount보다 많으면 슬롯·간격을 다같이
   줄여서 압축한다(적으면 그냥 기본폭 유지, 억지로 안 늘림). o.measures = 그릴 마디 배열 전체,
   o.from/o.to = 그 중 이 줄에 들어갈 구간, o.cache(선택) = {mi:{x0,top,w}}를 채워줌(하이라이트용). */
const REF_SLOT = 19, REF_GAP = 6, REF_PAD = 13, REF_CLEF = 54;
const REF_MEASURE_W = REF_PAD*2 + 16*REF_SLOT + 3*REF_GAP;   // 표준 4박 마디 1개 폭

function paint(target, o){
  target.innerHTML = '';
  const measures = o.measures;
  const from = o.from|0;
  const to = (o.to == null) ? measures.length : o.to;
  const n = Math.max(1, to - from);
  const refCount = o.refCount || Math.max(1, o.perLine || n);   // 이 줄이 대표하는 "표준 마디 수"(보통 4)
  const scale = Math.min(1, refCount / n);
  const basePad = REF_PAD*scale, baseGap = REF_GAP*scale, baseSlot = REF_SLOT*scale;
  // 마디 폭은 박 수와 무관하게 항상 동일(기준 4박 마디 폭) — 변박이어도 줄이 들쭉날쭉해지지
  // 않고, 입력 탭 영역도 항상 일정하게 유지된다(2026-08-22, 비례 폭 방식에서 변경).
  // 그 안의 슬롯 폭만 박 수에 맞게 늘이거나 줄여서 항상 같은 폭을 채운다.
  const FIXED_MW = basePad*2 + 4*4*baseSlot + 3*baseGap;
  function slotFor(bc){ return Math.max(2, (FIXED_MW - basePad*2 - Math.max(0,bc-1)*baseGap) / (4*bc)); }
  function measureWidthFor(){ return FIXED_MW; }
  GEO = {SLOT_W: baseSlot, BEAT_GAP: baseGap, M_PAD: basePad, CLEF_W: REF_CLEF};
  const SYS_H = 150, TOP_PAD = 26;
  const svgW = GEO.CLEF_W + refCount*REF_MEASURE_W + 8;   // 항상 고정 폭 — 마디 수와 무관
  const svgH = TOP_PAD + SYS_H;
  target.setAttribute('width', svgW);
  target.setAttribute('height', svgH);
  target.setAttribute('viewBox', `0 0 ${svgW} ${svgH}`);

  const lineTs = normTs(measures[from] && measures[from].ts);
  const top = TOP_PAD + 34;
  const bottom = top + 4*LG;
  SVGT = target;
  let usedWidth = GEO.CLEF_W;
  for(let mi=from; mi<to; mi++) usedWidth += measureWidthFor(measures[mi]);
  for(let l=0;l<5;l++)
    target.appendChild(el('line',{x1:6,y1:top+l*LG,x2:usedWidth,y2:top+l*LG,stroke:INK,'stroke-width':1}));
  const clefX = 15;
  target.appendChild(el('rect',{x:clefX,y:top+LG,width:3.2,height:2*LG,fill:INK}));
  target.appendChild(el('rect',{x:clefX+6.4,y:top+LG,width:3.2,height:2*LG,fill:INK}));
  const tsX = clefX + 17, tsSize = 13.5;
  const ts1 = el('text',{x:tsX,y:top+LG*1.62,'font-size':tsSize,'font-weight':'700',
    fill:INK,'font-family':'Georgia,"Times New Roman",serif','text-anchor':'start'});
  ts1.textContent = String(lineTs[0]);
  const ts2 = el('text',{x:tsX,y:top+LG*3.62,'font-size':tsSize,'font-weight':'700',
    fill:INK,'font-family':'Georgia,"Times New Roman",serif','text-anchor':'start'});
  ts2.textContent = String(lineTs[1]);
  target.appendChild(ts1); target.appendChild(ts2);
  target.appendChild(el('line',{x1:6,y1:top,x2:6,y2:bottom,stroke:INK,'stroke-width':1.4}));
  let mx = GEO.CLEF_W;
  for(let mi=from; mi<to; mi++){
    const MW = FIXED_MW;
    GEO = {SLOT_W: slotFor(beatCount(measures[mi])), BEAT_GAP: baseGap, M_PAD: basePad, CLEF_W: REF_CLEF};
    if(o.cache) o.cache[mi] = {x0:mx, top, w:MW};
    const num = el('text',{x:mx+2,y:top-14,'font-size':10,fill:'#8E88A0'}); num.textContent = mi+1;
    target.appendChild(num);
    // 마디 위 자유 텍스트(연주 큐 등) — 좌측 정렬, 마디 번호(x=mx+2) 바로 오른쪽에 이어붙여
    // 같은 왼쪽 구역에 있어도 숫자와 안 겹치게 한다.
    if(measures[mi] && measures[mi].text){
      const ann = el('text',{x:mx+16,y:top-14,'font-size':10,'font-weight':'700',fill:'#7B4BE0','text-anchor':'start'});
      ann.textContent = measures[mi].text;
      target.appendChild(ann);
    }
    // 줄 중간에서 박자표가 바뀌어도 더 이상 강제로 줄을 끊지 않으므로(2026-08-22), 그 지점에
    // 정식 표기법대로 작은 박자표를 그려 왜 마디 폭이 달라졌는지 표기상 드러낸다.
    if(mi > from && tsKey(measures[mi]) !== tsKey(measures[mi-1])) drawInlineTs(mx, top, normTs(measures[mi].ts));
    drawMeasure(measures[mi], mx, top, MW);
    mx += MW;
    target.appendChild(el('line',{x1:mx,y1:top,x2:mx,y2:bottom,stroke:INK,'stroke-width':1.4}));
  }
  return svgW;
}
function drawInlineTs(x, top, ts){
  const size = 11;
  const t1 = el('text',{x:x+3,y:top+LG*1.55,'font-size':size,'font-weight':'700',
    fill:INK,'font-family':'Georgia,"Times New Roman",serif','text-anchor':'start'});
  t1.textContent = String(ts[0]);
  const t2 = el('text',{x:x+3,y:top+LG*3.55,'font-size':size,'font-weight':'700',
    fill:INK,'font-family':'Georgia,"Times New Roman",serif','text-anchor':'start'});
  t2.textContent = String(ts[1]);
  SVGT.appendChild(t1); SVGT.appendChild(t2);
}

/* 줄바꿈 — 왼쪽에서 오른쪽으로 훑는 단순 순차 모델.
   기본은 항상 targetPerLine(보통 4)마디씩 끊는다. 나누어떨어지지 않으면 맨 끝에만 자투리가
   남는다 — 중간에 어중간한 줄이 생기는 일이 없다.

   - measures[i].lineBreak===true: i 바로 앞에 강제 줄바꿈("줄바꿈"·"뒷줄로" 둘 다 이걸 쓴다 —
     기본이 순차 모델이 된 뒤로는 "뒤에 붙이기"와 "여기서 끊기"가 사실상 같은 동작이다: 끊긴
     자리부터 다시 4마디씩 채워나가므로, 끊는 순간 그 뒤가 자동으로 "다음 줄"이 된다).
   - measures[i].lineBreak===false: i가 원래 자연스러운 4마디 경계였더라도 무시하고 이어붙인다
     ("앞줄로" — 옮기는 구간의 모든 마디에 이 값을 설정하면, 그 경계들을 전부 무시하고
     쭉 이어붙인 뒤 다시 그 지점부터 4마디씩 재정렬한다. 그래서 마디를 옮기면 그 뒤로
     캐스케이드로 다시 채워지고 마지막에만 자투리가 남는다).
   - measures[i].lineTarget===8: "8마디로 배치" — 정확히 선택한 마디들만(연속 구간) 8마디
     단위로 묶는 "섬"이 된다. 그 앞뒤로는 기본 4마디 순차 모델이 그대로 이어진다. 이 태그가
     있는 구간은 사람이 선택한 정확한 범위 자체가 곧 하드 경계라, 줄 정렬 여부와 무관하게
     항상 그 경계 그대로 적용된다. */
function buildLineGroups(measures, sectionBreaks, targetPerLine){
  const N = measures.length;
  targetPerLine = targetPerLine || 4;
  const sectionSet = new Set(sectionBreaks.filter(i=>i>0 && i<N));
  const groups = [];
  let i = 0;
  while(i < N){
    const isl = measures[i] && measures[i].lineTarget;
    if(typeof isl === 'number' && isl > 0){
      // "섬" 구간: 연속으로 같은 태그가 붙은 마디들을 그 크기로 순차 청크.
      // lineTarget은 버튼(4/8)뿐 아니라 "뒷줄로"가 계산한 임의 크기도 들어올 수 있다.
      let j = i;
      while(j < N && measures[j] && measures[j].lineTarget === isl) j++;
      let p = i;
      while(p < j){ const cnt = Math.min(isl, j-p); groups.push({measureStartIdx:p, measureCount:cnt}); p += cnt; }
      i = j;
      continue;
    }
    // 기본 순차 targetPerLine 청크. 자연 경계(딱 target개째)에 다다르면 suppress(false)가
    // 연쇄로 붙어있는 만큼 계속 이어붙인다("앞줄로"). 강제 줄바꿈(true)이나 섹션 경계,
    // 다음 섬의 시작을 만나면 그 자리에서 무조건 끊는다. 박자표 변경은 더 이상 강제로 줄을
    // 끊지 않는다(2026-08-22) — 필요하면 사용자가 "줄바꿈"으로 직접 끊는다. 대신 바뀌는
    // 지점에 인라인 박자표를 그려서(paint 쪽) 표기상 드러나게 한다.
    let cnt = 0;
    while(i + cnt < N){
      const nextIdx = i + cnt;
      if(cnt > 0){
        const nm = measures[nextIdx];
        if((nm && typeof nm.lineTarget === 'number' && nm.lineTarget > 0) || sectionSet.has(nextIdx)) break;
        if(nm && nm.lineBreak === true) break;
      }
      cnt++;
      if(cnt === targetPerLine){
        while(i+cnt < N){
          const nm = measures[i+cnt];
          if(!nm || nm.lineBreak !== false || (typeof nm.lineTarget === 'number' && nm.lineTarget > 0) || sectionSet.has(i+cnt)) break;
          cnt++;
        }
        break;
      }
    }
    if(cnt <= 0) cnt = 1;
    groups.push({measureStartIdx: i, measureCount: cnt});
    i += cnt;
  }
  return groups;
}

window.Notation = { paint, buildLineGroups, beatCount, normTs, tsKey, REF_MEASURE_W, REF_CLEF, REF_SLOT, REF_GAP, REF_PAD, SVG_NS, LG, INK, el };
})();
