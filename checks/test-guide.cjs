'use strict';
// Run: cd a dir with jsdom installed && node <this file> <path to AgentDeck-Guide.html>
const assert = require('node:assert/strict');
const fs = require('node:fs');
const { JSDOM, VirtualConsole } = require('jsdom');
const html = fs.readFileSync(process.argv[2]||'Resources/AgentDeck-Guide.html', 'utf8');
function setup() {
 let now=0,seq=0;const timers=new Map(),errors=[];
 const vc=new VirtualConsole();vc.on('jsdomError',e=>errors.push(e));
 const dom=new JSDOM(html,{runScripts:'dangerously',virtualConsole:vc,beforeParse(w){
  w.setTimeout=(fn,delay=0)=>{const id=++seq;timers.set(id,{fn,at:now+delay});return id;};
  w.clearTimeout=id=>timers.delete(id);
  w.requestAnimationFrame=fn=>w.setTimeout(fn,0);
  w.Element.prototype.setPointerCapture=()=>{};
  // jsdom has no PointerEvent handler attributes; route those browser handlers through its DOM event system.
  for(const name of ['pointerdown','pointermove','pointerup','pointercancel','lostpointercapture','pointerenter']) {
   const key=Symbol(name);Object.defineProperty(w.HTMLElement.prototype,'on'+name,{get(){return this[key]||null;},set(fn){if(this[key])this.removeEventListener(name,this[key]);this[key]=fn;if(fn)this.addEventListener(name,fn);}});
  }
  Object.defineProperty(w.HTMLElement.prototype,'clientHeight',{get(){return this.id==='reviewBody'?100:this.id==='stage'?650:400;}});
  Object.defineProperty(w.HTMLElement.prototype,'scrollHeight',{get(){return this.id==='reviewBody'?500:400;}});
  Object.defineProperty(w.HTMLElement.prototype,'clientWidth',{get(){return this.id==='stage'?600:390;}});
  Object.defineProperty(w.HTMLElement.prototype,'offsetWidth',{get(){return parseInt(this.style.width)|| (this.classList.contains('collapsed')?280:390);}});
  Object.defineProperty(w.HTMLElement.prototype,'offsetHeight',{get(){return parseInt(this.style.height)||(this.classList.contains('collapsed')?45:550);}});
  Object.defineProperty(w.HTMLElement.prototype,'offsetLeft',{get(){return parseInt(this.style.left)||24;}});
  Object.defineProperty(w.HTMLElement.prototype,'offsetTop',{get(){return parseInt(this.style.top)||24;}});
 }});
 const w=dom.window,$=id=>w.document.getElementById(id);
 function tick(ms){const target=now+ms;let count=0;while(true){const next=[...timers].filter(([,t])=>t.at<=target).sort((a,b)=>a[1].at-b[1].at)[0];if(!next)break;assert(++count<100,'Bounded timer queue');const[id,t]=next;timers.delete(id);now=t.at;t.fn();}now=target;assert.equal(errors.length,0,errors.map(e=>e.message).join('\n'));}
 function event(el,name,opts={}){el.dispatchEvent(new w.Event(name,{bubbles:true,...opts}));}
 function select(mode){$('scenario').value=mode;event($('scenario'),'change');tick(0);}
 function review(){const body=$('reviewBody');body.scrollTop=400;event(body,'scroll');}
 function pointer(el,name,x,y){el.dispatchEvent(new w.MouseEvent(name,{bubbles:true,button:0,clientX:x,clientY:y}));}
 function key(el,name){el.dispatchEvent(new w.KeyboardEvent(name,{bubbles:true,key:' '}));}
 tick(0);$('tab-demo').click();return{$,w,tick,event,select,review,pointer,key,close:()=>dom.window.close()};
}
let passed=0;
test('why tab is first, visible by default, and Get set up opens Setup',t=>{const d=new JSDOM(html).window.document;assert.equal(d.getElementById('why').hidden,false);assert.equal(d.getElementById('setup').hidden,true);t.$('tab-why').click();t.$('goSetup').click();assert.equal(t.$('setup').hidden,false);assert(t.$('why').hidden);assert.equal(t.w.document.activeElement.id,'tab-setup');});
function test(name,fn){const t=setup();try{fn(t);passed++;console.log('PASS '+name);}finally{t.close();}}
test('routine label and 600ms review gate',t=>{t.$('expand').click();t.tick(0);assert.equal(t.$('allow').textContent,'Allow (demo)');assert(t.$('allow').disabled);t.tick(1000);assert(t.$('allow').disabled);t.review();t.tick(599);assert(t.$('allow').disabled);t.tick(1);assert(!t.$('allow').disabled);assert.equal(t.$('allow').textContent,'Allow (demo)');});
test('routine allow changes only fictional card',t=>{t.$('expand').click();t.tick(0);t.review();t.tick(600);t.$('allow').click();assert.match(t.$('demoCard').textContent,/Demo request allowed for session #demo01/);assert.match(t.$('demoCard').textContent,/No actual permission/);});
test('deny with note refuses blank, then resolves',t=>{t.$('expand').click();t.tick(0);t.review();t.tick(600);t.$('noteToggle').click();assert(!t.$('noteEditor').hidden);t.$('noteSend').click();assert.match(t.$('demoStatus').textContent,/Add a demo note first/);t.$('note').value='Try a narrower scope';t.$('noteSend').click();assert.match(t.$('demoCard').textContent,/denied with a note/);});
test('question Other refuses blank, accepts text',t=>{t.select('question');t.review();t.tick(600);t.$('answer').value='Other';t.event(t.$('answer'),'change');assert(!t.$('otherLabel').hidden);t.$('submit').click();assert.match(t.$('demoStatus').textContent,/complete Other first/);t.$('other').value='Only the sample setup guide';t.$('submit').click();assert.match(t.$('demoCard').textContent,/Demo question answered/);});
test('high-risk hold release at 999ms cancels',t=>{t.select('high');t.review();t.tick(600);t.key(t.$('allow'),'keydown');t.tick(999);assert(t.$('allow'));t.key(t.$('allow'),'keyup');t.tick(1);assert(t.$('allow'));assert.match(t.$('demoStatus').textContent,/Released early/);assert.equal(t.$('allow').textContent,'Hold to allow · 1 s');});
test('high-risk one-second hold resolves',t=>{t.select('high');t.review();t.tick(600);t.key(t.$('allow'),'keydown');t.tick(999);assert(t.$('allow'));t.tick(1);assert.match(t.$('demoCard').textContent,/allowed after a one-second hold/);});
test('collapse cancels in-progress hold',t=>{t.select('high');t.review();t.tick(600);t.key(t.$('allow'),'keydown');t.tick(500);t.$('expand').click();t.tick(600);assert(t.$('deck').classList.contains('collapsed'));assert.doesNotMatch(t.$('demoCard').textContent,/Demo result/);t.$('expand').click();t.tick(0);assert(t.$('allow').disabled);});
test('header drag moves without opening or deciding',t=>{const h=t.$('drag');t.pointer(h,'pointerdown',40,40);t.pointer(h,'pointermove',80,60);t.pointer(h,'pointerup',80,60);assert(t.$('deck').classList.contains('collapsed'));assert.equal(t.$('deck').style.left,'64px');assert.doesNotMatch(t.$('demoStatus').textContent,/allowed for session/);});
test('resize disarms and settles again',t=>{t.$('expand').click();t.tick(0);t.review();t.tick(600);assert(!t.$('allow').disabled);const g=t.$('grip');t.pointer(g,'pointerdown',400,500);t.pointer(g,'pointermove',420,520);t.pointer(g,'pointerup',420,520);assert(t.$('allow').disabled);t.tick(599);assert(t.$('allow').disabled);t.tick(1);assert(!t.$('allow').disabled);});
test('privacy hides details and all decisions',t=>{t.$('expand').click();t.tick(0);t.$('privacy').checked=true;t.event(t.$('privacy'),'change');assert.equal(t.$('allow'),null);assert.match(t.$('demoCard').textContent,/Privacy is on/);assert.doesNotMatch(t.$('sessionA').textContent,/Sample project/);assert.match(t.$('sessionA').textContent,/Session 1/);});
test('search no results and reset search',t=>{t.$('search').value='zzzz-nothing-matches';t.event(t.$('search'),'input');assert.match(t.$('helpCount').textContent,/0 of 6/);assert([...t.w.document.querySelectorAll('#faqs details')].every(d=>d.hidden));t.$('search').value='';t.event(t.$('search'),'input');assert.match(t.$('helpCount').textContent,/6 of 6/);});
test('reset restores click-mode routine collapsed state',t=>{t.select('high');t.$('hover').checked=true;t.$('privacy').checked=true;t.event(t.$('privacy'),'change');t.$('reset').click();t.tick(0);assert(!t.$('hover').checked&&!t.$('privacy').checked);assert.equal(t.$('scenario').value,'routine');assert(t.$('deck').classList.contains('collapsed'));t.$('expand').click();t.tick(0);assert.equal(t.$('allow').textContent,'Allow (demo)');});
test('host-only opens no external app or decision',t=>{t.select('host');assert.equal(t.$('allow'),null);t.$('hostOpen').click();assert.match(t.$('demoStatus').textContent,/No real app was opened/);});
test('seven vertical tabs keep one associated panel visible',t=>{const tabs=[...t.w.document.querySelectorAll('[role=tab]')];assert.equal(tabs.length,7);assert.equal(tabs[0].id,'tab-why');assert.equal(tabs[0].parentElement.getAttribute('aria-orientation'),'vertical');t.$('tab-setup').click();for(const tab of tabs){const selected=tab.id==='tab-setup';assert.equal(tab.getAttribute('aria-selected'),String(selected));assert.equal(tab.tabIndex,selected?0:-1);assert.equal(t.$(tab.getAttribute('aria-controls')).hidden,!selected);}});
test('tab keyboard supports Up Down Home End with focus',t=>{const send=(id,key)=>t.$(id).dispatchEvent(new t.w.KeyboardEvent('keydown',{bubbles:true,key}));t.$('tab-setup').click();send('tab-setup','ArrowDown');assert.equal(t.w.document.activeElement.id,'tab-daily');send('tab-daily','End');assert.equal(t.w.document.activeElement.id,'tab-demo');send('tab-demo','Home');assert.equal(t.w.document.activeElement.id,'tab-why');send('tab-why','ArrowUp');assert.equal(t.w.document.activeElement.id,'tab-demo');});
test('leaving demo cancels hold and disarms decisions',t=>{t.select('high');t.review();t.tick(600);t.key(t.$('allow'),'keydown');t.tick(300);t.$('tab-setup').click();t.tick(1000);assert(t.$('demo').hidden);assert(t.$('allow').disabled);assert.doesNotMatch(t.$('demoCard').textContent,/Demo result/);});
test('static copy is 900 to 1150 words and punctuation stays inline',t=>{const clean=new JSDOM(html);clean.window.document.querySelectorAll('script,style').forEach(e=>e.remove());const doc=clean.window.document;const walker=doc.createTreeWalker(doc.body,clean.window.NodeFilter.SHOW_TEXT);const pieces=[];while(walker.nextNode())pieces.push(walker.currentNode.textContent);const words=pieces.join(' ').trim().split(/\s+/).length;assert(words>=900&&words<=1150,`Static word count ${words}`);for(const p of doc.querySelectorAll('p,li,summary,h1,h2,h3'))assert(!/^[.,;:]/.test(p.textContent.trim()),`Leading punctuation: ${p.textContent}`);for(const strong of t.w.document.querySelectorAll('p strong,li strong'))assert.notEqual(t.w.getComputedStyle(strong).display,'block');console.log(`Static copy: ${words} words`);clean.window.close();});
console.log(`${passed} DOM/JavaScript unit checks passed; no GUI or native app verification performed.`);
